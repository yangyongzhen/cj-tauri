#!/usr/bin/env bash
# ============================================================
# cj-Link（examples/cj-link）—— Linux 侧实机验证
#
# 验的是「二合一助手」两条业务链：串口（参数面板 → serial 插件 → C 桥 termios → 真实 pty）
# 与 TCP（连接面板 → link:tcp* → std.net → 本机 echo 服务）。两个「对端」由 cj-link-peer.py
# 一条进程扮演：串口 echo 回包 + TCP echo 服务，收发证据都落在应用进程之外（rx 文件 / 对端日志）。
#
# 前置：桥已构建（bash native/build_linux.sh）；需要 python3（标准库即可）。
# 用法：bash run.sh [日志路径]（默认 /tmp/cj-link.log）
# ============================================================
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
LOG="${1:-/tmp/cj-link.log}"
APP="$HERE/target/release/bin/main"
BRIDGE="$ROOT/native/libcjtbridge.so"
DEV_FILE="$LOG.dev"
RX_FILE="$LOG.rx"
PEER_LOG="$LOG.peer"
TCP_PORT="${CJ_LINK_TCP_PORT:-15021}"

CANGJIE_HOME="${CANGJIE_HOME:-/opt/cangjie/cangjie}"
CANGJIE_STDX="${CANGJIE_STDX:-/root/.cangjie/stdx/cangjie-stdx-linux-x64-1.0.5.1/dynamic/stdx}"
export CANGJIE_HOME
export CANGJIE_STDX
export PATH="$CANGJIE_HOME/bin:$CANGJIE_HOME/tools/bin:$PATH"
export LD_LIBRARY_PATH="$ROOT/native:$CANGJIE_STDX:$CANGJIE_HOME/runtime/lib/linux_x86_64_cjnative:$CANGJIE_HOME/third_party/llvm/lib:${LD_LIBRARY_PATH:-}"
export WEBKIT_DISABLE_COMPOSITING_MODE=1
export LIBGL_ALWAYS_SOFTWARE=1

if [ ! -f "$BRIDGE" ]; then
    echo "[run] 缺 $BRIDGE —— 先跑 bash native/build_linux.sh" >&2
    exit 1
fi
if ! command -v python3 >/dev/null 2>&1; then
    echo "[run] SKIP 缺 python3（本脚本用它起对端；标准库即可）" >&2
    exit 0
fi

# 显示环境不可用就自己套 Xvfb 重跑自己（不能只看 DISPLAY 设没设——SSH 转发常留一个失效的）。
if [ "${CJLINK_IN_XVFB:-}" != "1" ] \
   && { ! command -v xdotool >/dev/null 2>&1 || ! xdotool getdisplaygeometry >/dev/null 2>&1; }; then
    echo "[run] DISPLAY='${DISPLAY:-}' 打不开 -> 在 Xvfb 里重跑（1280x800x24）"
    export CJLINK_IN_XVFB=1
    exec xvfb-run -a -s "-screen 0 1280x800x24" bash "$0" "$LOG"
fi

cd "$HERE"   # 工作目录 = 工程根：capabilities/ 与 ui/ 按相对路径读

echo "[run] 构建 $HERE"
cjpm build > "$LOG.build" 2>&1 || { tail -40 "$LOG.build"; exit 1; }
if grep -qE 'warning' "$LOG.build"; then
    echo "[run] FAIL 构建有警告（AGENTS §3 零警告）"; grep -E 'warning' "$LOG.build" | head; exit 1
fi

echo "[run] 起对端（串口 pty echo + TCP echo）"
: > "$DEV_FILE"
: > "$RX_FILE"
python3 "$HERE/cj-link-peer.py" "$DEV_FILE" "$RX_FILE" "$PEER_LOG" "$TCP_PORT" &
PEER_PID=$!

DEV=""
for _ in $(seq 1 40); do
    DEV="$(tr -d '\n' < "$DEV_FILE" 2>/dev/null || true)"
    [ -n "$DEV" ] && break
    sleep 0.25
done
if [ -z "$DEV" ]; then
    echo "[run] FAIL 对端没给出从端路径 —— 看 $PEER_LOG" >&2
    cat "$PEER_LOG" >&2 || true
    kill "$PEER_PID" 2>/dev/null || true
    exit 1
fi
echo "[run] 对端从端 = $DEV ；TCP echo = 127.0.0.1:$TCP_PORT"

APP_PID=""
cleanup() {
    [ -n "$APP_PID" ] && kill "$APP_PID" 2>/dev/null || true
    kill "$PEER_PID" 2>/dev/null || true
}
trap cleanup EXIT

echo "[run] 起应用（探针模式）"
: > "$LOG"
CJ_LINK_PROBE=1 \
CJ_LINK_PROBE_SERIAL_PATH="$DEV" \
CJ_LINK_PROBE_TCP_HOST=127.0.0.1 \
CJ_LINK_PROBE_TCP_PORT="$TCP_PORT" \
CJ_LINK_PROBE_QUIT=1 \
    ./target/release/bin/main > "$LOG" 2>&1 &
APP_PID=$!

RC=99
for _ in $(seq 1 120); do
    if ! kill -0 "$APP_PID" 2>/dev/null; then break; fi
    sleep 0.5
done
set +e
wait "$APP_PID"
RC=$?
set -e
APP_PID=""
trap - EXIT
kill "$PEER_PID" 2>/dev/null || true

echo "[run] exit=$RC  log=$LOG"
echo "---- 日志取证行 ----"
grep -aE '\[cj-link\]|\[cj-bridge\] serial|\[frontend\]' "$LOG" | head -60 || true
echo "---- 对端日志 ----"
cat "$PEER_LOG" 2>/dev/null || true

FAIL=0
check() {
    if grep -aqF "$2" "$LOG"; then
        echo "  ok    $1"
    else
        echo "  FAIL  $1（缺子串: $2）"
        FAIL=1
    fi
}
absent() {
    if grep -aqF "$2" "$LOG"; then
        echo "  FAIL  $1（出现不该有的子串: $2）"
        FAIL=1
    else
        echo "  ok    $1"
    fi
}

echo "---- 断言 ----"
if [ "$RC" -eq 0 ]; then echo "  ok    干净退出（exit=0，走的是页面 invoke('quit')）"; else echo "  FAIL  退出码 $RC（124=挂死 / 134=abort）"; FAIL=1; fi
check "应用起来了"               '[cj-link] main start'
check "页面已从 ui/ 读入"         '[cj-link] 前端页面已载入'
check "探针配置已注入"           '[cj-link] 探针模式：'
check "C 桥真打开了设备节点"       '[cj-bridge] serial open: handle='
check "打开的就是对端那个从端"      "path=$DEV"
check "termios 参数落到设备上"     "serial termios: path=$DEV baud=115200 data=8 parity=0 stop=1"
check "自检：open  PASS"         'selfcheck] open: PASS'
check "自检：write PASS"         'selfcheck] write: PASS'
check "自检：read  PASS"         'selfcheck] read: PASS'
check "读回的正是对端回包"         'cj-link-ping'
check "自检：close PASS"         'selfcheck] close: PASS'
check "自检：tcpConnect PASS"    'selfcheck] tcpConnect: PASS'
check "自检：tcpSend PASS"       'selfcheck] tcpSend: PASS'
check "自检：tcpClose PASS"      'selfcheck] tcpClose: PASS'
check "探针一轮跑完"             'probe] ALL DONE'
check "收尾走应用级 quit"         'quit requested by frontend'
check "宿主已销毁"               'host destroyed'
check "run 之后有收尾日志"        'after run'
absent "没有崩溃"                'Aborted'
absent "没有段错误"              'Handle signal'
absent "没有命令误报"             'command not allowed'
absent "没有命令未注册"           'command not registered'
absent "没有打开失败"             'serial open failed'

# 对端侧证据：应用写出去的字节，真的到了「另一头」
if grep -aqF 'cj-link-ping' "$RX_FILE"; then
    echo "  ok    串口对端收到了应用写出的负载（rx 文件）"
else
    echo "  FAIL  串口对端没收到负载 —— 看 $RX_FILE 与 $PEER_LOG"
    FAIL=1
fi
if grep -aqF 'connected' "$PEER_LOG"; then
    echo "  ok    TCP 对端看到了客户端接入"
else
    echo "  FAIL  TCP 对端没看到接入 —— 看 $PEER_LOG"
    FAIL=1
fi

if [ "$FAIL" -eq 0 ]; then
    echo "[run] PASS —— 两条链路都是活的：串口（面板→serial 插件→C 桥 termios→真实 pty）+"
    echo "[run]        TCP（面板→link:tcp*→std.net→本机 echo），两端证据都在应用进程之外。"
else
    echo "[run] FAIL —— 看 $LOG / $PEER_LOG / $RX_FILE"
fi
echo "[run] app log : $LOG"
echo "[run] peer log: $PEER_LOG"
echo "[run] rx bytes: $RX_FILE"
exit "$FAIL"
