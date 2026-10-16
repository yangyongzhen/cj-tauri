#!/usr/bin/env bash
# e2e/test-linux-logfile.sh — Linux 实机 E2E：日志落盘能力位（RFC-003 第 5 期）
#
# 两轮，各出一份证据（同一入口，run-all.sh 只算一条）：
#   轮一 logfile        —— 预算 4 MB（本轮不轮转），验「落盘 / 并流 / 增长」
#     · 应用**不显式调 setLogFile**，只给 CJ_TAURI_LOG；且路径的多级父目录先不存在，
#       得由框架自己按需建出来（默认目录 ~/.local/state/cj-tauri 也常常还不存在）
#     · C 桥自己的行、**仓颉侧经 log:write 写进来的页面诊断**落在同一份文件里
#     · 同一次运行里行数两次采样递增（防「建了个空文件就算落盘」）
#   轮二 logfile-rotate —— 预算 1 KB、keep 2，验轮转语义
#     · 压力来自页面连写 25 行 ~100 字节填充；档案 .1 / .2 该出现、.3 不该出现（keep 上限）
#     · 轮转之后当前文件继续写（轮转标记行之后还有行）
#
# 取证口径（为什么这么取）：
#   · 落盘接管 fd 2 之后，进程的 stderr 已经指向日志文件，壳那层 `>>$E2E_LOG` 的重定向收不到
#     后续行——所以断言与证据层读的就是**应用那一份**（应用起来后把 E2E_LOG 指过去）；
#     启动段另存 startup 日志，用来做一条反向对账：前端诊断**不该**出现在继承来的 stderr 里。
#   · 轮二只留得住最近约 3 KB（keep 2 × 1 KB + 当前），接管行与标记行早被平移出去了——
#     于是把 `.2 → .1 → 当前` 按时间顺序拼成 series 文件当证据（原始三份留同目录可逐份对账），
#     断言的 needle 只挑「一定在保留窗口里」的：轮转标记行、填充行、轮转期间的桥调用行。
#   · 不依赖探针页最后那条聚合行（probe:echo）：那要等九条探针**全部**落定，其中一条在无通知
#     守护的 Xvfb 下会挂住——那是探针工程自己的事，不该拖住日志这条链路的取证。所以页面把
#     回读到的日志路径随标记行一起写进日志，log:path 的返回值因此也是落盘凭证。
#
# 用法：bash scripts/e2e/test-linux-logfile.sh
#   - 无 DISPLAY 时自动在 Xvfb 下重跑（lib.sh 的 e2e_ensure_display）
#   - 非 Linux 默认跳过；CI 设 CJ_TAURI_E2E_REQUIRE=linux 让「错机」变失败
#
# 证据：dist/e2e-evidence/linux-logfile.json、linux-logfile-rotate.json
set -u

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

e2e_require_platform linux
e2e_ensure_display

FIXTURE="$E2E_LIB_DIR/fixture-app"
APP="$FIXTURE/target/release/bin/main"
BUILD_LOG="$E2E_ROOT/dist/e2e-evidence/linux-logfile.build.log"

rc=0

if ! e2e_ensure_sdk; then
  e2e_fail "找不到仓颉 SDK（设 CANGJIE_HOME）：应用需要运行时库才能启动"
  exit 1
fi

if [ ! -x "$APP" ]; then
  e2e_info "探针工程未构建，先 cjpm build（日志 $BUILD_LOG）"
  if ! ( cd "$FIXTURE" && cjpm build ) >"$BUILD_LOG" 2>&1; then
    e2e_fail "探针工程构建失败，见 $BUILD_LOG"
    tail -20 "$BUILD_LOG" >&2
    exit 1
  fi
  e2e_info "探针工程构建完成"
fi

e2e_set_cwd "$FIXTURE"

# ==================================================================== 轮一：落盘 / 并流 / 增长
e2e_begin "logfile"
E2E_NOTE="CJ_TAURI_LOG 兜底开日志（预算 4 MB，本轮不轮转）；多级父目录按需建出来；页面 log:write/log:path 与 C 桥行并进同一份文件；行数两采样递增"

RUN1="$E2E_ROOT/dist/e2e-evidence/logfile-run-$$-a"
APPLOG1="$RUN1/nested/deep/app.log"   # nested/deep 两级此刻都不存在
STARTUP1="$E2E_LOG"                    # 落盘前的启动段（继承来的 stderr）
export CJ_TAURI_LOG="$APPLOG1"
export CJ_TAURI_LOG_MAX_KB=4096
export CJ_TAURI_LOG_KEEP=2

e2e_info "轮一应用日志 = $APPLOG1（父目录先不存在，交给框架按需建）"
e2e_run_app "$APP"
E2E_LOG="$APPLOG1"   # 从这一刻起，等待与取证都读应用那一份

if ! e2e_wait_log "[cj-bridge] log file: " 60; then
  e2e_fail "等不到「log file」接管行——CJ_TAURI_LOG 兜底没生效？"
  rc=1
fi
lines1=0; [ -f "$APPLOG1" ] && lines1="$(wc -l < "$APPLOG1")"

# 页面那条日志链跑到底的凭证：填充是 25 → 1 **倒着写**的，`filler 1 ` 就是最后一笔
if ! e2e_wait_log "[frontend] e2e filler 1 " 60; then
  e2e_fail "等不到页面填充写到底（filler 1）——log:write 链路没走通？"
  rc=1
fi
lines2=0; [ -f "$APPLOG1" ] && lines2="$(wc -l < "$APPLOG1")"
e2e_stop_app

if [ -s "$APPLOG1" ]; then
  e2e_info "轮一日志已生成：$APPLOG1（$lines2 行）"
else
  e2e_fail "轮一日志不存在或为空：$APPLOG1"
  rc=1
fi
if [ "$lines1" -gt 0 ] && [ "$lines2" -gt "$lines1" ]; then
  e2e_info "行数增长：$lines1 → $lines2"
else
  e2e_fail "行数没有增长（$lines1 → $lines2）——建了个空文件不等于落盘"
  rc=1
fi
# 预算给到 4 MB：本轮不该出现档案（出现即说明门槛被改坏）
if [ -e "$APPLOG1.1" ]; then
  e2e_fail "4 MB 预算下不该有档案 .1（轮转门槛被改坏？）"
  rc=1
else
  e2e_info "4 MB 预算下未轮转（无 .1 档案），符合预期"
fi
# 反向对账：前端诊断走的是日志文件，**不是**继承来的 stderr
if [ -f "$STARTUP1" ] && grep -aqF "e2e probe marker=gamma" "$STARTUP1"; then
  e2e_fail "前端诊断出现在启动段（继承的 stderr）里——落盘接管没生效？"
  rc=1
else
  e2e_info "启动段没有前端诊断行（说明它确实走的日志文件）"
fi

e2e_assert "日志接管行落在文件里"          "[cj-bridge] log file: "
e2e_assert "预算与保留份数按环境变量生效"    "deep/app.log (max=4096KB keep=2)"
e2e_assert "C 桥调用行也在同一份文件"        "[cj-bridge] js -> native ("
e2e_assert "页面回读路径并写回同一份文件"    "[frontend] e2e probe marker=gamma path="
e2e_assert "页面填充写到底"                  "[frontend] e2e filler 1 "

e2e_finalize || rc=1

# ==================================================================== 轮二：轮转
e2e_begin "logfile-rotate"
E2E_NOTE="预算 1 KB keep 2：页面连写 25 行填充压出 .1/.2 档案、.3 不该出现（keep 上限）；轮转之后当前文件继续写；证据为 .2→.1→当前 拼接的保留窗口（原始三份留同目录）"

RUN2="$E2E_ROOT/dist/e2e-evidence/logfile-run-$$-b"
APPLOG2="$RUN2/log/app.log"
export CJ_TAURI_LOG="$APPLOG2"
export CJ_TAURI_LOG_MAX_KB=1
export CJ_TAURI_LOG_KEEP=2

e2e_info "轮二应用日志 = $APPLOG2（预算 1 KB，keep 2）"
e2e_run_app "$APP"
E2E_LOG="$APPLOG2"

# 轮转标记行由轮转自己写在**截断后的新文件开头**：当前文件一旦轮转过就一定带着它
if ! e2e_wait_log "log rotated: keep=2 archive=" 90; then
  e2e_fail "等不到轮转标记行（1 KB 预算下没轮转？）"
  rc=1
fi
# 两份档案都该出现（.2 要等第二次轮转），有界等待
i=0
while [ "$i" -lt 120 ] && { [ ! -s "$APPLOG2.1" ] || [ ! -s "$APPLOG2.2" ]; }; do
  sleep 0.25
  i=$((i + 1))
done

# 等页面那条日志链跑完：轮转下填充行可能已经被搬进 .1/.2（接管行早平移出去了），
# 所以当前文件与两份档案一起看——这也正是「档案带走的是正文」的直接凭证。
# 少了这一步会在页面还没开始写填充时就收尾应用，于是三个文件里一条填充都没有（实测踩过）。
i=0
burst_ok=0
while [ "$i" -lt 240 ]; do
  if grep -aqF "[frontend] e2e filler " "$APPLOG2" "$APPLOG2.1" "$APPLOG2.2" 2>/dev/null; then
    burst_ok=1
    break
  fi
  sleep 0.25
  i=$((i + 1))
done
if [ "$burst_ok" = "1" ]; then
  e2e_info "页面填充已落盘（当前文件或档案里）"
else
  e2e_fail "等不到页面填充落盘——log:write 链路在 1 KB 预算下没走通？"
  rc=1
fi

# 轮转之后继续写：当前文件里，最后一条轮转标记行之后还有行
last_rot=0; total=0
if [ -f "$APPLOG2" ]; then
  total="$(wc -l < "$APPLOG2")"
  last_rot="$(grep -anF "log rotated: keep=2" "$APPLOG2" | tail -1 | cut -d: -f1)"
  [ -n "$last_rot" ] || last_rot=0
fi
i=0
while [ "$i" -lt 40 ] && [ "$total" -le "$last_rot" ]; do
  sleep 0.25
  total="$(wc -l < "$APPLOG2")"
  i=$((i + 1))
done
e2e_stop_app

for n in 1 2; do
  if [ -s "$APPLOG2.$n" ]; then
    e2e_info "档案 .$n 已生成（$(wc -c < "$APPLOG2.$n") 字节）"
  else
    e2e_fail "缺档案 .$n（1 KB 预算下 25 行填充没压出两轮轮转？）"
    rc=1
  fi
done
if [ -e "$APPLOG2.3" ]; then
  e2e_fail "多出 .3——keep=2 的上限没生效（档案会无限堆积）"
  rc=1
else
  e2e_info "keep=2 上限生效（没有 .3）"
fi
if [ "$last_rot" -gt 0 ] && [ "$total" -gt "$last_rot" ]; then
  e2e_info "轮转后当前文件继续写：轮转标记在第 $last_rot 行，共 $total 行"
else
  e2e_fail "轮转标记行之后没有新行（末次轮转在第 $last_rot 行，共 $total 行）——截断后停了？"
  rc=1
fi
# 内容是被**搬进档案**、不是被丢掉
moved=0
for f in "$APPLOG2.1" "$APPLOG2.2" "$APPLOG2"; do
  if [ -f "$f" ] && grep -aqF "[frontend] e2e filler " "$f"; then
    moved=1
  fi
done
if [ "$moved" = "1" ]; then
  e2e_info "保留窗口里仍有页面填充行（内容随档案平移，不是丢）"
else
  e2e_fail "保留窗口里一条页面填充行都没有——轮转把内容弄丢了？"
  rc=1
fi

# 证据：保留窗口按时间顺序拼一份（原始三份留同目录，可逐份对账）
MERGED="$APPLOG2.series"
: > "$MERGED"
for f in "$APPLOG2.2" "$APPLOG2.1" "$APPLOG2"; do
  [ -f "$f" ] && cat "$f" >> "$MERGED"
done
E2E_LOG="$MERGED"
e2e_info "轮二证据 = 保留窗口拼接（.2 → .1 → 当前）：$MERGED"

e2e_assert "轮转如实留痕"              "log rotated: keep=2 archive="
e2e_assert "轮转后填充行仍在保留窗口"    "[frontend] e2e filler "
e2e_assert "轮转期间 C 桥照写"          "[cj-bridge] js -> native ("

e2e_finalize || rc=1

exit $rc
