#!/usr/bin/env bash
# e2e/test-linux-sqlite-browser.sh — Linux 实机 E2E：SQLite 浏览器示例（examples/sqlite-browser）
#
# 验的是完整一跳：**页面 → 桥 → IPC → 能力校验（命名权限集 + 路径 scope）→ 插件的 sqlite:* 命令
# → 仓颉 FFI 直连系统 libsqlite3（本仓首例）→ 结果回投 → 页面渲染与断言**。
#
# 三侧对账（本示例的取信方式）：
#   页面侧 —— 36 条断言各自经 `report` 回投成 `[frontend] [sqlite-selfcheck] PASS <名字>`；
#   桥侧   —— 护栏与拒绝在 stderr 留凭证：`sqlite denied: attach/detach is not allowed`（authorizer 按语句拒）、
#             `[cj-tauri] scope denied (sqlite): …`（路径越界）、`command rejected (sqlite:query): … readonly …`
#             （只读是**内核级**的，这句原文来自 sqlite 而不是我们写的检查）；
#   进程外 —— fixture.py 用 python3 的 sqlite3 只读打开**同一个库文件**，确认页面经 exec 写的那一行
#             真的落盘（`[sqlite-fixture] VERIFY ok inserted.row …`）。这条对不上，就说明「页面说写成功了」
#             只是页面自己说的。
#
# 用法：bash scripts/e2e/test-linux-sqlite-browser.sh
#   - 无 DISPLAY 时自动在 Xvfb 下重跑（lib.sh 的 e2e_ensure_display）
#   - 在非 Linux 上默认跳过；CI 里设 CJ_TAURI_E2E_REQUIRE=linux 可让「错机」变成失败
#
# 证据：dist/e2e-evidence/linux-linux-sqlite-browser.json（双前缀是本仓约定：e2e_begin 自己再加一次平台名）
#   ~.log          应用 + 对端合并日志（前缀可分流）
#   ~-fixture.log  夹具库生成 + 自检（12 项）
#   ~.verify.log   进程外核对（页面写的那一行在不在）
#   ~.build.log    示例构建日志
set -u

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

e2e_require_platform linux
e2e_ensure_display
e2e_begin "linux-sqlite-browser"

EXAMPLE="$E2E_ROOT/examples/sqlite-browser"
APP="$EXAMPLE/target/release/bin/main"
FIXTURE="$EXAMPLE/fixture.py"
DB="$EXAMPLE/data/fixture.db"
EVID="$E2E_ROOT/dist/e2e-evidence"
BUILD_LOG="$EVID/linux-sqlite-browser.build.log"
FIXTURE_LOG="$EVID/linux-sqlite-browser-fixture.log"
VERIFY_LOG="$EVID/linux-sqlite-browser.verify.log"
EXPECT_PASS=36
EXPECT_SELFTEST=12
E2E_NOTE="对端是 python3 标准库的 sqlite3（与仓颉侧链的同一个系统库同版本）；夹具库 3 表 1 视图（含 NULL / 4 字节 BLOB / 80000 字节大文本）；页内自检 36 条（info/tables/schema/page/query/exec/env 七条命令 + 页长夹紧 + 排序 + 类型映射 + 单元格截断 + 只读写被内核拒 + ATTACH 被 authorizer 拒 + 路径 scope 拒绝）；收尾时对端日志并入同一份证据日志（前缀 [sqlite-fixture]），并用**进程外**只读打开同一文件核对页面写进去的那一行"

# ------------------------------------------------------------------ 1) 环境与构建
# SDK 环境无条件准备：应用要加载 libcjtbridge.so 与仓颉运行时（含 stdx 动态库），
# 少一个的表象是「产物在、一跑就退」，很容易被误读成构建问题。
if ! e2e_ensure_sdk; then
  e2e_fail "找不到仓颉 SDK（设 CANGJIE_HOME）：应用需要运行时库才能启动"
  exit 1
fi

# 对端与夹具都用 python3：它同时是「独立进程的第二个 sqlite 实现视角」，缺了就没法做进程外核对
if ! command -v python3 >/dev/null 2>&1; then
  e2e_skip "缺 python3，无法生成夹具库并做进程外核对"
  exit 0
fi

if [ ! -x "$APP" ]; then
  e2e_info "示例未构建，先 cjpm build（日志 $BUILD_LOG）"
  if ! ( cd "$EXAMPLE" && cjpm build ) >"$BUILD_LOG" 2>&1; then
    e2e_fail "示例构建失败，见 $BUILD_LOG"
    tail -20 "$BUILD_LOG" >&2
    exit 1
  fi
  e2e_info "示例构建完成"
fi

# ------------------------------------------------------------------ 2) 夹具库：先自证生成器，再造这一轮要用的库
# 生成器先自己跑一遍自检（12 项）：夹具形状错了就在这一步失败，别让「夹具少了列」冒充成插件的问题。
if ! python3 "$FIXTURE" --selftest >"$FIXTURE_LOG" 2>&1; then
  e2e_fail "夹具生成器自检没过，见 $FIXTURE_LOG"
  tail -20 "$FIXTURE_LOG" >&2
  exit 1
fi
e2e_info "夹具生成器自检通过（$(grep -c -F 'SELFTEST PASS' "$FIXTURE_LOG" || true) 项）"

# 每轮**重建**夹具库（生成器会先删旧的）：上一轮页面 exec 写进去的那一行必须被清掉，
# 否则「写进去几行」这类断言就不再确定性（同 http-client 里清工作区的理由）。
python3 "$FIXTURE" --out "$DB" >>"$FIXTURE_LOG" 2>&1
if [ ! -f "$DB" ]; then
  e2e_fail "夹具库没生成出来：$DB（见 $FIXTURE_LOG）"
  exit 1
fi
e2e_info "夹具库已生成 $DB（$(stat -c '%s' "$DB" 2>/dev/null || echo '?') 字节）"

# ------------------------------------------------------------------ 3) 实机跑一轮
# 两样都由宿主经环境变量给页面（页面读不到进程环境）：
#   CJ_SQLITE_FIXTURE    要打开的库（绝对路径，落在 $CWD/data 下，过 scope 白名单）
#   CJ_SQLITE_SELFCHECK  自检开关（页面跑完 36 条后打一行 summary）
export CJ_SQLITE_FIXTURE="$DB"
export CJ_SQLITE_SELFCHECK=1

e2e_set_cwd "$EXAMPLE"
e2e_run_app "$APP"

rc=0
# 等的是**页面跑完整个自检之后打的那行**：只等「窗口出现」证明不了这一跳
# （窗口照起、库打不开的情况会被判通过）。
if ! e2e_wait_log "[sqlite-selfcheck] summary" 180; then
  rc=1
fi
e2e_stop_app

# ------------------------------------------------------------------ 4) 进程外核对（最硬的一条证据）
# 应用已经退出，文件是静止的：换一个进程、换一个 sqlite 实现视角，只读打开同一个库文件。
python3 "$FIXTURE" --verify "$DB" >"$VERIFY_LOG" 2>&1
VERIFY_RC=$?
if [ "$VERIFY_RC" != "0" ]; then
  e2e_fail "进程外核对失败（退出码 $VERIFY_RC），见 $VERIFY_LOG"
  tail -20 "$VERIFY_LOG" >&2
  rc=1
fi

# ------------------------------------------------------------------ 5) 对端日志并入同一份证据日志
{
  printf '\n[merge] 下面是夹具库生成 / 自检（对端）日志，前缀 [sqlite-fixture]\n'
  cat "$FIXTURE_LOG" 2>/dev/null || true
  printf '\n[merge] 下面是进程外核对日志（同一个库文件，另一个进程）\n'
  cat "$VERIFY_LOG" 2>/dev/null || true
  printf '[merge] 对端日志结束\n'
} >> "$E2E_LOG"

# ------------------------------------------------------------------ 6) 取证
# needle 用整行前缀或不撞词的长子串（AGENTS §4：中缀过滤器会骗人；断言名里不许带冒号）。
# --- 应用侧：启动与装配
e2e_assert "示例应用启动"                  "[sqlite-browser] main start (selfcheck=1, fixture="
e2e_assert "能力清单已加载"                "[cj-tauri] 已自动加载 capabilities/：1 个清单"
e2e_assert "窗口已创建"                    "[cj-bridge] set window: title=cj-tauri SQLite 浏览器"
e2e_assert "页面已拿到启动参数"            "[frontend] [sqlite-selfcheck] begin fixture="
e2e_assert "页面已打开夹具库"              "[frontend] [sqlite-selfcheck] PASS env.fixture"
# --- 页面侧：36 条自检逐条（每条都是页面自己算的结论）
e2e_assert "自检 自检开关已生效"           "[frontend] [sqlite-selfcheck] PASS env.selfcheck"
e2e_assert "自检 链接的是 sqlite3 主版本"   "[frontend] [sqlite-selfcheck] PASS info.version.major"
e2e_assert "自检 表数不把视图算进去"       "[frontend] [sqlite-selfcheck] PASS info.tableCount"
e2e_assert "自检 page_size 已回投"         "[frontend] [sqlite-selfcheck] PASS info.pageSize.positive"
e2e_assert "自检 ATTACH 已被封"            "[frontend] [sqlite-selfcheck] PASS info.attachBlocked"
e2e_assert "自检 对象清单 3 表 1 视图"     "[frontend] [sqlite-selfcheck] PASS objects.count"
e2e_assert "自检 artists 行数"             "[frontend] [sqlite-selfcheck] PASS objects.artists.rows"
e2e_assert "自检 albums 行数"              "[frontend] [sqlite-selfcheck] PASS objects.albums.rows"
e2e_assert "自检 notes 行数"               "[frontend] [sqlite-selfcheck] PASS objects.notes.rows"
e2e_assert "自检 视图 kind 如实"           "[frontend] [sqlite-selfcheck] PASS objects.view.kind"
e2e_assert "自检 视图行数报 -1 不冒充 0"   "[frontend] [sqlite-selfcheck] PASS objects.view.rows"
e2e_assert "自检 列定义条数"               "[frontend] [sqlite-selfcheck] PASS schema.artists.columns"
e2e_assert "自检 主键识别"                 "[frontend] [sqlite-selfcheck] PASS schema.artists.pk"
e2e_assert "自检 建表原文已回投"           "[frontend] [sqlite-selfcheck] PASS schema.artists.sql"
e2e_assert "自检 分页总数"                 "[frontend] [sqlite-selfcheck] PASS page.artists.total"
e2e_assert "自检 单元格类型 text"          "[frontend] [sqlite-selfcheck] PASS page.artists.cell.type"
e2e_assert "自检 中文单元格逐字一致"       "[frontend] [sqlite-selfcheck] PASS page.artists.cell.value"
e2e_assert "自检 页长夹紧到上限"           "[frontend] [sqlite-selfcheck] PASS page.clamp.limit"
e2e_assert "自检 夹紧标记如实上报"         "[frontend] [sqlite-selfcheck] PASS page.clamp.flag"
e2e_assert "自检 排序生效 升序首位"        "[frontend] [sqlite-selfcheck] PASS page.sort.asc.first"
e2e_assert "自检 排序生效 升序末位"        "[frontend] [sqlite-selfcheck] PASS page.sort.asc.last"
e2e_assert "自检 NULL 有独立类型"          "[frontend] [sqlite-selfcheck] PASS page.albums.rating.null"
e2e_assert "自检 BLOB 有独立类型"          "[frontend] [sqlite-selfcheck] PASS page.albums.cover.type"
e2e_assert "自检 BLOB 如实报字节数"        "[frontend] [sqlite-selfcheck] PASS page.albums.cover.bytes"
e2e_assert "自检 大文本被截断"             "[frontend] [sqlite-selfcheck] PASS page.notes.body.truncated"
e2e_assert "自检 截断到就是 65536"         "[frontend] [sqlite-selfcheck] PASS page.notes.body.length"
e2e_assert "自检 只读查询结果集"           "[frontend] [sqlite-selfcheck] PASS query.count.rows"
e2e_assert "自检 只读查询值"               "[frontend] [sqlite-selfcheck] PASS query.count.value"
e2e_assert "自检 只读写被内核拒"           "[frontend] [sqlite-selfcheck] PASS query.write.rejected"
e2e_assert "自检 ATTACH 被 authorizer 拒"  "[frontend] [sqlite-selfcheck] PASS exec.attach.rejected"
e2e_assert "自检 exec 写生效"              "[frontend] [sqlite-selfcheck] PASS exec.insert.changes"
e2e_assert "自检 写后查得到"               "[frontend] [sqlite-selfcheck] PASS exec.insert.count.after"
e2e_assert "自检 路径越界被 scope 拒"      "[frontend] [sqlite-selfcheck] PASS scope.denied"
e2e_assert "自检 不存在的表被拒"           "[frontend] [sqlite-selfcheck] PASS page.unknownTable"
e2e_assert "自检 不存在的库被拒"           "[frontend] [sqlite-selfcheck] PASS info.missingFile"
# --- 桥侧：护栏与拒绝都留了原因
e2e_assert "桥侧 authorizer 留凭证"        "sqlite denied: attach/detach is not allowed"
e2e_assert "桥侧 越界路径留凭证"           "[cj-tauri] scope denied (sqlite): /etc/hostname"
e2e_assert "桥侧 只读写拒绝带 sqlite 原文" "attempt to write a readonly database"
e2e_assert "桥侧 命令拒绝前缀可分流"       "command rejected (sqlite:query)"
# --- 对端侧
e2e_assert "夹具生成器自检通过"            "[sqlite-fixture] SELFTEST PASS file.created"
e2e_assert "夹具库已生成"                  "[sqlite-fixture] built path="
e2e_assert "进程外核到 4 行"               "[sqlite-fixture] VERIFY ok artists.count=4"
e2e_assert "进程外核到写进去的那行"        "[sqlite-fixture] VERIFY ok inserted.row id=4 name=自检写入 country=ZZ"
e2e_assert "进程外核对整体通过"            "[sqlite-fixture] VERIFY summary pass"

# --- 外部证据①：页内自检计数逐字对账（只有「跑完了」不算，得看 36/0 且 0 条 FAIL 行）
SUM_LINE="$(grep -F '[sqlite-selfcheck] summary' "$E2E_LOG" | tail -1 || true)"
PASS_N="$(printf '%s' "$SUM_LINE" | sed -n 's/.*pass=\([0-9]*\).*/\1/p')"
FAIL_N="$(printf '%s' "$SUM_LINE" | sed -n 's/.*fail=\([0-9]*\).*/\1/p')"
FAIL_LINES="$(grep -c -F '[sqlite-selfcheck] FAIL' "$E2E_LOG" || true)"
if [ "${PASS_N:-0}" = "$EXPECT_PASS" ] && [ "${FAIL_N:-1}" = "0" ] && [ "${FAIL_LINES:-1}" = "0" ]; then
  e2e_info "页内自检 ${PASS_N}/0，且日志里 0 条 FAIL 行"
else
  e2e_fail "页内自检计数不对：passed=${PASS_N:-空} failed=${FAIL_N:-空} FAIL 行=${FAIL_LINES:-空}（应为 $EXPECT_PASS/0）"
  rc=1
fi

# --- 外部证据②：对端自检计数（夹具形状是页面断言的基准，它自己也得逐条过）
SELFTEST_N="$(grep -c -F 'SELFTEST PASS' "$FIXTURE_LOG" || true)"
if [ "${SELFTEST_N:-0}" = "$EXPECT_SELFTEST" ]; then
  e2e_info "夹具生成器自检 ${SELFTEST_N}/0"
else
  e2e_fail "夹具生成器自检项数不对：${SELFTEST_N:-0}（应为 $EXPECT_SELFTEST）"
  rc=1
fi

# --- 外部证据③：进程外核对逐条（allow 与 deny 两条路都在这里闭环）
VERIFY_OK_N="$(grep -c -F 'VERIFY ok ' "$VERIFY_LOG" || true)"
VERIFY_SUM="$(grep -F 'VERIFY summary' "$VERIFY_LOG" | tail -1 || true)"
if [ "${VERIFY_OK_N:-0}" = "3" ] && printf '%s' "$VERIFY_SUM" | grep -q -F 'VERIFY summary pass'; then
  e2e_info "进程外核对 3 条 ok 且汇总为 pass（页面写的那一行在另一个进程里可见）"
else
  e2e_fail "进程外核对不成立：ok=${VERIFY_OK_N:-0} 汇总=${VERIFY_SUM:-空}"
  rc=1
fi

# --- 负向证据：授权/注册这条路一次都不该响（响了就是能力清单与插件装配对不上）
MISREPORT_N="$(grep -c -E 'command not allowed|command not registered|command does not exist' "$E2E_LOG" || true)"
if [ "${MISREPORT_N:-0}" = "0" ]; then
  e2e_info "无 command not allowed / not registered 误报（命名权限集 sqlite:default 展开正确）"
else
  e2e_fail "出现 $MISREPORT_N 条授权/注册误报（能力清单与插件提供的命令对不上）"
  grep -E 'command not allowed|command not registered|command does not exist' "$E2E_LOG" | head -5 >&2
  rc=1
fi

# --- 负向证据：越界路径**必须**被拒且只拒这一次（多了说明页面别处也在越界）
SCOPE_N="$(grep -c -F 'scope denied (sqlite)' "$E2E_LOG" || true)"
if [ "${SCOPE_N:-0}" = "1" ]; then
  e2e_info "越界路径被拒 1 次（就是自检里那次故意的 /etc/hostname）"
else
  e2e_fail "scope denied (sqlite) 出现 ${SCOPE_N:-0} 次（应为 1：自检故意越界那条）"
  grep -F 'scope denied' "$E2E_LOG" | head -5 >&2
  rc=1
fi

# --- 负向证据：护栏只该在自检那一条 ATTACH 上响（响多了说明正常语句也被误拦）
GUARD_N="$(grep -c -F 'sqlite denied: attach/detach is not allowed' "$E2E_LOG" || true)"
if [ "${GUARD_N:-0}" = "1" ]; then
  e2e_info "authorizer 只拦了 1 次（自检那条 ATTACH），其余语句照常执行"
else
  e2e_fail "authorizer 拦截 ${GUARD_N:-0} 次（应为 1：自检故意 ATTACH 那条）"
  grep -F 'sqlite denied' "$E2E_LOG" | head -5 >&2
  rc=1
fi

# --- 负向证据：命令失败必须在桥侧留一行 stderr（失败无声比失败更糟）
REJECT_N="$(grep -c -E 'command rejected \(sqlite:(query|exec|page|info)\)' "$E2E_LOG" || true)"
if [ "${REJECT_N:-0}" -ge 4 ]; then
  e2e_info "被拒的 sqlite 命令都在桥侧留了原因（$REJECT_N 条：只读写 / ATTACH / 未知表 / 不存在的库）"
else
  e2e_fail "桥侧只留了 ${REJECT_N:-0} 条 sqlite 命令拒绝原因（应有只读写/ATTACH/未知表/不存在的库 4 条）"
  rc=1
fi

e2e_finalize || rc=1
exit $rc
