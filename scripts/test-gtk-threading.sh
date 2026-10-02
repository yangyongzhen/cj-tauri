#!/usr/bin/env bash
# 多窗口可行性最小对照的复现器（见 docs/架构演进-多平台与多窗口.md §8）
#
# 它跑四组：N=1 / N=2（纯 GTK）、N=1 / N=2（GTK+WebKit，各线程一个 WebView），
# 然后**对照 §8 记录的结论**给出判定：
#   N=1 两种  → 期望 exit=0
#   N=2 纯 GTK → 期望 exit=0   （GTK 本身不反对两条各自的 gtk_main）
#   N=2+WebKit → 期望**非 0**（WebKitGTK 不能被两条线程各自使用，这就是约束本身）。
#                实测 8/8 失败：多数 exit=139（SIGSEGV）+ Gtk-CRITICAL，早先 /tmp 变体是
#                exit=134（abort），也可能表现为进程卡在初始化里（探针超时 → exit=3）
# 退出码：0 = 与 §8 记录一致；1 = 不一致（若 N=2+WebKit 反而干净通过，说明约束可能已消失，请复核 §8）。
#
# 不需要仓颉 SDK；缺 gcc / GTK / WebKit 开发包或 xvfb-run 时自行跳过（exit 0）。
# 用法: bash scripts/test-gtk-threading.sh [工作目录，默认 /tmp]
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="${1:-/tmp}"
BIN="$WORK/gtk-threading-probe"
LOG="$WORK/gtk-threading-probe.log"

skip() {
    echo "[gtk-threading] 跳过：$1"
    exit 0
}

command -v cc >/dev/null 2>&1 || skip "本机没有 C 编译器"
pkg-config --exists gtk+-3.0 || skip "本机没有 GTK3 开发包（gtk+-3.0.pc）"
pkg-config --exists webkit2gtk-4.1 || skip "本机没有 WebKitGTK 开发包（webkit2gtk-4.1.pc）"
command -v xvfb-run >/dev/null 2>&1 || skip "本机没有 xvfb-run"

echo "[gtk-threading] 编译 $BIN"
cc "$ROOT/native/tests/gtk_threading_probe.c" -o "$BIN" \
   -DCJ_GTK_PROBE_WITH_WEBKIT \
   $(pkg-config --cflags --libs webkit2gtk-4.1) -lpthread || skip "编译失败"

# 无显示环境时用 Xvfb；有 DISPLAY 就直接跑
run_one() {  # run_one <描述> <期望:clean|crash> <N> [--webkit]
    local desc="$1" expect="$2"; shift 2
    local rc
    export WEBKIT_DISABLE_COMPOSITING_MODE=1 LIBGL_ALWAYS_SOFTWARE=1
    if [ -n "${DISPLAY:-}" ]; then
        timeout 90 "$BIN" "$@" > "$LOG" 2>&1
    else
        timeout 90 xvfb-run -a -s "-screen 0 1024x768x24" "$BIN" "$@" > "$LOG" 2>&1
    fi
    rc=$?
    if [ "$expect" = "clean" ]; then
        if [ "$rc" -eq 0 ]; then
            echo "  ok    $desc → exit=0"; return 0
        fi
        echo "  FAIL  $desc → exit=$rc（期望干净退出）"; return 1
    fi
    if [ "$rc" -ne 0 ]; then
        echo "  ok    $desc → exit=$rc（期望：非 0），签名： $(grep -aoE 'Gtk-CRITICAL[^)]*|Pango-CRITICAL[^)]*|invalid next size|Aborted|超时' "$LOG" | head -1)"
        return 0
    fi
    echo "  FAIL  $desc → exit=0：约束似乎已消失，请复核 §8 的结论"
    return 1
}

FAIL=0
echo "[gtk-threading] 四组对照（串行起线程，排除初始化竞态）"
run_one "N=1 纯 GTK"            clean 1           || FAIL=1
run_one "N=1 GTK+WebKit"        clean 1 --webkit  || FAIL=1
run_one "N=2 纯 GTK"            clean 2           || FAIL=1
run_one "N=2 GTK+WebKit（§8 根因行）" crash 2 --webkit || FAIL=1

if [ "$FAIL" -eq 0 ]; then
    echo "[gtk-threading] 与 §8 记录一致"
else
    echo "[gtk-threading] 与 §8 记录不一致——先看 $LOG，再更新文档结论"
fi
exit "$FAIL"
