#!/usr/bin/env bash
# test-bridge-core.sh — C 桥公共核心（native/bridge_core.c）的自检
#
# 不需要仓颉 SDK，也不需要 GTK / WebKit / WebView2：用一个「只记录调用」的桩平台实现
# bridge_core.h 里的 18 个 cj_plat_* 原语，再把 core 与桩一起编译成单文件可执行程序——
# 链接期就能证明 core 只经 cj_plat_* 触达平台、不 include 任何平台头（批次 1 的分层契约）。
#
# 覆盖：回投队列与批处理（单条快路径 / 多条拼批 / 批上限 64 + 自续唤醒）、
#       对话框单槽状态机（未就绪拒绝 / UI 线程快路径 / abort 幂等）、
#       窗口配置与预执行脚本存储、quit 与 window_destroyed 的生命周期标志、导出对 NULL 安全。
#
# 用法：bash scripts/test-bridge-core.sh
# 退出码：0 = 通过（或本机没有 C 编译器，跳过）；1 = 编译失败或有断言失败
#
# 坑：必须带 -pthread（core 的同步原语由桩用 pthread 实现）；
#     -std=c99 下 strdup 要先 define _POSIX_C_SOURCE（测试文件自己带上了）。
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT" || exit 1

CC="${CC:-cc}"
if ! command -v "$CC" >/dev/null 2>&1; then
    echo "[bridge-core] 本机没有 C 编译器（$CC），跳过自检"
    exit 0
fi

TMPDIR_RUN="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_RUN"' EXIT
BIN="$TMPDIR_RUN/test_bridge_core"

if ! "$CC" -std=c99 -Wall -Wextra -pthread -O1 -g -I native \
        -o "$BIN" native/tests/test_bridge_core.c native/bridge_core.c; then
    echo "[FAIL] bridge_core 自检编译失败" >&2
    exit 1
fi

if ! "$BIN"; then
    echo "[FAIL] bridge_core 自检有失败项（明细见上）" >&2
    exit 1
fi
echo "[OK] bridge_core 自检通过（native/bridge_core.c，桩平台，无需 SDK / 图形栈）"
