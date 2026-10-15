#!/usr/bin/env python3
"""cj-link 探针对端：TCP echo + UDP echo + 串口 pty 回包，一条进程跑齐三条链路的「另一头」。

用法：python3 cj-link-peer.py <dev-file> <rx-file> <peer-log> [tcp-port] [udp-port]
  dev-file  ：写从端 pty 路径（应用侧轮询读取）
  rx-file   ：串口对端收到的字节落这里（「真的写到了线路上」的外部证据）
  peer-log  ：对端自己的日志
行为：
  - 串口：从端收到什么回什么（echo），原样字节同时追加进 rx-file；
  - TCP ：127.0.0.1:<tcp-port> 起 echo 服务，收到什么回什么；
  - UDP ：127.0.0.1:<udp-port> 起 echo 服务（数据报原样回给来源地址）。
"""
import os
import pty
import socket
import sys
import threading


def serial_peer(master_fd, rx_file):
    with open(rx_file, "ab") as rx:
        while True:
            try:
                data = os.read(master_fd, 1024)
            except OSError:
                break
            if not data:
                break
            rx.write(data)
            rx.flush()
            os.write(master_fd, data)  # echo 回去


def tcp_peer(port, log):
    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind(("127.0.0.1", port))
    srv.listen(4)
    print("[tcp-peer] listening on 127.0.0.1:%d" % port, flush=True)

    def handle(conn, addr):
        print("[tcp-peer] client %s:%d connected" % addr, flush=True)
        try:
            while True:
                data = conn.recv(1024)
                if not data:
                    break
                conn.sendall(data)
        except OSError:
            pass
        finally:
            conn.close()
            print("[tcp-peer] client %s:%d closed" % addr, flush=True)

    while True:
        conn, addr = srv.accept()
        t = threading.Thread(target=handle, args=(conn, addr), daemon=True)
        t.start()


def udp_peer(port, log):
    u = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    u.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    u.bind(("127.0.0.1", port))
    print("[udp-peer] listening on 127.0.0.1:%d" % port, flush=True)
    while True:
        data, addr = u.recvfrom(4096)
        print("[udp-peer] %d bytes from %s:%d, echoing" % (len(data), addr[0], addr[1]), flush=True)
        u.sendto(data, addr)


def main():
    dev_file, rx_file, peer_log = sys.argv[1], sys.argv[2], sys.argv[3]
    tcp_port = int(sys.argv[4]) if len(sys.argv) > 4 else 15021
    udp_port = int(sys.argv[5]) if len(sys.argv) > 5 else tcp_port + 1

    sys.stdout = open(peer_log, "w", buffering=1)
    sys.stderr = sys.stdout

    master, slave = pty.openpty()
    name = os.ttyname(slave)
    with open(dev_file, "w") as f:
        f.write(name)
    print("[serial-peer] slave pty = %s" % name, flush=True)

    threading.Thread(target=serial_peer, args=(master, rx_file), daemon=True).start()
    threading.Thread(target=udp_peer, args=(udp_port, peer_log), daemon=True).start()
    try:
        tcp_peer(tcp_port, peer_log)
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
