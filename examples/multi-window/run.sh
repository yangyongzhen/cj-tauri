#!/usr/bin/env bash
# 多窗口 PoC 探针：构建 + 在 Xvfb 里跑一轮，把桥 stderr 的取证行打出来并按模式判定。
#
# 两种模式（环境变量 MW_MODE）：
#   full（缺省） 两个窗口：一条广播 + 两条定向各投各的。**当前预期失败**——现有「一宿主一 GTK
#                线程一 gtk_main」的装配在 Linux 上起不了第二个窗口（见 docs/架构演进-多平台与
#                多窗口.md §8）。所以本模式下脚本核对的是「与 §8 记录的失败签名是否一致」，
#                成功通过反而要报警（说明约束可能已消失，该把它改成验收用例）。
#   single       只起主窗（对照组）：验多窗口缝没弄坏原有单窗路径——这一档**应当干净通过**。
#
# 与 Windows 面（run.bat）的差别：run.bat 已于 2026-10-03 实机通过，且**多两个阶段**——阶段 2
# 两窗同时开原生消息框、阶段 3 只关一个窗口（§7.5 残余项的判据，断言 18 条）。那两个阶段在 Linux 上
# **不会被走到**：full 模式在「假设 A 起不了第二个窗口」这一步就判失败退出，所以本脚本不覆盖它们
# ——想在 Linux 上验，得等「单主循环 + 多窗口」重构落地后另加。
#
# 前置：桥已构建（bash native/build_linux.sh）。Linux 桌面 / Xvfb 均可；Windows 侧用 run.bat
#（本脚本是 Linux 侧探针，不适用于 Windows）。
# 用法：bash run.sh [日志路径]（默认 /tmp/multi-window-poc.log）
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
LOG="${1:-/tmp/multi-window-poc.log}"
MODE="${MW_MODE:-full}"

# 与 scripts/test.sh 同一套环境推导：cjc / cjpm 都要在 PATH；Linux 上运行时 .so 只认
# LD_LIBRARY_PATH（不查 PATH，见 AGENTS.md §4 的坑）
CANGJIE_HOME="${CANGJIE_HOME:-/opt/cangjie/cangjie}"
CANGJIE_STDX="${CANGJIE_STDX:-/root/.cangjie/stdx/cangjie-stdx-linux-x64-1.0.5.1/dynamic/stdx}"
export CANGJIE_HOME
export PATH="$CANGJIE_HOME/bin:$CANGJIE_HOME/tools/bin:$PATH"

cd "$HERE"   # 工作目录 = 工程根：capabilities/ 按相对路径读

# LD_LIBRARY_PATH 必须在**构建之前**就位：cjpm 自己也是仓颉程序，缺 libcangjie-runtime.so
# 会直接以「error while loading shared libraries」退出（AGENTS.md §4 的坑，Linux 不查 PATH）
export LD_LIBRARY_PATH="$ROOT/native:$CANGJIE_STDX:$CANGJIE_HOME/runtime/lib/linux_x86_64_cjnative:$CANGJIE_HOME/third_party/llvm/lib:${LD_LIBRARY_PATH:-}"
export WEBKIT_DISABLE_COMPOSITING_MODE=1
export LIBGL_ALWAYS_SOFTWARE=1

echo "[run] 模式=$MODE  构建 $HERE"
cjpm build > "$LOG.build" 2>&1 || { tail -40 "$LOG.build"; exit 1; }

echo "[run] 跑（最长 120s，超时=挂死）"
set +e
MW_MODE="$MODE" timeout 120 xvfb-run -a -s "-screen 0 1280x800x24" ./target/release/bin/main > "$LOG" 2>&1
RC=$?
set -e

echo "[run] exit=$RC  log=$LOG"
echo "---- 日志取证行 ----"
grep -aE '\[mwprobe\]|附加窗口已启动|command not|invalid next|Aborted|SIGABRT' "$LOG" || true

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
        echo "  FAIL  $1（出现了不该有的子串: $2）"
        FAIL=1
    else
        echo "  ok    $1"
    fi
}

echo "---- 断言（模式=$MODE）----"
if [ "$MODE" = "single" ]; then
    # 对照组：单窗路径必须与批次 2 之前完全一致
    if [ "$RC" -eq 0 ]; then echo "  ok    干净退出（exit=0）"; else echo "  FAIL  退出码 $RC（124=挂死，134=abort）"; FAIL=1; fi
    check  "主窗 boot 且 label 注入 ↔ 路由一致" 'window=main BOOT jsLabel=main booted=1'
    check  "驱动窗轮询到只有 1 个窗口"          'window=main GATE boots=1'
    check  "如实报「第二窗没起来」"              'FAIL second window never booted'
    check  "收尾走应用级 quit"                   'requested quit -> 收全部窗口'
    check  "run 之后有收尾日志"                  '[mwprobe] after run'
    absent "没有第二窗口"                        '附加窗口已启动'
else
    # full：核对「与 §8 记录的失败签名是否一致」
    check "第二窗口的宿主确实起来了（缝是好的）" '附加窗口已启动：label="second"'
    if [ "$RC" -eq 0 ]; then
        echo "  !!    exit=0：双窗似乎跑通了，与 §8 记录不符"
        if grep -aqF 'window=main COUNTS role=driver label=main broadcast=1 target_main=1 target_second=0' "$LOG" \
           && grep -aqF 'window=second COUNTS role=observer label=second broadcast=1 target_main=0 target_second=1' "$LOG"; then
            echo "  🎉    驱动窗与观察窗计数都对——约束可能已消失，请复核 §8 并把它当验收用例"
        else
            echo "  FAIL  但两窗计数不符合期望，需人工看日志"
            FAIL=1
        fi
    else
        echo "  ok    已知失败签名：exit=$RC（124=挂死 / 134=abort）"
        absent "两页都没能 boot（崩溃发生在页面执行之前）" 'BOOT jsLabel='
        check  "崩溃点是堆损坏或 GTK/Pango 断言"        'invalid next'
    fi
fi

if [ "$FAIL" -eq 0 ]; then
    if [ "$MODE" = "single" ]; then echo "[run] 单窗对照通过"; else echo "[run] 与 §8 记录一致"; fi
else
    echo "[run] 有失败项（先看 $LOG 与 docs/架构演进-多平台与多窗口.md §8）"
fi
exit "$FAIL"
