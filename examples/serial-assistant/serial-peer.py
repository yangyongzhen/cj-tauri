#!/usr/bin/env python3
"""虚拟串口对端：给 serial 示例（examples/plugin-serial / examples/serial-assistant）的实机验证当"另一头的设备"。

为什么是 pty 而不是 socat：socat 的 `pty,raw,echo=0` 造的就是内核 pty，本机没装 socat 时
用 python 标准库开一对等价；而且**回包时机由本脚本说了算**，比 `exec:cat` 那种回显更好断言。

行为：
  1. 开一对 pty（内核对象），把**从端**（/dev/pts/N）路径写进 argv[1] 指定的文件，调用方等它就绪；
  2. 从端设为 raw 115200 8N1（应用自己也会设一遍；termios 是 per-tty 的，两边设同一个东西）；
  3. 循环读主端：应用写进来的字节落到 argv[2]（**这是"真的写到了线路上"的外部证据**），
     并回一帧 `PONG:<原样>` —— 应用随即读到的就是它；
  4. 空闲超过 --idle-exit 秒（或跑满 --max-life 秒）自行退出，调用方也会兜底 kill。

用法：
  python3 serial-peer.py <从端路径文件> <收到字节的落盘文件> [--idle-exit 20] [--max-life 90]
"""

import argparse
import os
import select
import sys
import termios
import time


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("dev_file", help="把 /dev/pts/N 写到这里，调用方据此设置 CJ_SERIAL_PROBE_PATH")
    ap.add_argument("rx_file", help="把应用写进来的原始字节追加到这里")
    ap.add_argument("--idle-exit", type=float, default=20.0, help="无数据这么久后退出（秒）")
    ap.add_argument("--max-life", type=float, default=90.0, help="总时长上限（秒）")
    args = ap.parse_args()

    master, slave = os.openpty()
    name = os.ttyname(slave)

    # 从端 raw 115200 8N1：pty 不真跑波特率，但保持与应用侧 settings 一致，便于对照日志
    iflag, oflag, cflag, lflag, ispeed, ospeed, cc = termios.tcgetattr(slave)
    cflag = termios.CS8 | termios.CREAD | termios.CLOCAL
    cc = list(cc)
    cc[termios.VMIN] = 1
    cc[termios.VTIME] = 0
    termios.tcsetattr(slave, termios.TCSANOW,
                      [0, 0, cflag, 0, termios.B115200, termios.B115200, cc])
    # 从端 fd 一直开着：pty 从端在全关时才销毁，也保证主端读到的是"应用写进来的"
    print("[peer] pty ready slave=%s" % name, file=sys.stderr, flush=True)

    with open(args.dev_file, "w", encoding="utf-8") as f:
        f.write(name)
        f.flush()
        os.fsync(f.fileno())

    started = time.time()
    last = time.time()
    with open(args.rx_file, "wb") as rx:
        while True:
            now = time.time()
            if now - started > args.max_life:
                print("[peer] max-life reached, exit", file=sys.stderr, flush=True)
                return 0
            if now - last > args.idle_exit:
                print("[peer] idle %.1fs, exit" % (now - last), file=sys.stderr, flush=True)
                return 0
            r, _, _ = select.select([master], [], [], 0.5)
            if not r:
                continue
            try:
                data = os.read(master, 4096)
            except OSError as e:
                print("[peer] read error: %s" % e, file=sys.stderr, flush=True)
                return 0
            if not data:
                continue
            last = time.time()
            rx.write(data)
            rx.flush()
            reply = b"PONG:" + data
            try:
                os.write(master, reply)
            except OSError as e:
                print("[peer] write error: %s" % e, file=sys.stderr, flush=True)
                return 0
            print("[peer] rx=%d bytes, replied %d bytes" % (len(data), len(reply)),
                  file=sys.stderr, flush=True)


if __name__ == "__main__":
    sys.exit(main())
