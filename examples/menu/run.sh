#!/usr/bin/env bash
# ============================================================
# cj-tauri 菜单能力位探针（examples/menu）—— Linux 侧跑法
#
# 与 Windows 侧 run.bat 的关系：**断言口径同源，形态按平台事实切**
#   - run.bat 跑 full 模式（两窗）：菜单链 + 「事件按宿主句柄路由」（点第二扇窗，第一扇窗
#     必须一声不响）；
#   - 本脚本跑 single 模式（单窗）：GTK/WebKitGTK 不能被两条线程各自使用，第二宿主一装配就
#     segv、菜单那一段根本走不到（实测见 /tmp 的基线日志与 docs/架构演进-多平台与多窗口.md §8）。
#     所以两窗路由这一维**留在 Windows**，本脚本验的是同一条链在 GTK 上的实现：
#     建菜单 → 真实鼠标点下去 → 回投 core → 应用钩子 → 走应用层 API 改状态 → **平台侧读回**。
#
# 驱动方式：xdotool 在菜单项上发真实 X 鼠标事件（对应 Windows 侧 click-menu.ps1 的
# PostMessage WM_COMMAND）。点击坐标是按截图量出来的像素中心（见下面的项中心常量），
# 所以每一下都走「点到日志出现为止」的有界重试：判据是**日志里的效果**，不是「我点过了」——
# 菜单轮踩过「设了但没生效，日志照说已应用」，所以这里两平台都以事后读回为准。
#
# 收尾：单窗模式由探针自己调 app.quit()（应用级退出路径，Windows 侧是驱动 PostMessage WM_CLOSE），
# 所以本脚本能一并断言 exit=0 与 host destroyed —— 顺带重跑一次 Linux 的退出路径。
#
# 前置：桥已构建（bash native/build_linux.sh）；需要 xdotool；没有 DISPLAY 时脚本自己套一层
# xvfb-run 重跑自己（本机 X11 转发常失效，永远走 Xvfb 最稳）。
# 用法：bash run.sh [日志路径]（默认 /tmp/menu-probe.log，驱动日志是同名 -driver.log）
# ============================================================
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
LOG="${1:-/tmp/menu-probe.log}"
DRVLOG="${LOG%.log}-driver.log"
APP="$HERE/target/release/bin/main"
BRIDGE="$ROOT/native/libcjtbridge.so"

# 与 scripts/test.sh / examples/multi-window/run.sh 同一套环境推导
CANGJIE_HOME="${CANGJIE_HOME:-/opt/cangjie/cangjie}"
CANGJIE_STDX="${CANGJIE_STDX:-/root/.cangjie/stdx/cangjie-stdx-linux-x64-1.0.5.1/dynamic/stdx}"
export CANGJIE_HOME
export PATH="$CANGJIE_HOME/bin:$CANGJIE_HOME/tools/bin:$PATH"
# Linux 上运行时 .so 只认 LD_LIBRARY_PATH（不查 PATH）。必须在**构建之前**就位：cjpm 自己也是
# 仓颉程序，缺 libcangjie-runtime.so 会直接以「error while loading shared libraries」退出。
export LD_LIBRARY_PATH="$ROOT/native:$CANGJIE_STDX:$CANGJIE_HOME/runtime/lib/linux_x86_64_cjnative:$CANGJIE_HOME/third_party/llvm/lib:${LD_LIBRARY_PATH:-}"
export WEBKIT_DISABLE_COMPOSITING_MODE=1
export LIBGL_ALWAYS_SOFTWARE=1
export MENU_MODE=single

if [ ! -f "$BRIDGE" ]; then
    echo "[run] 缺 $BRIDGE —— 先跑 bash native/build_linux.sh" >&2
    exit 1
fi
if ! command -v xdotool >/dev/null 2>&1; then
    echo "[run] 缺 xdotool（Debian/Ubuntu: sudo apt install xdotool）" >&2
    exit 1
fi

# 显示环境不可用就自己套 Xvfb 重跑自己。**不能只看 DISPLAY 有没有设**：本机（SSH 转发）
# 常留着一个失效的 DISPLAY=localhost:1x.0，信它会得到「cannot open display」+ 应用直接 segv；
# 所以拿 xdotool 真问一句显示能不能打开（xdotool 本就是本脚本的硬依赖）。
# MENU_IN_XVFB 是防自旋的标记：进了 Xvfb 还打不开就不再重试。
if [ "${MENU_IN_XVFB:-}" != "1" ] && ! xdotool getdisplaygeometry >/dev/null 2>&1; then
    echo "[run] DISPLAY='${DISPLAY:-}' 打不开 -> 在 Xvfb 里重跑（1280x800x24）"
    export MENU_IN_XVFB=1
    exec xvfb-run -a -s "-screen 0 1280x800x24" "$0" "$LOG"
fi

cd "$HERE"   # 工作目录 = 工程根：capabilities/ 与 ui/ 都按相对路径读
: > "$DRVLOG"
drv() { echo "[click] $*" | tee -a "$DRVLOG"; }

echo "[run] 构建 $HERE"
cjpm build > "$LOG.build" 2>&1 || { tail -40 "$LOG.build"; exit 1; }

echo "[run] 起探针（single 模式）"
: > "$LOG"
./target/release/bin/main > "$LOG" 2>&1 &
APP_PID=$!
cleanup() { kill "$APP_PID" 2>/dev/null || true; }
trap cleanup EXIT

# 等窗口别用固定 sleep（cjpm 首次构建可能较久）：有界轮询
# 注意 xdotool 的 --name 是**正则**：标题里的括号不转义就变成分组，"probe (main)" 会去匹配
# "probe main" 而永远搜不到（实测第一轮就是这么空等的）。
WIN=""
for _ in $(seq 1 60); do
    WIN="$(xdotool search --name 'cj-tauri menu probe \(main\)' 2>/dev/null | head -1 || true)"
    [ -n "$WIN" ] && break
    sleep 1
done
if [ -z "$WIN" ]; then
    echo "[run] FAIL 窗口没起来 —— 看 $LOG" >&2
    tail -30 "$LOG"
    exit 1
fi
eval "$(xdotool getwindowgeometry --shell "$WIN")"
drv "window=$WIN geometry=${WIDTH}x${HEIGHT} at $X,$Y"
xdotool windowraise "$WIN"
sleep 2

# ---- 点击驱动 ----------------------------------------------------------------
# 两步走：① 项的位置不用算——**用窗口相对坐标**，xdotool 自己问 X 要窗口位置；
#          ② 按下与抬起放进**同一个 xdotool 进程**，把「定位 → 按下」的间隔压到最小。
# 为什么不自己算绝对坐标：窗口位置在 no-WM 的 Xvfb 上每轮都不一样（实测三轮分别 0,0 / 60,83 /
# 190,213），而且 `xdotool getwindowgeometry` 报的原点与实际落点能差出整整一个菜单项——
# 第一版实机「点 New 出来的是 Sidebar」就是这么来的。用 --window 就不碰这套算术。
# 为什么每项都留重试：GTK 菜单栏上，**同一位置的第一次按下只把项选中，第二次才激活**
# （实测一次干净运行里三项全都恰好第 2 次命中）；所以判据只看「这条 id 回投出现没有」，不看点击次数。
# 顺带一条：本环境里 `xdotool getmouselocation` 的 window 字段恒为 0（指针明明在窗口上），
# 别拿它做「指针是否落在窗口上」的自检。
count() { grep -acF "$1" "$LOG" 2>/dev/null || true; }

# 取某 id 最新一次几何：回 "x w h"（桥打的客户区坐标 —— GTK 自己报的，不是谁估的像素）
layout_of() {
    grep -ao "$1=[0-9]*+[0-9]*+[0-9]*" "$LOG" 2>/dev/null | tail -1 | sed "s/^$1=//; s/+/ /g"
}

click_until() {
    local id="$1" name="$2" needle="$3" before after a i geom ix iw ih cx cy
    before="$(count "$needle")"
    for a in 1 2 3 4 5 6; do
        geom="$(layout_of "$id")"
        if [ -z "$geom" ]; then drv "MISS $name -- 日志里没有 $id 的几何读回"; return 1; fi
        read -r ix iw ih <<< "$geom"
        cx=$((ix + iw / 2))
        cy=$((ih / 2))
        xdotool mousemove --window "$WIN" $((WIDTH - 20)) $((HEIGHT - 20))  # 指针先离开菜单栏
        sleep 0.2
        xdotool mousemove --window "$WIN" "$cx" "$cy" sleep 0.2 mousedown 1 sleep 0.2 mouseup 1
        for i in $(seq 1 12); do
            sleep 0.25
            after="$(count "$needle")"
            if [ "$after" -gt "$before" ]; then
                drv "HIT $name attempt=$a item=${ix}+${iw}+${ih} click=${cx},${cy}(win-rel)"
                return 0
            fi
        done
        if ! kill -0 "$APP_PID" 2>/dev/null; then
            drv "MISS $name -- 应用已退出，不再重试"
            return 1
        fi
    done
    drv "MISS $name -- 点了 6 次都没见到「$needle」"
    return 1
}

echo "[run] 点菜单（三次：普通项 / 勾选项 / 触发改状态的项）"
CLICKS=0
# 探针的一次点击只回投一条事件，所以 needle 只认 id：勾选项的 checked 由断言另算，
# 不把「这一下必须翻成 1」钉进点击判据（顺序敏感会让脚本假红）。
click_until file.new     "New"             'menu clicked: id=file.new'     && CLICKS=$((CLICKS + 1))
click_until view.sidebar "Sidebar"         'menu clicked: id=view.sidebar' && CLICKS=$((CLICKS + 1))
click_until edit.toggle  "Disable sidebar" 'menu clicked: id=edit.toggle'  && CLICKS=$((CLICKS + 1))

# 第三次点击会让探针改状态并请求退出；等它自己走完收尾（有界：挂死的话这里判失败）
RC=99
for _ in $(seq 1 80); do
    if ! kill -0 "$APP_PID" 2>/dev/null; then break; fi
    sleep 0.5
done
set +e
wait "$APP_PID"
RC=$?
set -e
trap - EXIT
drv "DONE clicks=$CLICKS exit=$RC"

echo "[run] exit=$RC  log=$LOG"
echo "---- 日志取证行 ----"
grep -aE '\[menuprobe\]|\[cj-bridge\]|\[cj-tauri\]' "$LOG" || true
echo "---- 驱动日志 ----"
cat "$DRVLOG"

FAIL=0
check() {
    if grep -aqF "$2" "$LOG"; then
        echo "  ok    $1"
    else
        echo "  FAIL  $1（缺子串: $2）"
        FAIL=1
    fi
}
count_eq() {
    local n
    n="$(grep -acF "$2" "$LOG" || true)"
    if [ "$n" -eq "$3" ]; then
        echo "  ok    $1（$3 行）"
    else
        echo "  FAIL  $1（期望 $3 行 \"$2\"，实到 $n 行）"
        FAIL=1
    fi
}
check_ge() {
    local n
    n="$(grep -acF "$2" "$LOG" || true)"
    if [ "$n" -ge "$3" ]; then
        echo "  ok    $1（$n 行）"
    else
        echo "  FAIL  $1（期望 ≥$3 行 \"$2\"，实到 $n 行）"
        FAIL=1
    fi
}
count_eq_pair() {   # 两条子串行数必须相等：这里是「每次点击恰好回投一次、且都落在本窗」
    local a b
    a="$(grep -acF "$2" "$LOG" || true)"
    b="$(grep -acF "$3" "$LOG" || true)"
    if [ "$a" -eq "$b" ] && [ "$a" -ge 1 ]; then
        echo "  ok    $1（两条都是 $a 行）"
    else
        echo "  FAIL  $1（\"$2\"=$a 行 vs \"$3\"=$b 行，应相等且 ≥1）"
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

echo "---- 断言（single 模式）----"
if [ "$RC" -eq 0 ]; then echo "  ok    干净退出（exit=0）"; else echo "  FAIL  退出码 $RC（124=挂死 / 134=abort）"; FAIL=1; fi
check "探针起来了且是单窗"        '[menuprobe] main start mode=single windows=1'
count_eq "菜单模型送出去了"        'menu set bytes=' 1
check "能力位报告了菜单"          'menu-capable=true'
check "菜单在宿主 UI 线程建好"    '[cj-bridge] menu applied: items='
# 事后读回（不是「我调过了」）：菜单栏已挂进 box、5 个顶层项、可见
check "菜单栏真挂进 box 且可见"   'bar_children=5 visible=1'
check_ge "普通项被点到"            'menu clicked: id=file.new' 1
check_ge "勾选项被点到"            'menu clicked: id=view.sidebar' 1
check_ge "勾选项被平台翻成选中"     'menu clicked: id=view.sidebar enabled=1 checked=1' 1
check_ge "触发改状态的项被点到"     'menu clicked: id=edit.toggle' 1
count_eq_pair "每次点击恰好回投一次且都落在本窗" 'menu clicked: id=' 'window=main shell'
check "应用钩子对 edit.toggle 回手" 'state requested id=view.sidebar enabled=false checked=true'
check "模型改动到平台"            'set menu item: id=view.sidebar enabled=0 checked=1'
check "平台读回真状态"            'menu item readback: id=view.sidebar sensitive=0 active=1'
check "单窗模式收尾走应用级 quit"  '[menuprobe] single mode: quit requested'
check "run 之后有收尾日志"        '[menuprobe] after run'
check "宿主已销毁"                '[cj-bridge] host destroyed'
absent "没有崩溃"                 'Aborted'
absent "没有段错误"               'Handle signal'
absent "没有命令误报"             'command not allowed'
absent "没有事件被拒"             'event not allowed'

if [ "$FAIL" -eq 0 ]; then
    echo "[run] PASS —— Linux 上菜单这条链是活的：菜单栏真挂进 box、真实鼠标点击走了整条链、"
    echo "[run]        事件落在本窗、状态改动由平台侧读回、退出走应用级 quit 且 exit=0。"
    echo "[run]        注意：两窗路由（同一宿主回调入口下按句柄认领）的证据在 Windows 侧 run.bat，"
    echo "[run]              本平台起不了第二个宿主（docs/架构演进-多平台与多窗口.md §8）。"
else
    echo "[run] FAIL —— 看 $LOG 与 $DRVLOG"
fi
echo "[run] app log: $LOG"
echo "[run] drv log: $DRVLOG"
exit "$FAIL"
