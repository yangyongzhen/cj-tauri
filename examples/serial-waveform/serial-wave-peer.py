#!/usr/bin/env python3
"""虚拟示波器对端：给 examples/serial-waveform 的实机验证当「会吐数据的那台设备」。

为什么用 pty 而不是 socat：socat 造的也是内核 pty，本机没装 socat 时用 python 标准库开一对等价；
而且**什么时候吐数据、吐什么样的数据由本脚本说了算**，波形与统计才有可断言的确定形状
（真接一台仪器上来，值域与速率都是不可预知的）。

协议（ASCII 行协议 —— 真实仪器里最常见的那一种，本示例按它解析）：
  应用 → 设备:  "SCAN" 开始连续输出 ; "STOP" 停止
  设备 → 应用:  每行 "<序号>,<值>"，值域 -1.0..1.0，正弦 + 定种子噪声

用法:
  python3 serial-wave-peer.py <从端路径文件> [--rx-file F] [--hz 60] [--seed 7]
                              [--idle-exit 20] [--max-life 90]
  --rx-file 把应用写进来的原始字节落到该文件（「SCAN 真的写到了线路上」的外部证据）
"""

import argparse
import math
import os
import random
import select
import sys
import termios
import time


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("dev_file", help="把 /dev/pts/N 写到这里，调用方据此设置 CJ_SERIAL_PROBE_PATH")
    ap.add_argument("--rx-file", default="", help="把应用写进来的原始字节追加到这里（可省）")
    ap.add_argument("--hz", type=float, default=60.0, help="目标输出频率（样本/秒）")
    ap.add_argument("--seed", type=int, default=7, help="噪声种子（固定种子 = 可复现的波形）")
    ap.add_argument("--idle-exit", type=float, default=20.0, help="无数据这么久后退出（秒）")
    ap.add_argument("--max-life", type=float, default=90.0, help="总时长上限（秒）")
    args = ap.parse_args()

    master, slave = os.openpty()
    name = os.ttyname(slave)

    # 从端 raw 115200 8N1：pty 不真跑波特率，但与应用侧 settings 保持一致，日志里好对照
    _iflag, _oflag, cflag, _lflag, _ispeed, _ospeed, cc = termios.tcgetattr(slave)
    cflag = termios.CS8 | termios.CREAD | termios.CLOCAL
    cc = list(cc)
    cc[termios.VMIN] = 1
    cc[termios.VTIME] = 0
    termios.tcsetattr(slave, termios.TCSANOW,
                      [0, 0, cflag, 0, termios.B115200, termios.B115200, cc])
    # 从端 fd 一直开着：pty 从端全关时才销毁，也保证主端读到的是「应用写进来的」
    print("[peer] pty ready slave=%s hz=%g" % (name, args.hz), file=sys.stderr, flush=True)

    with open(args.dev_file, "w", encoding="utf-8") as f:
        f.write(name)
        f.flush()
        os.fsync(f.fileno())

    rx = open(args.rx_file, "ab") if args.rx_file else None
    rng = random.Random(args.seed)
    started = time.time()
    last_rx = time.time()
    scanning = False
    seq = 0
    period = 1.0 / args.hz if args.hz > 0 else 0.016
    next_at = 0.0
    buf = b""

    try:
        while True:
            now = time.time()
            if now - started > args.max_life:
                print("[peer] max-life reached, exit", file=sys.stderr, flush=True)
                return 0
            if now - last_rx > args.idle_exit:
                print("[peer] idle %.1fs, exit" % (now - last_rx), file=sys.stderr, flush=True)
                return 0

            # 先收：SCAN / STOP 是应用的指令，收到就切换输出状态
            r, _, _ = select.select([master], [], [], 0.02)
            if r:
                try:
                    data = os.read(master, 4096)
                except OSError as e:
                    print("[peer] read error: %s" % e, file=sys.stderr, flush=True)
                    return 1
                if not data:
                    continue
                last_rx = time.time()
                if rx:
                    rx.write(data)
                    rx.flush()
                buf += data
                while b"\n" in buf:
                    line, buf = buf.split(b"\n", 1)
                    cmd = line.decode("utf-8", "replace").strip().upper()
                    if cmd == "SCAN":
                        scanning = True
                        next_at = time.time()
                        print("[peer] SCAN -> 开始输出 %g Hz 样本流" % args.hz,
                              file=sys.stderr, flush=True)
                    elif cmd == "STOP":
                        scanning = False
                        print("[peer] STOP -> 暂停输出", file=sys.stderr, flush=True)

            # 再发：把「到点该发」的样本一次补齐。
            # 注意别写成"每轮发一个"——select 的超时是 20ms，那样实际速率会被循环周期卡在 ~50/s，
            # 与 --hz 请求的值差一个数量级（实测：请求 400 Hz、应用侧只量到 49.3/s）。
            # 每轮上限 256 个：万一卡顿很久也不做爆发式追赶；落后 1 秒以上就重新对时。
            if scanning:
                burst = 0
                while now >= next_at and burst < 256:
                    v = math.sin(seq * 2.0 * math.pi / 120.0) + rng.uniform(-0.03, 0.03)
                    try:
                        os.write(master, ("%d,%.4f\n" % (seq, v)).encode("ascii"))
                    except OSError as e:
                        print("[peer] write error: %s" % e, file=sys.stderr, flush=True)
                        return 1
                    seq += 1
                    next_at += period
                    burst += 1
                if now - next_at > 1.0:
                    next_at = now
    finally:
        if rx:
            rx.close()


if __name__ == "__main__":
    sys.exit(main())
