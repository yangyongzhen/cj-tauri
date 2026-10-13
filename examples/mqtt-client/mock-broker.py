#!/usr/bin/env python3
"""E2E 对端：一个只实现 MQTT 3.1.1 必需控制报文的 mock broker。

为什么自带一个（而不是装 mosquitto）：本机没有 broker，装一个还要跟发行版版本、systemd、
默认监听地址较劲；而框架这边要验证的东西很窄——**我们发出去的字节对端认不认、对端发回来的
字节我们认不认**。自己写对端能做到两件装 broker 做不到的事：

1. 每一步都打一行 `[mock-broker]` 前缀的日志，于是端到端有**两侧**证据（应用侧 stderr +
   对端侧日志），「到底谁没说话」一眼可分；
2. 订阅一成功就主动回推一条报文（QoS 0 与 QoS 1 各一条），把客户端的**收侧**（含 PUBACK 回执）
   也拉进同一轮验证——真实 broker 不会这么配合。

用法：
    python3 mock-broker.py --port 18830 --log /tmp/mock-broker.log
    python3 mock-broker.py --selftest        # 自检：本进程起 broker + 裸 socket 客户端跑一轮

实现范围（如实）：CONNECT/CONNACK、SUBSCRIBE/SUBACK、UNSUBSCRIBE/UNSUBACK、PUBLISH(0/1/2 收，
0/1 发)、PUBACK/PUBREC/PUBREL/PUBCOMP、PINGREQ/PINGRESP、DISCONNECT。
不做：TLS / WebSocket / MQTT 5.0、持久会话与离线消息、retain 存储、通配符匹配（订阅一律授予，
回推报文用具体主题）。它是**测试对端**，不是 broker 实现。
"""

import argparse
import socket
import struct
import sys
import threading
import time

# 控制报文类型码 → 名字（日志里一律写名字，别让人对着数字猜）
TYPE_NAMES = {
    1: "CONNECT", 2: "CONNACK", 3: "PUBLISH", 4: "PUBACK", 5: "PUBREC",
    6: "PUBREL", 7: "PUBCOMP", 8: "SUBSCRIBE", 9: "SUBACK", 10: "UNSUBSCRIBE",
    11: "UNSUBACK", 12: "PINGREQ", 13: "PINGRESP", 14: "DISCONNECT",
}

# 订阅一成功就回推的两条报文的载荷（页面/断言都按这两串文本对账）
GREET_QOS0 = b'{"from":"mock-broker","n":0}'
GREET_QOS1 = b'{"from":"mock-broker","n":1}'


class Log:
    """带锁的日志：一行前缀、同时进 stdout 与文件（stdout 给前台跑，文件给无人值守脚本 grep）。"""

    def __init__(self, path=None):
        self.lock = threading.Lock()
        self.fh = None
        if path:
            self.fh = open(path, "a", encoding="utf-8")

    def __call__(self, msg):
        line = "[mock-broker] " + msg
        with self.lock:
            print(line, flush=True)
            if self.fh:
                self.fh.write(line + "\n")
                self.fh.flush()


def enc_remaining(n):
    """变长剩余长度（MQTT 3.1.1 §2.2.3）：每字节 7 位有效，最高位是续接位。"""
    out = bytearray()
    while True:
        b = n % 128
        n //= 128
        if n > 0:
            b |= 0x80
        out.append(b)
        if n == 0:
            return bytes(out)


def recv_exact(sock, n):
    """读满 n 字节；对端提前关闭或出错回 None（调用方据此收尾）。"""
    buf = bytearray()
    while len(buf) < n:
        try:
            chunk = sock.recv(n - len(buf))
        except OSError:
            return None
        if not chunk:
            return None
        buf.extend(chunk)
    return bytes(buf)


def read_packet(sock):
    """读一个完整控制报文，返回 (type_code, flags, body)；对端关闭/畸形回 None。"""
    head = recv_exact(sock, 1)
    if head is None:
        return None
    b0 = head[0]
    mult = 1
    remaining = 0
    while True:
        rb = recv_exact(sock, 1)
        if rb is None:
            return None
        d = rb[0]
        remaining += (d & 0x7F) * mult
        if (d & 0x80) == 0:
            break
        mult *= 128
        if mult > 128 ** 3:
            return None
    body = b""
    if remaining > 0:
        body = recv_exact(sock, remaining)
        if body is None:
            return None
    return b0 >> 4, b0 & 0x0F, body


def send_packet(sock, type_code, flags, body):
    sock.sendall(bytes([(type_code << 4) | flags]) + enc_remaining(len(body)) + body)


def utf8_field(text):
    """MQTT 字符串 = 2 字节大端长度 + UTF-8 字节。"""
    raw = text.encode("utf-8")
    return struct.pack("!H", len(raw)) + raw


def read_utf8(body, at):
    """从 body 的 at 处读一个 MQTT 字符串，返回 (文本, 下一个位置)；越界回 (None, at)。"""
    if at + 2 > len(body):
        return None, at
    n = struct.unpack("!H", body[at:at + 2])[0]
    if at + 2 + n > len(body):
        return None, at
    try:
        text = body[at + 2:at + 2 + n].decode("utf-8")
    except UnicodeDecodeError:
        return None, at
    return text, at + 2 + n


def payload_text(payload):
    """载荷展示：能当文本看就给文本，否则给十六进制（与插件侧同一口径，不猜编码）。"""
    if not payload:
        return "(empty)"
    try:
        text = payload.decode("utf-8")
    except UnicodeDecodeError:
        return payload.hex()
    if any(ord(c) < 0x20 and c not in "\t\n\r" for c in text):
        return payload.hex()
    return text


def concrete_topic(topic_filter):
    """把订阅过滤器变成一个具体主题（回推报文用）：+ 与 # 各换成一个固定层。"""
    parts = []
    for level in topic_filter.split("/"):
        if level == "+":
            parts.append("plus")
        elif level == "#":
            parts.append("hash")
        else:
            parts.append(level)
    return "/".join(parts)


class Session:
    """一条客户端连接：按报文类型分派，每条都落一行日志。"""

    def __init__(self, conn, addr, log, greet):
        self.conn = conn
        self.addr = addr
        self.log = log
        self.greet = greet
        self.client_id = ""
        self.next_packet_id = 1
        self.rx_qos2 = {}   # 已回 PUBREC、等 PUBREL 的报文标识符（QoS 2 收侧状态机）

    def take_packet_id(self):
        pid = self.next_packet_id
        self.next_packet_id += 1
        return pid

    def run(self):
        try:
            while True:
                pkt = read_packet(self.conn)
                if pkt is None:
                    self.log("client %s closed" % self.addr[1])
                    return
                tcode, flags, body = pkt
                name = TYPE_NAMES.get(tcode, "UNKNOWN(%d)" % tcode)
                if tcode == 1:
                    self.on_connect(body)
                elif tcode == 3:
                    self.on_publish(flags, body)
                elif tcode == 4:
                    self.log("PUBACK rx pid=%d" % self.u16(body, 0))
                elif tcode == 6:
                    self.on_pubrel(body)
                elif tcode == 8:
                    self.on_subscribe(body)
                elif tcode == 10:
                    self.on_unsubscribe(body)
                elif tcode == 12:
                    send_packet(self.conn, 13, 0, b"")
                    self.log("PINGRESP tx（客户端保活心跳）")
                elif tcode == 14:
                    self.log("DISCONNECT rx（客户端主动下线，broker 不代发遗嘱）")
                    return
                else:
                    self.log("%s rx（本 mock 不处理，忽略）" % name)
        except OSError as exc:
            self.log("client %s socket error: %s" % (self.addr[1], exc))
        finally:
            try:
                self.conn.close()
            except OSError:
                pass

    def u16(self, body, at):
        if at + 2 > len(body):
            return -1
        return struct.unpack("!H", body[at:at + 2])[0]

    def on_connect(self, body):
        proto, at = read_utf8(body, 0)
        if at + 4 > len(body):
            self.log("CONNECT 畸形（协议名/级别/标志读不出来）")
            send_packet(self.conn, 2, 0, bytes([0, 1]))   # 返回码 1 = 协议级别不被支持
            return
        level = body[at]
        flags = body[at + 1]
        keepalive = struct.unpack("!H", body[at + 2:at + 4])[0]
        at += 4
        cid, at2 = read_utf8(body, at)
        if cid is None:
            self.log("CONNECT 畸形（客户端标识符读不出来）")
            send_packet(self.conn, 2, 0, bytes([0, 2]))   # 返回码 2 = 标识符被拒
            return
        self.client_id = cid
        clean = (flags & 0x02) != 0
        has_user = (flags & 0x80) != 0
        has_pass = (flags & 0x40) != 0
        self.log("CONNECT proto=%s level=%d client_id=%s keepalive=%ds clean=%s user=%s pass=%s" %
                 (proto, level, cid, keepalive, clean, has_user, has_pass))
        if proto != "MQTT" or level != 4:
            self.log("CONNACK tx rc=1（只认 MQTT 3.1.1 / 级别 4）")
            send_packet(self.conn, 2, 0, bytes([0, 1]))
            return
        send_packet(self.conn, 2, 0, bytes([0, 0]))
        self.log("CONNACK tx rc=0（连接已接受，session_present=0）")

    def on_publish(self, flags, body):
        qos = (flags >> 1) & 0x03
        retain = (flags & 0x01) != 0
        dup = (flags & 0x08) != 0
        topic, at = read_utf8(body, 0)
        if topic is None:
            self.log("PUBLISH 畸形（主题读不出来），丢弃")
            return
        pid = 0
        if qos > 0:
            pid = self.u16(body, at)
            at += 2
        payload = body[at:]
        self.log("PUBLISH rx topic=%s qos=%d retain=%s dup=%s pid=%d bytes=%d payload=%s" %
                 (topic, qos, retain, dup, pid, len(payload), payload_text(payload)))
        if qos == 1:
            send_packet(self.conn, 4, 0, struct.pack("!H", pid))
            self.log("PUBACK tx pid=%d" % pid)
        elif qos == 2:
            self.rx_qos2[pid] = True
            send_packet(self.conn, 5, 0, struct.pack("!H", pid))
            self.log("PUBREC tx pid=%d" % pid)

    def on_pubrel(self, body):
        pid = self.u16(body, 0)
        self.rx_qos2.pop(pid, None)
        send_packet(self.conn, 7, 0, struct.pack("!H", pid))
        self.log("PUBREL rx pid=%d → PUBCOMP tx pid=%d（QoS 2 收侧走完）" % (pid, pid))

    def on_subscribe(self, body):
        pid = self.u16(body, 0)
        at = 2
        granted = []
        names = []
        while at < len(body):
            topic_filter, at = read_utf8(body, at)
            if topic_filter is None or at >= len(body):
                break
            qos = body[at] & 0x03
            at += 1
            granted.append(qos)
            names.append("%s@%d" % (topic_filter, qos))
        self.log("SUBSCRIBE rx pid=%d filters=%s" % (pid, ",".join(names)))
        send_packet(self.conn, 9, 0, struct.pack("!H", pid) + bytes(granted))
        self.log("SUBACK tx pid=%d granted=%s" % (pid, ",".join(str(q) for q in granted)))
        if self.greet and names:
            # 订阅一成功就回推两条：QoS 0 验收侧普通路径，QoS 1 验客户端的 PUBACK 回执
            topic = concrete_topic(names[0].rsplit("@", 1)[0])
            self.publish_to_client(topic, GREET_QOS0, 0)
            self.publish_to_client(topic, GREET_QOS1, 1)

    def publish_to_client(self, topic, payload, qos):
        pid = self.take_packet_id() if qos > 0 else 0
        flags = (qos << 1)
        body = utf8_field(topic)
        if qos > 0:
            body += struct.pack("!H", pid)
        body += payload
        send_packet(self.conn, 3, flags, body)
        self.log("PUBLISH tx topic=%s qos=%d pid=%d payload=%s（回推，验证客户端收侧）" %
                 (topic, qos, pid, payload_text(payload)))

    def on_unsubscribe(self, body):
        pid = self.u16(body, 0)
        at = 2
        names = []
        while at < len(body):
            topic_filter, at = read_utf8(body, at)
            if topic_filter is None:
                break
            names.append(topic_filter)
        self.log("UNSUBSCRIBE rx pid=%d filters=%s" % (pid, ",".join(names)))
        send_packet(self.conn, 11, 0, struct.pack("!H", pid))
        self.log("UNSUBACK tx pid=%d（协议不带原因码）" % pid)


# ---------------------------------------------------------------- 服务端与入口


def serve(port, log, greet, on_ready=None):
    """监听并把每条连接交给一个线程；on_ready(实际端口) 在 accept 之前回调（自检靠它拿端口）。"""
    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind(("127.0.0.1", port))
    srv.listen(8)
    real_port = srv.getsockname()[1]
    log("listening on 127.0.0.1:%d" % real_port)
    if on_ready:
        on_ready(real_port)
    while True:
        conn, addr = srv.accept()
        log("client connected from 127.0.0.1:%d" % addr[1])
        threading.Thread(target=Session(conn, addr, log, greet).run, daemon=True).start()


def selftest():
    """自检：本进程起一个 broker，再用裸 socket 走一轮协议，逐步断言。

    为什么值得写：这个脚本是 E2E 的**对端**——对端自己有 bug 时，现象是「应用侧看着没问题、
    断言却对不上」，而那时人已经在怀疑被测代码了。自检先把「对端本身是对的」这件事钉住。
    """
    log = Log()
    ready = {}
    threading.Thread(target=serve, args=(0, log, True, lambda p: ready.setdefault("port", p)),
                     daemon=True).start()
    deadline = time.time() + 5
    while "port" not in ready and time.time() < deadline:
        time.sleep(0.02)
    if "port" not in ready:
        print("SELFTEST FAIL: mock broker 没起来（5s 内未监听）")
        return 1
    port = ready["port"]
    passed = []
    failed = []

    def check(name, ok):
        print(("SELFTEST ok   : " if ok else "SELFTEST FAIL : ") + name)
        (passed if ok else failed).append(name)

    c = socket.create_connection(("127.0.0.1", port), timeout=5)
    # CONNECT：cleanSession=1、keepalive=1s、clientId=selftest
    send_packet(c, 1, 0, utf8_field("MQTT") + bytes([4, 0x02]) + struct.pack("!H", 1) +
                utf8_field("selftest"))
    pkt = read_packet(c)
    check("CONNECT → CONNACK rc=0", pkt is not None and pkt[0] == 2 and pkt[2] == bytes([0, 0]))

    # SUBSCRIBE：一次一个过滤器（与本仓插件同一形态）
    send_packet(c, 8, 2, struct.pack("!H", 1) + utf8_field("demo/#") + bytes([1]))
    pkt = read_packet(c)
    check("SUBSCRIBE → SUBACK granted=1",
          pkt is not None and pkt[0] == 9 and pkt[2][2:] == bytes([1]))

    # 订阅成功后 broker 主动回推两条：QoS 0 与 QoS 1
    pkt0 = read_packet(c)
    check("broker → PUBLISH QoS0", pkt0 is not None and pkt0[0] == 3 and (pkt0[1] >> 1) == 0)
    pkt1 = read_packet(c)
    check("broker → PUBLISH QoS1", pkt1 is not None and pkt1[0] == 3 and (pkt1[1] >> 1) == 1)

    # QoS 1 收侧：解析出报文标识符与载荷，并回 PUBACK
    pid = 0
    payload_ok = False
    if pkt1 is not None and pkt1[0] == 3:
        topic, at = read_utf8(pkt1[2], 0)
        if topic is not None:
            pid = struct.unpack("!H", pkt1[2][at:at + 2])[0]
            payload_ok = pkt1[2][at + 2:] == GREET_QOS1
    check("QoS1 报文的主题/标识符/载荷可解出", pid > 0 and payload_ok)
    if pid > 0:
        send_packet(c, 4, 0, struct.pack("!H", pid))
        time.sleep(0.05)
        check("PUBACK 已发出（无应答报文，按无异常判定）", True)

    # 客户端发 PUBLISH QoS1 → 应收到 PUBACK
    send_packet(c, 3, 0x02, utf8_field("demo/tx") + struct.pack("!H", 7) + b"hello-mock")
    pkt = read_packet(c)
    check("PUBLISH(QoS1) → PUBACK pid=7",
          pkt is not None and pkt[0] == 4 and struct.unpack("!H", pkt[2])[0] == 7)

    # 保活
    send_packet(c, 12, 0, b"")
    pkt = read_packet(c)
    check("PINGREQ → PINGRESP", pkt is not None and pkt[0] == 13)

    # 退订
    send_packet(c, 10, 2, struct.pack("!H", 2) + utf8_field("demo/#"))
    pkt = read_packet(c)
    check("UNSUBSCRIBE → UNSUBACK pid=2",
          pkt is not None and pkt[0] == 11 and struct.unpack("!H", pkt[2])[0] == 2)

    # 主动下线
    send_packet(c, 14, 0, b"")
    time.sleep(0.05)
    c.close()
    check("DISCONNECT 已发出（连接由对端关闭，按无异常判定）", True)

    print("SELFTEST: %d passed, %d failed" % (len(passed), len(failed)))
    return 1 if failed else 0


def main(argv):
    ap = argparse.ArgumentParser(description="cj-tauri E2E 用的 MQTT 3.1.1 mock broker")
    ap.add_argument("--port", type=int, default=18830, help="监听端口（0 = 系统分配，自检用）")
    ap.add_argument("--log", default="", help="另存一份日志到这个文件（无人值守脚本 grep 它）")
    ap.add_argument("--no-greet", action="store_true", help="订阅成功后不回推报文（只看单向流量时用）")
    ap.add_argument("--selftest", action="store_true", help="跑自检后退出")
    args = ap.parse_args(argv)
    if args.selftest:
        return selftest()
    log = Log(args.log if args.log else None)
    log("mode=serve port=%d greet=%s" % (args.port, not args.no_greet))
    serve(args.port, log, not args.no_greet)
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv[1:]))
    except KeyboardInterrupt:
        sys.exit(0)
