#!/usr/bin/env bash
# ============================================================
# cj-tauri 串口插件探针（examples/plugin-serial）—— Linux 侧实机验证
#
# 验的是什么：**「页面 → 桥 → IPC → 能力校验 → 插件命令 → C 桥 → 真设备节点」这一整跳是活的**，
# 而不是「函数能编过」。所以：
#   - 设备那头由 serial-peer.py 造一对内核 pty（等价于 socat 的 pty,raw,echo=0，本机没装 socat），
#     应用 open 的是从端 /dev/pts/N —— 正是白名单放行的伪终端；
#   - 应用的写入由**对端**读到并落盘（rx 文件）——这是「真的写到了线路上」的外部证据，
#     不是应用自己说「我写了」；
#   - 对端随即回一帧 `PONG:<原样>`，应用读回来的是**对端给的字节**，于是读方向的证据也来自外部；
#   - 断言用的都是桥/应用自己打的 stderr 行（诊断一律走 stderr，AGENTS §4）。
#
# 顺带验到的一条：本示例的 capabilities 用**两种写法混着**放行——
#   permissions: ["serial:readonly"]（命名权限集：open/read/close）
#   commands:    [... "serial:write"]（明文）
# 所以下面既断言 open/read/close 成功（证明命名集在装配期真展开了），
# 又静态检查清单里**没有**写死 serial:open（证明上面那条成功不是靠明文）。
#
# 前置：桥已构建（bash native/build_linux.sh）；需要 python3（标准库即可）。
# 用法：bash run.sh [日志路径]（默认 /tmp/plugin-serial-probe.log）
# ============================================================
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
LOG="${1:-/tmp/plugin-serial-probe.log}"
APP="$HERE/target/release/bin/main"
BRIDGE="$ROOT/native/libcjtbridge.so"
DEV_FILE="$LOG.dev"
RX_FILE="$LOG.rx"
PEER_LOG="$LOG.peer"

# 与 scripts/test.sh / examples/menu/run.sh 同一套环境推导
CANGJIE_HOME="${CANGJIE_HOME:-/opt/cangjie/cangjie}"
CANGJIE_STDX="${CANGJIE_STDX:-/root/.cangjie/stdx/cangjie-stdx-linux-x64-1.0.5.1/dynamic/stdx}"
export CANGJIE_HOME
export PATH="$CANGJIE_HOME/bin:$CANGJIE_HOME/tools/bin:$PATH"
# Linux 上运行时 .so 只认 LD_LIBRARY_PATH（不查 PATH），而且必须在构建之前就位：cjpm 自己也是
# 仓颉程序，缺 libcangjie-runtime.so 会直接「error while loading shared libraries」退出。
export LD_LIBRARY_PATH="$ROOT/native:$CANGJIE_STDX:$CANGJIE_HOME/runtime/lib/linux_x86_64_cjnative:$CANGJIE_HOME/third_party/llvm/lib:${LD_LIBRARY_PATH:-}"
export WEBKIT_DISABLE_COMPOSITING_MODE=1
export LIBGL_ALWAYS_SOFTWARE=1

if [ ! -f "$BRIDGE" ]; then
    echo "[run] 缺 $BRIDGE —— 先跑 bash native/build_linux.sh" >&2
    exit 1
fi
if ! command -v python3 >/dev/null 2>&1; then
    echo "[run] SKIP 缺 python3（本脚本用它起虚拟串口对端；标准库即可）" >&2
    exit 0
fi

# 显示环境不可用就自己套 Xvfb 重跑自己。**不能只看 DISPLAY 设没设**（本机 SSH 转发常留一个
# 失效的 DISPLAY），拿 xdotool 真问一句显示能不能开；xdotool 不在就当它不能用。
# SERIAL_IN_XVFB 是防自旋标记：进了 Xvfb 还打不开就不再重试。
if [ "${SERIAL_IN_XVFB:-}" != "1" ] \
   && { ! command -v xdotool >/dev/null 2>&1 || ! xdotool getdisplaygeometry >/dev/null 2>&1; }; then
    echo "[run] DISPLAY='${DISPLAY:-}' 打不开 -> 在 Xvfb 里重跑（1280x800x24）"
    export SERIAL_IN_XVFB=1
    exec xvfb-run -a -s "-screen 0 1280x800x24" "$0" "$LOG"
fi

cd "$HERE"   # 工作目录 = 工程根：capabilities/ 按相对路径读

echo "[run] 构建 $HERE"
cjpm build > "$LOG.build" 2>&1 || { tail -40 "$LOG.build"; exit 1; }

echo "[run] 起虚拟串口对端（pty）"
: > "$DEV_FILE"
: > "$RX_FILE"
python3 "$HERE/serial-peer.py" "$DEV_FILE" "$RX_FILE" --idle-exit 25 --max-life 120 \
    > "$PEER_LOG" 2>&1 &
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
echo "[run] 对端从端 = $DEV（应用要 open 的就是它）"

APP_PID=""
cleanup() {
    [ -n "$APP_PID" ] && kill "$APP_PID" 2>/dev/null || true
    kill "$PEER_PID" 2>/dev/null || true
}
trap cleanup EXIT

echo "[run] 起应用（探针模式：配置由宿主经 document-start 预执行脚本注入页面）"
: > "$LOG"
CJ_SERIAL_PROBE_PATH="$DEV" \
CJ_SERIAL_PROBE_BAUD=115200 \
CJ_SERIAL_PROBE_DATA=cj-tauri-ping \
CJ_SERIAL_PROBE_ENCODING=utf8 \
CJ_SERIAL_PROBE_READ_MS=600 \
CJ_SERIAL_PROBE_QUIT=1 \
    ./target/release/bin/main > "$LOG" 2>&1 &
APP_PID=$!

# 探针自己跑完一轮就退（页面里 invoke('quit')）：有界等它，挂死按失败算
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
grep -aE '\[plugin-serial\]|\[cj-bridge\]|\[frontend\]' "$LOG" || true
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
count_ge() {
    local n
    n="$(grep -acF "$2" "$LOG" || true)"
    if [ "$n" -ge "$3" ]; then
        echo "  ok    $1（$n 行）"
    else
        echo "  FAIL  $1（期望 ≥$3 行 \"$2\"，实到 $n 行）"
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
check "应用起来了"                '[plugin-serial] main start'
check "插件面：4 命令 2 权限集"     '[plugin-serial] 插件 serial：命令 4 条，命名权限集 2 组'
check "探针配置已注入"            "[plugin-serial] 探针模式：path=$DEV"
check "shim 早于页面脚本"          '[frontend] shim-ready-at-script-start=true'
check "插件命名空间在页面上"        '[frontend] serial-namespace-type=object'
check "C 桥真打开了设备节点"        "[cj-bridge] serial open: handle="
check "打开的就是对端那个从端"       "path=$DEV"
check "termios 参数落到设备上"      "[cj-bridge] serial termios: path=$DEV baud=115200 data=8 parity=0 stop=1"
check "命令返回句柄给前端"          '[frontend] serial:open => handle='
check "写入字节数对上"             '[frontend] serial:write => written=13/13'
check "文本回读与对端回包一致"       'text="PONG:cj-tauri-ping"'
check "hex 回读与对端回包一致"       'hex=504f4e473a636a2d74617572692d70696e67'
check "读到了对端给的 18 字节"       '[frontend] serial:read => count=18'
check "关闭返回成功"               '[frontend] serial:close => true'
check "C 桥释放了句柄"            '[cj-bridge] serial close: handle='
check "一轮探针跑完"               '[frontend] [probe] ALL DONE'
check "收尾走应用级 quit"          '[plugin-serial] quit requested by frontend'
check "宿主已销毁"                '[cj-bridge] host destroyed'
check "run 之后有收尾日志"          '[plugin-serial] after run'
absent "没有崩溃"                 'Aborted'
absent "没有段错误"               'Handle signal'
absent "没有命令误报"              'command not allowed'
absent "没有打开失败"              'serial open failed'
absent "没有读失败"               'serial read failed'

# 对端侧证据：应用写出去的字节，真的到了「另一头」
if grep -aqF 'cj-tauri-ping' "$RX_FILE"; then
    echo "  ok    对端收到了应用写出的负载（rx 文件）"
else
    echo "  FAIL  对端没收到负载 —— 看 $RX_FILE 与 $PEER_LOG"
    FAIL=1
fi

# 命名权限集的证明：清单里**没有**明文写 serial:open，它却成功了 → 靠的是 permissions 里的 serial:readonly
if grep -aqF '"serial:readonly"' capabilities/default.json \
   && ! grep -aqF '"serial:open"' capabilities/default.json; then
    echo "  ok    open/read/close 的成功来自命名权限集（清单未写明文）"
else
    echo "  FAIL  命名权限集的对照失效：清单里应只有 serial:readonly + 明文 serial:write"
    FAIL=1
fi

if [ "$FAIL" -eq 0 ]; then
    echo "[run] PASS —— Linux 上串口这一整跳是活的：页面 invoke → IPC → 能力校验 → 插件命令 →"
    echo "[run]        C 桥 termios → 真实 pty 设备节点；写入由对端读到、读取拿的是对端回包，"
    echo "[run]        两端证据都在应用进程之外。"
    echo "[run]        注意：Windows 侧同名接口目前是**桩**（native/bridge_win.c 只校验不实现），"
    echo "[run]              本平台验的是 Linux/termios 这条实现。"
else
    echo "[run] FAIL —— 看 $LOG / $PEER_LOG / $RX_FILE"
fi
echo "[run] app log : $LOG"
echo "[run] peer log: $PEER_LOG"
echo "[run] rx bytes: $RX_FILE"
exit "$FAIL"
