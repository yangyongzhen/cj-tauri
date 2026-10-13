#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
cj-tauri E2E 用的 mock HTTP 对端（只用标准库）

为什么要有它：这一款示例的取证是**双侧对账**——页面侧断言「我收到了什么」，
而对端侧要能证明「我实际收到了什么」。公网端点做不到这一点（拿不到对端日志，还依赖网络），
所以断言锚点一律走本机 mock（docs/工具计划.md ② 的验收判据就是这么定的）。

端点（都是确定性的，方便逐字断言）：

  GET  /health          200 JSON {"ok":true,...}
  GET  /json            200 application/json，带 `X-Mock: yes` 与**两条 Set-Cookie**
                        （两条 Set-Cookie 是故意的：HTTP 语义里它们不能合并成一条，
                          用来验证客户端是逐条回投而不是拼成逗号串）
  GET  /text            200 text/plain，中文正文（验 UTF-8 解码）
  *    /echo            200 JSON，回显这次请求的方法 / 路径 / 查询 / 头 / 体
                        （页面拿它证明「发出去的东西对端真收到了」）
  *    /status/<码>     原样回该状态码（404 / 500 都是**正常结果**，不是错误——见 D-017 第 6 条）
  GET  /slow?ms=N      睡 N 毫秒再回（页面用超时打它，验传输层错误）
  GET  /big?kb=N       返回**正好** N*1024 字节（尾部是 `END:<N>kb`），验截断口径
  GET  /binary         200 application/octet-stream，4 个含 NUL 的字节
  GET  /redirect       302 → /json

日志：每行前缀 `[mock-http] `，逐行 flush（stdout）。给无人值守脚本看的是这几行：
  `READY port=<端口>`、`REQ method=… path=… query=… ct=… len=…`、`BODY …`、`RESP status=… bytes=…`。
`--selftest` 会自带一轮 16 项断言（服务端起在随机端口上），退出码即结论。
"""
import argparse
import json
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs

LOG_PREFIX = "[mock-http] "

# 逐字断言的固定正文（页面与 E2E 都拿这几个常量对账，改这里要同步改断言）
JSON_BODY = '{"slice":"ok","unicode":"中文","nested":{"a":1,"b":[true,null,"x"],"f":1.5}}'
TEXT_BODY = "你好，mock 对端"


def clip(s, n=300):
    """日志里的长文本截断：证据要能一行读完，不能把整个体刷进日志"""
    s = s.replace("\r", "\\r").replace("\n", "\\n")
    if len(s) <= n:
        return s
    return s[:n] + "...(共 %d 字符)" % len(s)


def force_utf8_stdout():
    """
    把 stdout 强成 UTF-8。

    坑：脚本被无人值守脚本重定向时，locale 往往是 POSIX/C，stdout 就按 **ASCII** 编码——
    而证据行里必然出现中文（页面发的中文体要证明对端真收到了），一打就 UnicodeEncodeError，
    整个 mock 当场退出（表现成「对端突然没了」，极难往编码上想）。
    errors=replace 兜底：宁可某个生僻字变问号，也不让编码问题把证据链整条掐断。
    """
    try:
        sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    except Exception:
        pass


class Logger:
    def __init__(self, path=""):
        self.lock = threading.Lock()
        self.fh = open(path, "w", encoding="utf-8") if path else None

    def log(self, msg):
        line = LOG_PREFIX + msg
        with self.lock:
            print(line, flush=True)
            if self.fh:
                self.fh.write(line + "\n")
                self.fh.flush()


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"      # 开 keep-alive；代价是每个响应都必须带 Content-Length
    server_version = "cj-tauri-mock-http"

    def log_message(self, fmt, *args):
        # BaseHTTPRequestHandler 默认往 stderr 打自己的格式，会把证据行淹掉——全部收进自己的日志
        self.server.logger.log("note " + (fmt % args))

    # ── 工具 ──────────────────────────────────────────────────────────────
    def _read_body(self):
        n = int(self.headers.get("Content-Length") or 0)
        if n <= 0:
            return b""
        return self.rfile.read(n)

    def _send(self, status, body, ctype="text/plain; charset=utf-8", extra=None):
        self.send_response(status)
        # 记下这一次真正发出去的体长：无人值守脚本拿它跟客户端侧读到的字节数对账
        # （/big 那条就是靠这个证明「截断」不是客户端自己瞎报的）
        self._last_bytes = len(body)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        for k, v in (extra or []):
            self.send_header(k, v)
        self.end_headers()
        if self.command != "HEAD":
            try:
                self.wfile.write(body)
            except (BrokenPipeError, ConnectionResetError):
                # 客户端超时先走了：这不是对端的错，但要留一行，免得看着像「响应丢了」
                self.server.logger.log("note client gone before body written")

    def _send_json(self, status, obj):
        self._send(status, json.dumps(obj, ensure_ascii=False).encode("utf-8"),
                   "application/json; charset=utf-8")

    # ── 所有方法都走同一条路（调试工具要能把任意方法发过来） ────────────────
    def do_GET(self):
        self._any()

    def do_POST(self):
        self._any()

    def do_PUT(self):
        self._any()

    def do_PATCH(self):
        self._any()

    def do_DELETE(self):
        self._any()

    def do_HEAD(self):
        self._any()

    def do_OPTIONS(self):
        self._any()

    def _any(self):
        u = urlparse(self.path)
        path = u.path
        q = parse_qs(u.query)
        body = self._read_body()

        self.server.logger.log("REQ method=%s path=%s query=%s ct=%s len=%d" % (
            self.command, path, u.query or "-",
            self.headers.get("Content-Type") or "-", len(body)))
        if body:
            self.server.logger.log("BODY " + clip(body.decode("utf-8", "replace")))

        if path == "/health":
            self._send_json(200, {"ok": True, "service": "mock-http"})
        elif path == "/json":
            self._send(200, JSON_BODY.encode("utf-8"), "application/json; charset=utf-8",
                       extra=[("X-Mock", "yes"),
                              ("Set-Cookie", "a=1; Path=/"),
                              ("Set-Cookie", "b=2; Path=/")])
        elif path == "/text":
            self._send(200, TEXT_BODY.encode("utf-8"), "text/plain; charset=utf-8")
        elif path == "/echo":
            # 头用 items() 逐对回显：同名头在这里也**不能**被合并，否则页面看到的不是对端收到的
            pairs = [[k, v] for k, v in self.headers.items()]
            self._send_json(200, {
                "method": self.command,
                "path": path,
                "query": u.query,
                "headers": pairs,
                "bodyLen": len(body),
                "bodyText": body.decode("utf-8", "replace"),
            })
        elif path.startswith("/status/"):
            try:
                code = int(path.rsplit("/", 1)[1])
            except ValueError:
                code = 400
            self._send_json(code, {"error": "mock", "status": code})
        elif path == "/slow":
            ms = int((q.get("ms") or ["0"])[0])
            time.sleep(ms / 1000.0)
            self._send_json(200, {"sleptMs": ms})
        elif path == "/big":
            kb = int((q.get("kb") or ["1024"])[0])
            total = kb * 1024
            marker = ("END:%dkb" % kb).encode("ascii")
            payload = b"A" * max(0, total - len(marker)) + marker
            self._send(200, payload, "text/plain; charset=utf-8",
                       extra=[("X-Mock-Bytes", str(len(payload)))])
        elif path == "/binary":
            self._send(200, b"\x00\x01\x02\xff", "application/octet-stream")
        elif path == "/redirect":
            self._send(302, b"redirecting", "text/plain; charset=utf-8",
                       extra=[("Location", "/json")])
        else:
            self._send_json(404, {"error": "no such endpoint", "path": path})

        self.server.logger.log("RESP status=%d path=%s bytes=%d"
                               % (self._last_status, path, self._last_bytes))

    def send_response(self, code, message=None):
        self._last_status = code
        self._last_bytes = 0
        BaseHTTPRequestHandler.send_response(self, code, message)


def start_server(port, logger):
    srv = ThreadingHTTPServer(("127.0.0.1", port), Handler)
    srv.logger = logger
    srv.daemon_threads = True
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    return srv


def selftest():
    """自检：自带 16 项断言，退出码即结论（与 mock-redis.py --selftest 同约定）"""
    import urllib.error
    import urllib.request

    force_utf8_stdout()
    logger = Logger()
    srv = start_server(0, logger)
    port = srv.server_address[1]
    logger.log("READY port=%d (selftest)" % port)
    base = "http://127.0.0.1:%d" % port

    state = {"passed": 0, "failed": 0}

    def check(name, cond, detail=""):
        if cond:
            state["passed"] += 1
            logger.log("SELFTEST PASS " + name)
        else:
            state["failed"] += 1
            logger.log("SELFTEST FAIL %s %s" % (name, detail))

    def fetch(path, data=None, method=None, headers=None):
        req = urllib.request.Request(base + path, data=data, method=method,
                                     headers=headers or {})
        return urllib.request.urlopen(req, timeout=10)

    try:
        # 1-3：JSON 端点逐字 + 头
        with fetch("/json") as r:
            raw = r.read().decode("utf-8")
            check("json.status", r.status == 200, "status=%s" % r.status)
            check("json.body", raw == JSON_BODY, "got=%s" % clip(raw))
            check("json.xmock", r.headers.get("X-Mock") == "yes")
            check("json.setcookie.two", len(r.headers.get_all("Set-Cookie") or []) == 2,
                  "got=%s" % (r.headers.get_all("Set-Cookie"),))

        # 4：中文正文逐字
        with fetch("/text") as r:
            check("text.unicode", r.read().decode("utf-8") == TEXT_BODY)

        # 5-7：回显端点证明「对端真收到了」
        # 中文查询串要写成百分号编码：http.client 编请求行时按 ASCII 走，
        # 直接塞裸中文会在这里抛 UnicodeEncodeError，看着像 mock 崩了、其实崩在自检的客户端
        with fetch("/echo?x=1&x=2&y=%E4%B8%AD", headers={"X-Probe": "hello"}) as r:
            echo = json.loads(r.read().decode("utf-8"))
            check("echo.method", echo["method"] == "GET", "got=%s" % echo["method"])
            check("echo.query", echo["query"] == "x=1&x=2&y=%E4%B8%AD", "got=%s" % echo["query"])
            check("echo.header", ["X-Probe", "hello"] in echo["headers"],
                  "got=%s" % clip(str(echo["headers"])))
        with fetch("/echo", data=json.dumps({"hello": "中文体"}, ensure_ascii=False).encode("utf-8"),
                   method="POST", headers={"Content-Type": "application/json"}) as r:
            echo = json.loads(r.read().decode("utf-8"))
            check("echo.body", echo["method"] == "POST" and echo["bodyLen"] > 0
                  and "中文体" in echo["bodyText"], "got=%s" % clip(str(echo)))

        # 8-9：错误状态码是**正常响应**（对端回码，客户端不该当异常）
        for code in (404, 500):
            try:
                fetch("/status/%d" % code)
                check("status.%d" % code, False, "没抛 HTTPError")
            except urllib.error.HTTPError as e:
                check("status.%d" % code, e.code == code, "got=%s" % e.code)

        # 10：慢响应
        t0 = time.time()
        with fetch("/slow?ms=120") as r:
            slept = json.loads(r.read().decode("utf-8"))["sleptMs"]
            check("slow.slept", slept == 120 and (time.time() - t0) >= 0.12,
                  "slept=%s elapsed=%.3f" % (slept, time.time() - t0))

        # 11：大响应体**正好** kb*1024 字节，尾部有标记（截断断言靠这个长度）
        with fetch("/big?kb=2") as r:
            data = r.read()
            check("big.length", len(data) == 2048, "got=%d" % len(data))
            check("big.marker", data.endswith(b"END:2kb"), "tail=%r" % data[-16:])

        # 12：二进制体（含 NUL）
        with fetch("/binary") as r:
            data = r.read()
            check("binary.nul", data == b"\x00\x01\x02\xff", "got=%r" % data)

        # 13：重定向（urllib 默认跟随，落到 /json）
        with fetch("/redirect") as r:
            check("redirect.followed", r.status == 200
                  and r.read().decode("utf-8") == JSON_BODY, "status=%s" % r.status)
    finally:
        srv.shutdown()
        srv.server_close()

    logger.log("SELFTEST DONE passed=%d failed=%d" % (state["passed"], state["failed"]))
    return 1 if state["failed"] else 0


def main(argv):
    force_utf8_stdout()
    ap = argparse.ArgumentParser(description="cj-tauri E2E 用的 mock HTTP 对端（标准库）")
    ap.add_argument("--port", type=int, default=8765, help="监听端口（0 = 系统分配）")
    ap.add_argument("--log", default="", help="另存一份日志到这个文件（无人值守脚本 grep 它）")
    ap.add_argument("--selftest", action="store_true", help="跑自检后退出")
    args = ap.parse_args(argv)

    if args.selftest:
        return selftest()

    logger = Logger(args.log)
    srv = ThreadingHTTPServer(("127.0.0.1", args.port), Handler)
    srv.logger = logger
    srv.daemon_threads = True
    # READY 行是脚本唯一可靠的「起好了 + 端口是多少」，必须逐行 flush（stdout 有缓冲）
    logger.log("READY port=%d" % srv.server_address[1])
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        srv.server_close()
    logger.log("STOP")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv[1:]))
    except KeyboardInterrupt:
        sys.exit(0)
