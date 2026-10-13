#!/usr/bin/env python3
"""E2E 对端：一个**照本宣科的假 Redis 服务端**（RESP2），不是 redis 实现。

为什么自带一个（而不是装 redis-server）：本仓要验证的东西很窄——**我们发出去的 RESP
字节对端认不认、对端发回来的字节我们认不认**。自己写对端能做到两件装真 redis 做不到的事：

1. 每条收到的命令、每条回复都打一行 `[mock-redis]` 前缀的日志，于是端到端有**两侧**证据
   （应用侧 stderr + 对端侧日志），「到底谁没说话」一眼可分；
2. 启动即 seed 一份**稳定、可断言**的数据集（14 个 key），无人值守脚本能直接对着断言，
   既不用等真 redis 起来，也不受版本/配置漂移影响。

用法：
    python3 mock-redis.py --port 6379 --log /tmp/mock-redis.log
    python3 mock-redis.py --selftest        # 自检：本进程起服务端 + 裸 socket 客户端跑 10 项断言

实现的命令（如实）：
  连接/服务：PING ECHO AUTH SELECT CLIENT(SETNAME/GETNAME/INFO) COMMAND DOCS
            INFO DBSIZE CONFIG GET SLOWLOG GET FLUSHDB
  键空间：  TYPE TTL PTTL EXISTS DEL RENAME EXPIRE PERSIST STRLEN SCAN KEYS
  string：  GET SET SETEX MGET APPEND
  hash：    HGETALL HSET HDEL HLEN HGET HEXISTS HSCAN
  list：    LRANGE LPUSH RPUSH LLEN LSET LREM LPOP
  set：     SMEMBERS SADD SREM SCARD SISMEMBER SSCAN
  zset：    ZRANGE(WITHSCORES) ZADD ZREM ZCARD ZSCORE
  stream：  XADD XRANGE XLEN
  发布订阅：SUBSCRIBE UNSUBSCRIBE PSUBSCRIBE PUNSUBSCRIBE PUBLISH
不做的：持久化、复制、集群、事务(MULTI/EXEC)、Lua、位图/Geo/HyperLogLog、RESP3、ACL 鉴权、
  真过期淘汰线程（用惰性删除）、以及上面没列的其余命令——**未知命令一律回
  `-ERR unknown command '<name>'`**。它是测试对端，不是 redis 实现。

风格：只用 python3 标准库；函数按 RESP 编解码 / 存储与命令 / 连接线程 / 自检 分层。
"""

import argparse
import socket
import sys
import threading
import time

# ---------------------------------------------------------------- 常量

CRLF = b"\r\n"
NULL_BULK = b"$-1\r\n"
NULL_ARRAY = b"*-1\r\n"
STREAM_TITLE_VERSION = b"7.2.0-mock"


# ---------------------------------------------------------------- 日志


class Log:
    """带锁的日志：一行前缀 `[mock-redis] `，同时进 stdout 与文件。

    只写 stdout：无人值守脚本用 `> log 2>&1` 收日志，若再往 stderr 写一份，同一行会**出现两次**，
    `grep -c` 那类断言（比如「对端看见几次客户端接入」）就被凭空翻倍——第一版实机取证正是这么被骗过。
    """

    def __init__(self, path=None):
        self.lock = threading.Lock()
        self.fh = None
        if path:
            self.fh = open(path, "a", encoding="utf-8")

    def __call__(self, msg):
        line = "[mock-redis] " + msg
        with self.lock:
            print(line, flush=True)
            if self.fh:
                self.fh.write(line + "\n")
                self.fh.flush()


def fmt_arg(b):
    """日志里的单个参数：可打印 ASCII 直接显示（超 40 字符截断加 …），否则按 hex（二进制安全）。"""
    if all(32 <= x < 127 for x in b):
        s = b.decode("ascii")
        if len(s) > 40:
            s = s[:40] + "…"
        return s
    return b.hex()


def fmt_args(args):
    return " ".join(fmt_arg(a) for a in args)


# ---------------------------------------------------------------- RESP 编码


def enc_simple(s):
    """简单字符串：+<s>\\r\\n。"""
    return b"+" + s + CRLF


def enc_error(s):
    """错误：-<s>\\r\\n（s 里别再带前导 -）。"""
    return b"-" + s + CRLF


def enc_int(n):
    """整数：:<n>\\r\\n。"""
    return b":" + str(int(n)).encode() + CRLF


def enc_bulk(b):
    """bulk：$<字节数>\\r\\n<b>\\r\\n。长度按**字节数**算（二进制安全）。"""
    return b"$" + str(len(b)).encode() + CRLF + b + CRLF


def enc_array(items):
    """数组：*<N>\\r\\n + 各元素（元素是已编码好的 blob）。"""
    return b"*" + str(len(items)).encode() + CRLF + b"".join(items)


# ---------------------------------------------------------------- RESP 读取


class Conn:
    """带缓冲的读端：一次 recv 可能只到一半，所有读取都基于内部 buffer。"""

    def __init__(self, sock):
        self.sock = sock
        self.buf = bytearray()

    def _fill(self):
        try:
            chunk = self.sock.recv(65536)
        except OSError:
            return False
        if not chunk:
            return False
        self.buf.extend(chunk)
        return True

    def read_line(self):
        while True:
            idx = self.buf.find(CRLF)
            if idx >= 0:
                line = bytes(self.buf[:idx])
                del self.buf[:idx + 2]
                return line
            if not self._fill():
                return None

    def read_exact(self, n):
        while len(self.buf) < n:
            if not self._fill():
                return None
        data = bytes(self.buf[:n])
        del self.buf[:n]
        return data

    def read_command(self):
        """读一条命令，返回参数列表（每项 bytes）；对端关闭/畸形回 None。"""
        line = self.read_line()
        if line is None:
            return None
        if line[:1] != b"*":
            # 内联命令（少数客户端会这么发）；空格分隔
            return line.split() if line else []
        try:
            n = int(line[1:])
        except ValueError:
            return None
        if n <= 0:
            return []
        args = []
        for _ in range(n):
            head = self.read_line()
            if head is None or head[:1] != b"$":
                return None
            try:
                ln = int(head[1:])
            except ValueError:
                return None
            data = self.read_exact(ln)
            if data is None:
                return None
            if self.read_exact(2) is None:
                return None
            args.append(data)
        return args


def read_reply(conn):
    """读一个 RESP 回复，返回 (kind, value)。自检的裸客户端用它解析。"""
    line = conn.read_line()
    if line is None:
        return ("eof", None)
    t, rest = line[:1], line[1:]
    if t == b"+":
        return ("simple", rest)
    if t == b"-":
        return ("error", rest)
    if t == b":":
        return ("integer", int(rest))
    if t == b"$":
        n = int(rest)
        if n == -1:
            return ("null", None)
        data = conn.read_exact(n)
        if data is None:
            return ("eof", None)
        conn.read_exact(2)
        return ("bulk", data)
    if t == b"*":
        n = int(rest)
        if n == -1:
            return ("null", None)
        return ("array", [read_reply(conn) for _ in range(n)])
    return ("unknown", line)


def send_command(sock, args):
    """把一条命令按 RESP 数组 of bulk 发出。"""
    parts = [b"*" + str(len(args)).encode() + CRLF]
    for a in args:
        if isinstance(a, str):
            a = a.encode()
        parts.append(enc_bulk(a))
    sock.sendall(b"".join(parts))


# ---------------------------------------------------------------- 值类型与 glob


class H(dict):
    """hash：field(bytes) -> value(bytes)。"""


class Z(dict):
    """zset：member(bytes) -> score(float)。"""


class L(list):
    """list：元素 bytes。"""


class S(set):
    """set：成员 bytes。"""


class Stream(list):
    """stream：元素 (id_bytes, [(field, value), ...])。"""


def type_name(v):
    if isinstance(v, H):
        return b"hash"
    if isinstance(v, L):
        return b"list"
    if isinstance(v, S):
        return b"set"
    if isinstance(v, Z):
        return b"zset"
    if isinstance(v, Stream):
        return b"stream"
    return b"string"


def _match_class(pat, pi, ch):
    """解析 pat[pi]=='[' 开始的字符组，返回 (']' 之后的下标, 是否匹配)。"""
    i = pi + 1
    neg = False
    if i < len(pat) and pat[i] in (0x5E, 0x21):  # '^' / '!'
        neg = True
        i += 1
    matched = False
    first = True
    while i < len(pat):
        if pat[i] == 0x5D and not first:  # ']'
            break
        first = False
        if i + 2 < len(pat) and pat[i + 1] == 0x2D and pat[i + 2] != 0x5D:  # a-z
            if pat[i] <= ch <= pat[i + 2]:
                matched = True
            i += 3
        else:
            if pat[i] == ch:
                matched = True
            i += 1
    return (i + 1 if i < len(pat) else i), (matched != neg)


def _glob(pat, pi, s, si):
    while pi < len(pat):
        c = pat[pi]
        if c == 0x2A:  # '*'
            while pi < len(pat) and pat[pi] == 0x2A:
                pi += 1
            if pi == len(pat):
                return True
            for k in range(si, len(s) + 1):
                if _glob(pat, pi, s, k):
                    return True
            return False
        if c == 0x3F:  # '?'
            if si >= len(s):
                return False
            si += 1
            pi += 1
        elif c == 0x5B:  # '['
            if si >= len(s):
                return False
            pi, ok = _match_class(pat, pi, s[si])
            if not ok:
                return False
            si += 1
        else:
            if si >= len(s) or s[si] != c:
                return False
            si += 1
            pi += 1
    return si == len(s)


def glob_match(pat, s):
    """Redis 风格 glob：* ? [...]（[^...] / [!...] 取反，支持 a-z 区间）。"""
    return _glob(pat, 0, s, 0)


def fmt_score(s):
    """分值字符串：整数形式不带小数点（7 而非 7.0），与 Redis 观感一致且稳定。"""
    if s == int(s):
        return str(int(s))
    return repr(s)


# ---------------------------------------------------------------- 存储


class Db:
    def __init__(self):
        self.data = {}
        self.expires = {}


class Store:
    """两个 db（0/1）+ 惰性过期 + 统计。多连接共享，用 lock 串行化命令执行。"""

    def __init__(self):
        self.lock = threading.RLock()
        self.dbs = [Db(), Db()]
        self.port = 0
        self.start = time.time()
        self.conn_count = 0
        self.cmd_count = 0
        self._seed()

    def _seed(self):
        now = time.time()
        d0 = self.dbs[0]
        d0.data[b"user:1"] = b"alice"
        d0.data[b"user:2"] = b"bob"
        d0.data[b"app:json"] = b'{"name":"cj-tauri","ok":true}'
        d0.data[b"cache:temp"] = b"expires-soon"
        d0.expires[b"cache:temp"] = now + 600
        d0.data[b"cache:persist"] = b"forever"
        d0.data[b"blob:bin"] = bytes([0x00, 0x01, 0xFF, 0xFE])
        d0.data[b"app:cache:a"] = b"1"
        d0.data[b"app:cache:b"] = b"2"
        d0.data[b"app:config"] = b"dark"

        prof = H()
        prof[b"name"] = b"alice"
        prof[b"city"] = b"Beijing"
        prof[b"level"] = b"7"
        d0.data[b"user:1:profile"] = prof

        jobs = L([b"job-1", b"job-2", b"job-3"])
        d0.data[b"queue:jobs"] = jobs

        tags = S([b"cj", b"tauri", b"gui"])
        d0.data[b"tags:news"] = tags

        board = Z({b"alice": 12.5, b"bob": 7.0, b"carol": 21.0})
        d0.data[b"board:score"] = board

        st = Stream()
        st.append((b"1-0", [(b"event", b"start"), (b"service", b"cj-tauri")]))
        st.append((b"2-0", [(b"event", b"heartbeat"), (b"n", b"1")]))
        d0.data[b"events:app"] = st

        self.dbs[1].data[b"db1:only"] = b"one"


class PubSub:
    """频道/模式 -> 订阅连接。PUBLISH 时向所有命中的连接推 push。"""

    def __init__(self):
        self.lock = threading.Lock()
        self.channels = {}  # bytes -> set(Session)
        self.patterns = {}  # bytes -> set(Session)

    def subscribe(self, sess, ch):
        with self.lock:
            self.channels.setdefault(ch, set()).add(sess)

    def unsubscribe(self, sess, ch):
        with self.lock:
            subs = self.channels.get(ch)
            if subs:
                subs.discard(sess)
                if not subs:
                    self.channels.pop(ch, None)

    def psubscribe(self, sess, pat):
        with self.lock:
            self.patterns.setdefault(pat, set()).add(sess)

    def punsubscribe(self, sess, pat):
        with self.lock:
            subs = self.patterns.get(pat)
            if subs:
                subs.discard(sess)
                if not subs:
                    self.patterns.pop(pat, None)

    def remove_session(self, sess):
        with self.lock:
            for ch in list(self.channels):
                self.channels[ch].discard(sess)
                if not self.channels[ch]:
                    self.channels.pop(ch, None)
            for pat in list(self.patterns):
                self.patterns[pat].discard(sess)
                if not self.patterns[pat]:
                    self.patterns.pop(pat, None)

    def publish(self, ch, payload):
        """向命中频道的连接推 [message, ch, payload]，向命中模式的推 [pmessage, pat, ch, payload]；
        返回收到推送的连接数（去重）。"""
        with self.lock:
            chan_subs = list(self.channels.get(ch, ()))
            pat_hits = [(pat, list(subs)) for pat, subs in self.patterns.items()
                        if glob_match(pat, ch)]
        targets = set(chan_subs)
        for _, subs in pat_hits:
            targets.update(subs)
        for sess in chan_subs:
            sess.push(enc_array([enc_bulk(b"message"), enc_bulk(ch), enc_bulk(payload)]))
        for pat, subs in pat_hits:
            for sess in subs:
                sess.push(enc_array([enc_bulk(b"pmessage"), enc_bulk(pat),
                                     enc_bulk(ch), enc_bulk(payload)]))
        return len(targets)


# ---------------------------------------------------------------- 连接线程


class Session:
    def __init__(self, sock, peer, store, pubsub, log):
        self.conn = Conn(sock)
        self.sock = sock
        self.peer = peer
        self.store = store
        self.pubsub = pubsub
        self.log = log
        self.send_lock = threading.Lock()
        self.db_index = 0
        self.subs = set()   # bytes 频道
        self.psubs = set()  # bytes 模式
        self.name = b""

    # ---- 发送与收尾

    def start(self):
        threading.Thread(target=self.run, daemon=True).start()

    def send(self, blob):
        with self.send_lock:
            try:
                self.sock.sendall(blob)
            except OSError:
                pass

    def push(self, blob):
        """PUBLISH 推送（可能与本线程的命令回复并发，走同一把锁）。"""
        self.send(blob)

    def _db(self):
        return self.store.dbs[self.db_index]

    def _live(self, key, db=None):
        """取 key 的活值：过期即惰性删除。"""
        db = db or self._db()
        exp = db.expires.get(key)
        if exp is not None and exp <= time.time():
            db.data.pop(key, None)
            db.expires.pop(key, None)
        return db.data.get(key)

    def run(self):
        try:
            while True:
                args = self.conn.read_command()
                if args is None:
                    break
                if not args:
                    continue
                name = args[0].decode("utf-8", "replace").upper()
                self.log("%s rx args=%s" % (name, fmt_args(args[1:])))
                blob, kind = self.execute(args, name)
                self.log("%s tx type=%s bytes=%d" % (name, kind, len(blob)))
                self.send(blob)
        finally:
            self.pubsub.remove_session(self)
            try:
                self.sock.close()
            except OSError:
                pass

    # ---- 分发

    def execute(self, args, name):
        self.store.cmd_count += 1
        handler = self.dispatch().get(args[0].upper())
        if handler is None:
            return enc_error(b"ERR unknown command '" + args[0] + b"'"), "error"
        with self.store.lock:
            return handler(args)

    def dispatch(self):
        return {
            b"PING": self.c_ping, b"ECHO": self.c_echo, b"AUTH": self.c_auth,
            b"SELECT": self.c_select, b"CLIENT": self.c_client,
            b"COMMAND": self.c_command, b"INFO": self.c_info, b"DBSIZE": self.c_dbsize,
            b"CONFIG": self.c_config, b"SLOWLOG": self.c_slowlog, b"FLUSHDB": self.c_flushdb,
            b"TYPE": self.c_type, b"TTL": self.c_ttl, b"PTTL": self.c_pttl,
            b"EXISTS": self.c_exists, b"DEL": self.c_del, b"RENAME": self.c_rename,
            b"EXPIRE": self.c_expire, b"PERSIST": self.c_persist, b"STRLEN": self.c_strlen,
            b"SCAN": self.c_scan, b"KEYS": self.c_keys,
            b"HSCAN": self.c_hscan, b"SSCAN": self.c_sscan,
            b"GET": self.c_get, b"SET": self.c_set, b"SETEX": self.c_setex,
            b"MGET": self.c_mget, b"APPEND": self.c_append,
            b"HGETALL": self.c_hgetall, b"HSET": self.c_hset, b"HDEL": self.c_hdel,
            b"HLEN": self.c_hlen, b"HGET": self.c_hget, b"HEXISTS": self.c_hexists,
            b"LRANGE": self.c_lrange, b"LPUSH": self.c_lpush, b"RPUSH": self.c_rpush,
            b"LLEN": self.c_llen, b"LSET": self.c_lset, b"LREM": self.c_lrem,
            b"LPOP": self.c_lpop,
            b"SMEMBERS": self.c_smembers, b"SADD": self.c_sadd, b"SREM": self.c_srem,
            b"SCARD": self.c_scard, b"SISMEMBER": self.c_sismember,
            b"ZRANGE": self.c_zrange, b"ZADD": self.c_zadd, b"ZREM": self.c_zrem,
            b"ZCARD": self.c_zcard, b"ZSCORE": self.c_zscore,
            b"XADD": self.c_xadd, b"XRANGE": self.c_xrange, b"XLEN": self.c_xlen,
            b"SUBSCRIBE": self.c_subscribe, b"UNSUBSCRIBE": self.c_unsubscribe,
            b"PSUBSCRIBE": self.c_psubscribe, b"PUNSUBSCRIBE": self.c_punsubscribe,
            b"PUBLISH": self.c_publish,
        }

    # ---- 小工具

    def _ok(self):
        return enc_simple(b"OK"), "simple"

    def _err(self, msg):
        return enc_error(msg), "error"

    def _wrongtype(self):
        return self._err(b"WRONGTYPE Operation against a key holding the wrong kind of value")

    def _need(self, args, n, name):
        """参数个数不足时回错（name 用于错误文案）。"""
        if len(args) < n:
            return self._err(b"ERR wrong number of arguments for '" + name + b"' command")
        return None

    def _ttl_ms(self, key):
        db = self._db()
        if self._live(key, db) is None:
            return -2
        exp = db.expires.get(key)
        if exp is None:
            return -1
        return int((exp - time.time()) * 1000)

    def _keytype(self, key):
        v = self._live(key)
        return b"none" if v is None else type_name(v)

    # ---- 连接 / 服务

    def c_ping(self, args):
        if len(args) == 1:
            return enc_simple(b"PONG"), "simple"
        return enc_bulk(args[1]), "bulk"

    def c_echo(self, args):
        if len(args) < 2:
            return self._need(args, 2, b"echo")
        return enc_bulk(args[1]), "bulk"

    def c_auth(self, args):
        # 用户名/口令任意；只在收到 AUTH 时验，不强制。1 参=口令，2 参=用户名+口令。
        if len(args) not in (2, 3):
            return self._need(args, 2, b"auth")
        return self._ok()

    def c_select(self, args):
        if len(args) < 2:
            return self._need(args, 2, b"select")
        try:
            n = int(args[1])
        except ValueError:
            return self._err(b"ERR value is not an integer or out of range")
        if n < 0 or n >= len(self.store.dbs):
            return self._err(b"ERR DB index is out of range")
        self.db_index = n
        return self._ok()

    def c_client(self, args):
        sub = args[1].upper() if len(args) > 1 else b""
        if sub == b"SETNAME":
            self.name = args[2] if len(args) > 2 else b""
            return self._ok()
        if sub == b"GETNAME":
            return enc_bulk(self.name), "bulk"
        if sub == b"INFO":
            txt = (b"id=%d addr=%s name=%s db=%d\n"
                   % (threading.get_ident() & 0xFFFF, self.peer.encode(), self.name, self.db_index))
            return enc_bulk(txt), "bulk"
        if sub in (b"ID", b"SETINFO", b"NO-EVICT", b"NO-TOUCH"):
            return enc_int(0), "integer" if sub in (b"ID",) else "simple"
        return self._ok()

    def c_command(self, args):
        # COMMAND DOCS（客户端探测）返空数组；COMMAND 整体也返空数组即可。
        return enc_array([]), "array"

    def c_info(self, args):
        store = self.store
        uptime = int(time.time() - store.start)
        d0 = len(self._live_keys(store.dbs[0]))
        d1 = len(self._live_keys(store.dbs[1]))
        sections = [
            (b"Server", [
                b"redis_version:" + STREAM_TITLE_VERSION,
                b"redis_mode:standalone",
                b"os:mock-redis (python test peer)",
                b"tcp_port:%d" % store.port,
                b"uptime_in_seconds:%d" % uptime,
            ]),
            (b"Clients", [
                b"connected_clients:%d" % store.conn_count,
                b"blocked_clients:0",
            ]),
            (b"Memory", [
                b"used_memory:1048576",
                b"used_memory_human:1.00M",
                b"maxmemory:0",
                b"maxmemory_policy:noeviction",
            ]),
            (b"Stats", [
                b"total_connections_received:%d" % store.conn_count,
                b"total_commands_processed:%d" % store.cmd_count,
                b"expired_keys:0",
                b"keyspace_hits:0",
                b"keyspace_misses:0",
            ]),
            (b"Keyspace", [
                b"db0:keys=%d,expires=%d,avg_ttl=0" % (d0, len(store.dbs[0].expires)),
                b"db1:keys=%d,expires=%d,avg_ttl=0" % (d1, len(store.dbs[1].expires)),
            ]),
        ]
        want = args[1].lower() if len(args) > 1 else b""
        if want and want not in (b"all", b"everything", b"default"):
            sections = [s for s in sections if s[0].lower() == want]
        lines = []
        for name, body in sections:
            lines.append(b"# " + name)
            lines.extend(body)
            lines.append(b"")
        text = b"\r\n".join(lines) + b"\r\n"
        return enc_bulk(text), "bulk"

    def _live_keys(self, db):
        now = time.time()
        for k in list(db.expires):
            if db.expires[k] <= now:
                db.data.pop(k, None)
                db.expires.pop(k, None)
        return sorted(db.data.keys())

    def c_dbsize(self, args):
        return enc_int(len(self._live_keys(self._db()))), "integer"

    def c_config(self, args):
        if len(args) >= 2 and args[1].upper() == b"GET":
            param = args[2] if len(args) > 2 else b""
            if param.lower() == b"maxmemory":
                return enc_array([enc_bulk(b"maxmemory"), enc_bulk(b"0")]), "array"
            return enc_array([]), "array"
        return self._ok()

    def c_slowlog(self, args):
        sub = args[1].upper() if len(args) > 1 else b""
        if sub != b"GET":
            return enc_array([]), "array"
        n = 2
        if len(args) > 2:
            try:
                n = max(0, min(2, int(args[2])))
            except ValueError:
                n = 2
        def entry(i, ts, dur, cmd_args):
            return enc_array([
                enc_int(i),                         # 唯一 id
                enc_int(ts),                        # 发生时间（unix 秒）
                enc_int(dur),                       # 耗时（微秒）
                enc_array([enc_bulk(a) for a in cmd_args]),  # 参数数组
                enc_bulk(b"127.0.0.1:0"),           # 客户端地址
                enc_bulk(b""),                      # 客户端名
            ])
        recs = [
            entry(1, int(self.store.start), 321, [b"GET", b"user:1"]),
            entry(2, int(self.store.start) + 1, 1543, [b"ZRANGE", b"board:score", b"0", b"-1"]),
        ]
        return enc_array(recs[:n]), "array"

    def c_flushdb(self, args):
        db = self._db()
        db.data.clear()
        db.expires.clear()
        return self._ok()

    # ---- 键空间

    def c_type(self, args):
        if len(args) < 2:
            return self._need(args, 2, b"type")
        return enc_simple(self._keytype(args[1])), "simple"

    def c_ttl(self, args):
        if len(args) < 2:
            return self._need(args, 2, b"ttl")
        ms = self._ttl_ms(args[1])
        if ms < 0:
            return enc_int(ms), "integer"
        return enc_int((ms + 500) // 1000), "integer"

    def c_pttl(self, args):
        if len(args) < 2:
            return self._need(args, 2, b"pttl")
        return enc_int(self._ttl_ms(args[1])), "integer"

    def c_exists(self, args):
        n = sum(1 for k in args[1:] if self._live(k) is not None)
        return enc_int(n), "integer"

    def c_del(self, args):
        db = self._db()
        n = 0
        for k in args[1:]:
            if self._live(k, db) is not None:
                db.data.pop(k, None)
                db.expires.pop(k, None)
                n += 1
        return enc_int(n), "integer"

    def c_rename(self, args):
        if len(args) < 3:
            return self._need(args, 3, b"rename")
        db = self._db()
        src, dst = args[1], args[2]
        val = self._live(src, db)
        if val is None:
            return self._err(b"ERR no such key")
        db.data.pop(src, None)
        exp = db.expires.pop(src, None)
        db.data[dst] = val
        if exp is not None:
            db.expires[dst] = exp
        else:
            db.expires.pop(dst, None)
        return self._ok()

    def c_expire(self, args):
        if len(args) < 3:
            return self._need(args, 3, b"expire")
        db = self._db()
        if self._live(args[1], db) is None:
            return enc_int(0), "integer"
        try:
            sec = int(args[2])
        except ValueError:
            return self._err(b"ERR value is not an integer or out of range")
        if sec <= 0:
            db.data.pop(args[1], None)
            db.expires.pop(args[1], None)
            return enc_int(1), "integer"
        db.expires[args[1]] = time.time() + sec
        return enc_int(1), "integer"

    def c_persist(self, args):
        if len(args) < 2:
            return self._need(args, 2, b"persist")
        db = self._db()
        if self._live(args[1], db) is None or args[1] not in db.expires:
            return enc_int(0), "integer"
        db.expires.pop(args[1], None)
        return enc_int(1), "integer"

    def c_strlen(self, args):
        if len(args) < 2:
            return self._need(args, 2, b"strlen")
        v = self._live(args[1])
        if v is None:
            return enc_int(0), "integer"
        if not isinstance(v, bytes):
            return self._wrongtype()
        return enc_int(len(v)), "integer"

    def c_scan(self, args):
        cursor = 0
        if len(args) > 1:
            try:
                cursor = int(args[1])
            except ValueError:
                cursor = 0
        match = None
        count = 10
        type_filter = None
        i = 2
        while i < len(args):
            opt = args[i].upper()
            if opt == b"MATCH" and i + 1 < len(args):
                match = args[i + 1]
                i += 2
            elif opt == b"COUNT" and i + 1 < len(args):
                try:
                    count = max(1, int(args[i + 1]))
                except ValueError:
                    count = 10
                i += 2
            elif opt == b"TYPE" and i + 1 < len(args):
                type_filter = args[i + 1]
                i += 2
            else:
                i += 1
        keys = self._live_keys(self._db())
        batch = keys[cursor:cursor + count]
        nxt = cursor + count
        if nxt >= len(keys):
            nxt = 0
        out = []
        for k in batch:
            if match is not None and not glob_match(match, k):
                continue
            if type_filter is not None and self._keytype(k) != type_filter:
                continue
            out.append(enc_bulk(k))
        return enc_array([enc_bulk(str(nxt).encode()), enc_array(out)]), "array"

    def _scan_tail(self, args, start):
        """HSCAN/SSCAN 的命令尾：MATCH 模式 / COUNT 条数（认不出的选项跳过，跟真实 redis 的宽松一致）"""
        match = None
        count = 10
        i = start
        while i < len(args):
            opt = args[i].upper()
            if opt == b"MATCH" and i + 1 < len(args):
                match = args[i + 1]
                i += 2
            elif opt == b"COUNT" and i + 1 < len(args):
                try:
                    count = max(1, int(args[i + 1]))
                except ValueError:
                    count = 10
                i += 2
            else:
                i += 1
        return match, count

    def _scan_cursor(self, args, idx):
        try:
            return int(args[idx])
        except (IndexError, ValueError):
            return 0

    def c_hscan(self, args):
        """HSCAN key cursor [MATCH p] [COUNT n] → [cursor, [field, value, ...]]

        游标语义是**简化版**：按字段名排序后切片，游标就是切片起点（真实 redis 给的是反向二进制
        游标）。这里只要「分批能拿全、终止条件对」——被测的是客户端的收发与分页处理，不是游标算法。
        """
        if len(args) < 3:
            return self._need(args, 3, b"hscan")
        v = self._live(args[1])
        cursor = self._scan_cursor(args, 2)
        match, count = self._scan_tail(args, 3)
        if v is None or not isinstance(v, H):
            return enc_array([enc_bulk(b"0"), enc_array([])]), "array"
        fields = sorted(v.keys())
        batch = fields[cursor:cursor + count]
        nxt = cursor + count
        if nxt >= len(fields):
            nxt = 0
        out = []
        for f in batch:
            if match is not None and not glob_match(match, f):
                continue
            out.append(enc_bulk(f))
            out.append(enc_bulk(v[f]))
        return enc_array([enc_bulk(str(nxt).encode()), enc_array(out)]), "array"

    def c_sscan(self, args):
        """SSCAN key cursor [MATCH p] [COUNT n] → [cursor, [member, ...]]（游标语义同 HSCAN 的简化版）"""
        if len(args) < 3:
            return self._need(args, 3, b"sscan")
        v = self._live(args[1])
        cursor = self._scan_cursor(args, 2)
        match, count = self._scan_tail(args, 3)
        if v is None or not isinstance(v, S):
            return enc_array([enc_bulk(b"0"), enc_array([])]), "array"
        members = sorted(v)
        batch = members[cursor:cursor + count]
        nxt = cursor + count
        if nxt >= len(members):
            nxt = 0
        out = []
        for m in batch:
            if match is not None and not glob_match(match, m):
                continue
            out.append(enc_bulk(m))
        return enc_array([enc_bulk(str(nxt).encode()), enc_array(out)]), "array"

    def c_keys(self, args):
        if len(args) < 2:
            return self._need(args, 2, b"keys")
        pat = args[1]
        out = [enc_bulk(k) for k in self._live_keys(self._db()) if glob_match(pat, k)]
        return enc_array(out), "array"

    # ---- string

    def c_get(self, args):
        if len(args) < 2:
            return self._need(args, 2, b"get")
        v = self._live(args[1])
        if v is None:
            return NULL_BULK, "null"
        if not isinstance(v, bytes):
            return self._wrongtype()
        return enc_bulk(v), "bulk"

    def c_set(self, args):
        if len(args) < 3:
            return self._need(args, 3, b"set")
        db = self._db()
        key, val = args[1], args[2]
        expiry = None
        i = 3
        while i < len(args):
            opt = args[i].upper()
            if opt in (b"EX", b"PX") and i + 1 < len(args):
                try:
                    num = int(args[i + 1])
                except ValueError:
                    return self._err(b"ERR value is not an integer or out of range")
                expiry = time.time() + (num if opt == b"EX" else num / 1000.0)
                i += 2
            elif opt == b"NX" or opt == b"XX" or opt == b"KEEPTTL":
                i += 1
            else:
                i += 1
        db.data[key] = val
        if expiry is not None:
            db.expires[key] = expiry
        return self._ok()

    def c_setex(self, args):
        if len(args) < 4:
            return self._need(args, 4, b"setex")
        db = self._db()
        try:
            sec = int(args[2])
        except ValueError:
            return self._err(b"ERR value is not an integer or out of range")
        db.data[args[1]] = args[3]
        db.expires[args[1]] = time.time() + sec
        return self._ok()

    def c_mget(self, args):
        out = []
        for k in args[1:]:
            v = self._live(k)
            out.append(enc_bulk(v) if isinstance(v, bytes) else NULL_BULK)
        return enc_array(out), "array"

    def c_append(self, args):
        if len(args) < 3:
            return self._need(args, 3, b"append")
        db = self._db()
        v = self._live(args[1], db)
        if v is None:
            v = b""
        elif not isinstance(v, bytes):
            return self._wrongtype()
        v = v + args[2]
        db.data[args[1]] = v
        return enc_int(len(v)), "integer"

    # ---- hash

    def c_hgetall(self, args):
        if len(args) < 2:
            return self._need(args, 2, b"hgetall")
        v = self._live(args[1])
        if v is None:
            return enc_array([]), "array"
        if not isinstance(v, H):
            return self._wrongtype()
        items = []
        for f, val in v.items():
            items.append(enc_bulk(f))
            items.append(enc_bulk(val))
        return enc_array(items), "array"

    def c_hset(self, args):
        if len(args) < 4 or (len(args) - 2) % 2 != 0:
            return self._need(args, 4, b"hset")
        db = self._db()
        v = self._live(args[1], db)
        if v is None:
            v = H()
            db.data[args[1]] = v
        elif not isinstance(v, H):
            return self._wrongtype()
        added = 0
        rest = args[2:]
        for i in range(0, len(rest), 2):
            if rest[i] not in v:
                added += 1
            v[rest[i]] = rest[i + 1]
        return enc_int(added), "integer"

    def c_hdel(self, args):
        if len(args) < 3:
            return self._need(args, 3, b"hdel")
        v = self._live(args[1])
        if v is None:
            return enc_int(0), "integer"
        if not isinstance(v, H):
            return self._wrongtype()
        n = 0
        for f in args[2:]:
            if f in v:
                del v[f]
                n += 1
        return enc_int(n), "integer"

    def c_hlen(self, args):
        if len(args) < 2:
            return self._need(args, 2, b"hlen")
        v = self._live(args[1])
        if v is None:
            return enc_int(0), "integer"
        if not isinstance(v, H):
            return self._wrongtype()
        return enc_int(len(v)), "integer"

    def c_hget(self, args):
        if len(args) < 3:
            return self._need(args, 3, b"hget")
        v = self._live(args[1])
        if v is None:
            return NULL_BULK, "null"
        if not isinstance(v, H):
            return self._wrongtype()
        val = v.get(args[2])
        return (enc_bulk(val) if val is not None else NULL_BULK), ("bulk" if val is not None else "null")

    def c_hexists(self, args):
        if len(args) < 3:
            return self._need(args, 3, b"hexists")
        v = self._live(args[1])
        if v is None:
            return enc_int(0), "integer"
        if not isinstance(v, H):
            return self._wrongtype()
        return enc_int(1 if args[2] in v else 0), "integer"

    # ---- list

    def _norm_range(self, ln, start, stop):
        if start < 0:
            start += ln
        if stop < 0:
            stop += ln
        start = max(0, start)
        stop = min(ln - 1, stop)
        return start, stop

    def c_lrange(self, args):
        if len(args) < 4:
            return self._need(args, 4, b"lrange")
        v = self._live(args[1])
        if v is None:
            return enc_array([]), "array"
        if not isinstance(v, L):
            return self._wrongtype()
        try:
            start, stop = int(args[2]), int(args[3])
        except ValueError:
            return self._err(b"ERR value is not an integer or out of range")
        start, stop = self._norm_range(len(v), start, stop)
        if start > stop:
            return enc_array([]), "array"
        return enc_array([enc_bulk(x) for x in v[start:stop + 1]]), "array"

    def _push(self, args, left):
        if len(args) < 3:
            return self._need(args, 3, b"lpush" if left else b"rpush")
        db = self._db()
        v = self._live(args[1], db)
        if v is None:
            v = L()
            db.data[args[1]] = v
        elif not isinstance(v, L):
            return self._wrongtype()
        if left:
            for x in args[2:]:
                v.insert(0, x)
        else:
            for x in args[2:]:
                v.append(x)
        return enc_int(len(v)), "integer"

    def c_lpush(self, args):
        return self._push(args, True)

    def c_rpush(self, args):
        return self._push(args, False)

    def c_llen(self, args):
        if len(args) < 2:
            return self._need(args, 2, b"llen")
        v = self._live(args[1])
        if v is None:
            return enc_int(0), "integer"
        if not isinstance(v, L):
            return self._wrongtype()
        return enc_int(len(v)), "integer"

    def c_lset(self, args):
        if len(args) < 4:
            return self._need(args, 4, b"lset")
        v = self._live(args[1])
        if v is None:
            return self._err(b"ERR no such key")
        if not isinstance(v, L):
            return self._wrongtype()
        try:
            idx = int(args[2])
        except ValueError:
            return self._err(b"ERR value is not an integer or out of range")
        if idx < 0:
            idx += len(v)
        if idx < 0 or idx >= len(v):
            return self._err(b"ERR index out of range")
        v[idx] = args[3]
        return self._ok()

    def c_lrem(self, args):
        if len(args) < 4:
            return self._need(args, 4, b"lrem")
        v = self._live(args[1])
        if v is None:
            return enc_int(0), "integer"
        if not isinstance(v, L):
            return self._wrongtype()
        try:
            cnt = int(args[2])
        except ValueError:
            return self._err(b"ERR value is not an integer or out of range")
        target = args[3]
        removed = 0
        if cnt == 0:
            keep = [x for x in v if x != target]
            removed = len(v) - len(keep)
            v[:] = keep
        elif cnt > 0:
            keep = []
            for x in v:
                if x == target and removed < cnt:
                    removed += 1
                else:
                    keep.append(x)
            v[:] = keep
        else:
            limit = -cnt
            keep = []
            for x in reversed(v):
                if x == target and removed < limit:
                    removed += 1
                else:
                    keep.append(x)
            v[:] = list(reversed(keep))
        return enc_int(removed), "integer"

    def c_lpop(self, args):
        if len(args) < 2:
            return self._need(args, 2, b"lpop")
        v = self._live(args[1])
        if v is None:
            if len(args) > 2:
                return enc_array([]), "array"
            return NULL_BULK, "null"
        if not isinstance(v, L):
            return self._wrongtype()
        if len(args) > 2:
            try:
                cnt = max(0, int(args[2]))
            except ValueError:
                return self._err(b"ERR value is not an integer or out of range")
            taken = [v.pop(0) for _ in range(min(cnt, len(v)))]
            return enc_array([enc_bulk(x) for x in taken]), "array"
        if not v:
            return NULL_BULK, "null"
        return enc_bulk(v.pop(0)), "bulk"

    # ---- set

    def c_smembers(self, args):
        if len(args) < 2:
            return self._need(args, 2, b"smembers")
        v = self._live(args[1])
        if v is None:
            return enc_array([]), "array"
        if not isinstance(v, S):
            return self._wrongtype()
        return enc_array([enc_bulk(x) for x in sorted(v)]), "array"

    def c_sadd(self, args):
        if len(args) < 3:
            return self._need(args, 3, b"sadd")
        db = self._db()
        v = self._live(args[1], db)
        if v is None:
            v = S()
            db.data[args[1]] = v
        elif not isinstance(v, S):
            return self._wrongtype()
        added = 0
        for m in args[2:]:
            if m not in v:
                v.add(m)
                added += 1
        return enc_int(added), "integer"

    def c_srem(self, args):
        if len(args) < 3:
            return self._need(args, 3, b"srem")
        v = self._live(args[1])
        if v is None:
            return enc_int(0), "integer"
        if not isinstance(v, S):
            return self._wrongtype()
        n = 0
        for m in args[2:]:
            if m in v:
                v.discard(m)
                n += 1
        return enc_int(n), "integer"

    def c_scard(self, args):
        if len(args) < 2:
            return self._need(args, 2, b"scard")
        v = self._live(args[1])
        if v is None:
            return enc_int(0), "integer"
        if not isinstance(v, S):
            return self._wrongtype()
        return enc_int(len(v)), "integer"

    def c_sismember(self, args):
        if len(args) < 3:
            return self._need(args, 3, b"sismember")
        v = self._live(args[1])
        if v is None:
            return enc_int(0), "integer"
        if not isinstance(v, S):
            return self._wrongtype()
        return enc_int(1 if args[2] in v else 0), "integer"

    # ---- zset

    def c_zrange(self, args):
        if len(args) < 4:
            return self._need(args, 4, b"zrange")
        v = self._live(args[1])
        withscores = len(args) > 4 and args[4].upper() == b"WITHSCORES"
        if v is None:
            return enc_array([]), "array"
        if not isinstance(v, Z):
            return self._wrongtype()
        try:
            start, stop = int(args[2]), int(args[3])
        except ValueError:
            return self._err(b"ERR value is not an integer or out of range")
        items = sorted(v.items(), key=lambda kv: (kv[1], kv[0]))
        start, stop = self._norm_range(len(items), start, stop)
        if start > stop:
            return enc_array([]), "array"
        out = []
        for member, score in items[start:stop + 1]:
            out.append(enc_bulk(member))
            if withscores:
                out.append(enc_bulk(fmt_score(score).encode()))
        return enc_array(out), "array"

    def c_zadd(self, args):
        if len(args) < 4 or (len(args) - 2) % 2 != 0:
            return self._need(args, 4, b"zadd")
        db = self._db()
        v = self._live(args[1], db)
        if v is None:
            v = Z()
            db.data[args[1]] = v
        elif not isinstance(v, Z):
            return self._wrongtype()
        added = 0
        rest = args[2:]
        for i in range(0, len(rest), 2):
            try:
                score = float(rest[i])
            except ValueError:
                return self._err(b"ERR value is not a valid float")
            member = rest[i + 1]
            if member not in v:
                added += 1
            v[member] = score
        return enc_int(added), "integer"

    def c_zrem(self, args):
        if len(args) < 3:
            return self._need(args, 3, b"zrem")
        v = self._live(args[1])
        if v is None:
            return enc_int(0), "integer"
        if not isinstance(v, Z):
            return self._wrongtype()
        n = 0
        for m in args[2:]:
            if m in v:
                del v[m]
                n += 1
        return enc_int(n), "integer"

    def c_zcard(self, args):
        if len(args) < 2:
            return self._need(args, 2, b"zcard")
        v = self._live(args[1])
        if v is None:
            return enc_int(0), "integer"
        if not isinstance(v, Z):
            return self._wrongtype()
        return enc_int(len(v)), "integer"

    def c_zscore(self, args):
        if len(args) < 3:
            return self._need(args, 3, b"zscore")
        v = self._live(args[1])
        if v is None:
            return NULL_BULK, "null"
        if not isinstance(v, Z):
            return self._wrongtype()
        score = v.get(args[2])
        if score is None:
            return NULL_BULK, "null"
        return enc_bulk(fmt_score(score).encode()), "bulk"

    # ---- stream

    def _next_stream_id(self, st):
        ms = int(time.time() * 1000)
        seq = 0
        if st:
            last = st[-1][0].decode()
            if b"-" in st[-1][0]:
                lms, lseq = last.split("-", 1)
                if int(lms) == ms:
                    seq = int(lseq) + 1
        return ("%d-%d" % (ms, seq)).encode()

    def c_xadd(self, args):
        if len(args) < 5:
            return self._need(args, 5, b"xadd")
        db = self._db()
        v = self._live(args[1], db)
        if v is None:
            v = Stream()
            db.data[args[1]] = v
        elif not isinstance(v, Stream):
            return self._wrongtype()
        rest = args[2:]
        # 跳过可选 MAXLEN/MINID [~|] N 之类的选项，定位 id
        i = 0
        while i < len(rest) and rest[i].upper() in (b"MAXLEN", b"MINID"):
            i += 1
            if i < len(rest) and rest[i] in (b"~", b"="):
                i += 1
            if i < len(rest):
                i += 1
        if i >= len(rest):
            return self._err(b"ERR wrong number of arguments for 'xadd' command")
        rid = rest[i]
        fields = rest[i + 1:]
        if len(fields) < 2 or len(fields) % 2 != 0:
            return self._err(b"ERR wrong number of arguments for 'xadd' command")
        if rid == b"*":
            rid = self._next_stream_id(v)
        pairs = [(fields[j], fields[j + 1]) for j in range(0, len(fields), 2)]
        v.append((rid, pairs))
        return enc_bulk(rid), "bulk"

    def c_xrange(self, args):
        if len(args) < 4:
            return self._need(args, 4, b"xrange")
        v = self._live(args[1])
        if v is None:
            return enc_array([]), "array"
        if not isinstance(v, Stream):
            return self._wrongtype()
        start, end = args[2], args[3]
        out = []
        for rid, pairs in v:
            if start != b"-" and rid < start:
                continue
            if end != b"+" and rid > end:
                continue
            flat = []
            for f, val in pairs:
                flat.append(enc_bulk(f))
                flat.append(enc_bulk(val))
            out.append(enc_array([enc_bulk(rid), enc_array(flat)]))
        return enc_array(out), "array"

    def c_xlen(self, args):
        if len(args) < 2:
            return self._need(args, 2, b"xlen")
        v = self._live(args[1])
        if v is None:
            return enc_int(0), "integer"
        if not isinstance(v, Stream):
            return self._wrongtype()
        return enc_int(len(v)), "integer"

    # ---- 发布订阅

    def _sub_count(self):
        return len(self.subs) + len(self.psubs)

    def c_subscribe(self, args):
        if len(args) < 2:
            return self._need(args, 2, b"subscribe")
        out = []
        for ch in args[1:]:
            self.subs.add(ch)
            self.pubsub.subscribe(self, ch)
            out.append(enc_array([enc_bulk(b"subscribe"), enc_bulk(ch), enc_int(self._sub_count())]))
        return b"".join(out), "array"

    def c_unsubscribe(self, args):
        chans = args[1:] if len(args) > 1 else list(self.subs)
        out = []
        if not chans:
            out.append(enc_array([enc_bulk(b"unsubscribe"), NULL_BULK, enc_int(self._sub_count())]))
        for ch in chans:
            self.subs.discard(ch)
            self.pubsub.unsubscribe(self, ch)
            out.append(enc_array([enc_bulk(b"unsubscribe"), enc_bulk(ch), enc_int(self._sub_count())]))
        return b"".join(out), "array"

    def c_psubscribe(self, args):
        if len(args) < 2:
            return self._need(args, 2, b"psubscribe")
        out = []
        for pat in args[1:]:
            self.psubs.add(pat)
            self.pubsub.psubscribe(self, pat)
            out.append(enc_array([enc_bulk(b"psubscribe"), enc_bulk(pat), enc_int(self._sub_count())]))
        return b"".join(out), "array"

    def c_punsubscribe(self, args):
        pats = args[1:] if len(args) > 1 else list(self.psubs)
        out = []
        if not pats:
            out.append(enc_array([enc_bulk(b"punsubscribe"), NULL_BULK, enc_int(self._sub_count())]))
        for pat in pats:
            self.psubs.discard(pat)
            self.pubsub.punsubscribe(self, pat)
            out.append(enc_array([enc_bulk(b"punsubscribe"), enc_bulk(pat), enc_int(self._sub_count())]))
        return b"".join(out), "array"

    def c_publish(self, args):
        if len(args) < 3:
            return self._need(args, 3, b"publish")
        ch, payload = args[1], args[2]
        n = self.pubsub.publish(ch, payload)
        self.log("PUBLISH push ch=%s subscribers=%d" % (fmt_arg(ch), n))
        return enc_int(n), "integer"


# ---------------------------------------------------------------- 服务端与入口


def serve(port, log, on_ready=None):
    """监听并把每条连接交给一个线程；on_ready(实际端口) 在 accept 之前回调（自检靠它拿端口）。"""
    store = Store()
    pubsub = PubSub()
    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind(("127.0.0.1", port))
    srv.listen(16)
    real_port = srv.getsockname()[1]
    store.port = real_port
    store.start = time.time()
    # 就绪判定靠这一行，格式必须精确
    log("listening on 127.0.0.1:%d" % real_port)
    if on_ready:
        on_ready(real_port)
    while True:
        conn, addr = srv.accept()
        peer = "%s:%d" % (addr[0], addr[1])
        log("client connected %s" % peer)
        store.conn_count += 1
        Session(conn, peer, store, pubsub, log).start()


# ---------------------------------------------------------------- 自检


class RawClient:
    """自检用的裸 socket 客户端（不许依赖 redis-cli）。"""

    def __init__(self, port, timeout=5):
        self.sock = socket.create_connection(("127.0.0.1", port), timeout=timeout)
        self.conn = Conn(self.sock)

    def cmd(self, *args):
        send_command(self.sock, list(args))
        return read_reply(self.conn)


def selftest():
    """自检：本进程起服务端，再用裸 socket 走一轮，逐步断言 10 项。

    为什么值得写：这个脚本是 E2E 的**对端**——对端自己有 bug 时，现象是「应用侧看着没问题、
    断言却对不上」，而那时人已经在怀疑被测代码了。自检先把「对端本身是对的」这件事钉住。
    """
    log = Log()
    ready = {}
    threading.Thread(target=serve, args=(0, log, lambda p: ready.setdefault("port", p)),
                     daemon=True).start()
    deadline = time.time() + 5
    while "port" not in ready and time.time() < deadline:
        time.sleep(0.02)
    if "port" not in ready:
        log("selftest failed 0/10 mock-redis 没起来（5s 内未监听）")
        return 1
    port = ready["port"]
    passed = [0]

    def report(n, ok, desc):
        log("selftest %d/12 %s %s" % (n, "PASS" if ok else "FAIL", desc))
        if ok:
            passed[0] += 1

    c = RawClient(port)

    # ① PING → PONG
    kind, val = c.cmd(b"PING")
    report(1, kind == "simple" and val == b"PONG", "PING → PONG")

    # ② SELECT 1 → OK，DBSIZE 变 1
    k1, v1 = c.cmd(b"SELECT", b"1")
    k2, v2 = c.cmd(b"DBSIZE")
    report(2, k1 == "simple" and v1 == b"OK" and k2 == "integer" and v2 == 1,
           "SELECT 1 → OK 且 DBSIZE=1")

    # ③ SELECT 0 后 SCAN 0 COUNT 100 拿到全部 14 个 key
    c.cmd(b"SELECT", b"0")
    k3, v3 = c.cmd(b"SCAN", b"0", b"COUNT", b"100")
    # v3 = [cursor_reply, keys_array_reply]
    keys = [e[1] for e in v3[1][1]] if k3 == "array" and len(v3) == 2 else []
    report(3, k3 == "array" and len(keys) == 14, "SCAN 0 COUNT 100 返回 14 个 key（实为 %d）" % len(keys))

    # ④ TYPE / TTL 语义
    kt, vt = c.cmd(b"TYPE", b"user:1")
    kt2, vt2 = c.cmd(b"TTL", b"cache:temp")
    kt3, vt3 = c.cmd(b"TTL", b"cache:persist")
    kt4, vt4 = c.cmd(b"TTL", b"no:such:key")
    report(4, vt == b"string" and vt2 > 0 and vt3 == -1 and vt4 == -2,
           "TYPE user:1=string / TTL cache:temp>0 / TTL cache:persist=-1 / TTL 不存在=-2")

    # ⑤ GET 存在与不存在
    kg, vg = c.cmd(b"GET", b"user:1")
    km, vm = c.cmd(b"GET", b"no:such:key")
    report(5, kg == "bulk" and vg == b"alice" and km == "null" and vm is None,
           "GET user:1=alice / GET 不存在=null bulk")

    # ⑥ HGETALL 含 name/alice
    kh, vh = c.cmd(b"HGETALL", b"user:1:profile")
    flat = [e[1] for e in vh] if kh == "array" else []
    report(6, kh == "array" and b"name" in flat and b"alice" in flat,
           "HGETALL user:1:profile 含 name/alice")

    # ⑦ LRANGE 长度 3
    kl, vl = c.cmd(b"LRANGE", b"queue:jobs", b"0", b"-1")
    report(7, kl == "array" and len(vl) == 3, "LRANGE queue:jobs 0 -1 长度 3（实为 %d）"
           % (len(vl) if kl == "array" else -1))

    # ⑧ ZRANGE WITHSCORES 含 alice/12.5
    kz, vz = c.cmd(b"ZRANGE", b"board:score", b"0", b"-1", b"WITHSCORES")
    zflat = [e[1] for e in vz] if kz == "array" else []
    report(8, kz == "array" and b"alice" in zflat and b"12.5" in zflat,
           "ZRANGE board:score 0 -1 WITHSCORES 含 alice/12.5")

    # ⑨ XRANGE 长度 2
    kx, vx = c.cmd(b"XRANGE", b"events:app", b"-", b"+")
    report(9, kx == "array" and len(vx) == 2, "XRANGE events:app - + 长度 2（实为 %d）"
           % (len(vx) if kx == "array" else -1))

    # ⑩ 订阅 news.live，用第二个连接 PUBLISH，订阅连接收到 [message, news.live, …]
    sub = RawClient(port)
    ks, vs = sub.cmd(b"SUBSCRIBE", b"news.live")
    sub_ok = (ks == "array" and len(vs) == 3
              and vs[0] == ("bulk", b"subscribe") and vs[1] == ("bulk", b"news.live"))
    pub = RawClient(port)
    kp, vp = pub.cmd(b"PUBLISH", b"news.live", b"hello-pubsub")
    km2, msg = read_reply(sub.conn)
    push_ok = (km2 == "array" and len(msg) == 3
               and msg[0] == ("bulk", b"message")
               and msg[1] == ("bulk", b"news.live")
               and msg[2] == ("bulk", b"hello-pubsub"))
    report(10, sub_ok and kp == "integer" and vp == 1 and push_ok,
           "SUBSCRIBE news.live + PUBLISH → 收到 [message, news.live, payload] push")

    # ⑪ HSCAN 游标分页：user:1:profile 3 字段，COUNT 2 先给 2 对且游标非 0
    khc, vhc = c.cmd(b"HSCAN", b"user:1:profile", b"0", b"COUNT", b"2")
    hc_ok = False
    if khc == "array" and len(vhc) == 2:
        hc_flat = [e[1] for e in vhc[1][1]] if vhc[1][0] == "array" else []
        hc_ok = len(hc_flat) == 4 and vhc[0][1] != b"0"
    report(11, hc_ok, "HSCAN user:1:profile 0 COUNT 2 → 2 对字段且游标非 0")

    # ⑫ SSCAN：tags:news 3 成员，COUNT 100 一页拿全且游标归 0
    ksc, vsc = c.cmd(b"SSCAN", b"tags:news", b"0", b"COUNT", b"100")
    sc_flat = [e[1] for e in vsc[1][1]] if (ksc == "array" and len(vsc) == 2
                                            and vsc[1][0] == "array") else []
    report(12, ksc == "array" and len(sc_flat) == 3 and vsc[0][1] == b"0",
           "SSCAN tags:news 0 COUNT 100 → 3 个成员且游标归 0（实为 %d）" % len(sc_flat))

    if passed[0] == 12:
        log("selftest passed 12/12")
    else:
        log("selftest failed %d/12" % passed[0])
    return 0 if passed[0] == 12 else 1


def main(argv):
    ap = argparse.ArgumentParser(description="cj-tauri E2E 用的 mock Redis 服务端（RESP2）")
    ap.add_argument("--port", type=int, default=6379, help="监听端口（0 = 系统分配，自检用）")
    ap.add_argument("--log", default="", help="另存一份日志到这个文件（无人值守脚本 grep 它）")
    ap.add_argument("--selftest", action="store_true", help="跑自检后退出")
    args = ap.parse_args(argv)
    if args.selftest:
        return selftest()
    log = Log(args.log if args.log else None)
    serve(args.port, log)
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv[1:]))
    except KeyboardInterrupt:
        sys.exit(0)
