#!/usr/bin/env bash
# e2e/test-linux-http-client.sh — Linux 实机 E2E：HTTP API 客户端示例（examples/http-client）
#
# 验的是完整一跳：**页面 → 桥 → IPC → 能力校验 → http:send（stdx.net.http，仓颉侧直发）
# → mock 对端 → 响应回投 → 页面渲染与断言**。
#
# 双侧对账（本示例的取信方式）：
#   页面侧 —— 34 条断言各自经 `report` 回投成 `[frontend] SELFCHECK PASS <名字>`；
#   桥侧   —— 每条请求在 stderr 留 `[http-client] GET … -> 200 78B truncated=false`，
#             被拒不建客户端的留 `refused: host=… not in allowlist`，越界读留 `[cj-tauri] scope denied (fs)`；
#   对端侧 —— mock-http.py 逐行 `[mock-http] REQ …` / `RESP … bytes=…`，收尾并入同一份证据日志。
# 判据不是「页面说自己成了」，而是**三侧能对上**：例如 /big 对端说发了 2097152 字节、
# 桥侧说只读了 1048576 且 truncated=true、页面说 bodyBytes=1048576 且 contentLength=2097152。
#
# 用法：bash scripts/e2e/test-linux-http-client.sh
#   - 无 DISPLAY 时自动在 Xvfb 下重跑（lib.sh 的 e2e_ensure_display）
#   - 在非 Linux 上默认跳过；CI 里设 CJ_TAURI_E2E_REQUIRE=linux 可让「错机」变成失败
#
# 证据：dist/e2e-evidence/linux-linux-http-client.json（双前缀是本仓约定：e2e_begin 自己再加一次平台名）
#   ~.log            应用 + 对端合并日志（前缀可分流）
#   ~-mock.log       对端（mock http）单独一份
#   ~.selftest.log   对端自检（16 项）
#   ~.build.log      示例构建日志
set -u

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

e2e_require_platform linux
e2e_ensure_display
e2e_begin "linux-http-client"

EXAMPLE="$E2E_ROOT/examples/http-client"
APP="$EXAMPLE/target/release/bin/main"
MOCK="$EXAMPLE/mock-http.py"
BUILD_LOG="$E2E_ROOT/dist/e2e-evidence/linux-http-client.build.log"
MOCK_LOG="$E2E_ROOT/dist/e2e-evidence/linux-http-client-mock.log"
# 固定端口（不用 0 让系统分配）：证据里能直接写 `127.0.0.1:8611`，人复盘时不用去日志里翻端口。
# 代价是端口被占就起不来——那时的报错是「对端没起来」+ 对端日志尾部，够定位了。
PORT=8611
E2E_NOTE="对端是本仓自写的 mock http（python3 标准库，零第三方依赖）；应用侧页内自检 34 条（状态/头逐条不合并/中文体/回显/4xx-5xx 是正常结果/超时/2MiB 截断/二进制/重定向/白名单与 scheme 拒绝/落盘往返/越界读被 scope 拦下）。收尾时对端日志并入同一份证据日志（前缀 [mock-http]），并用对端侧计数与字节数做外部对账"

# ------------------------------------------------------------------ 1) 环境与构建
# SDK 环境无条件准备：应用要加载 libcjtbridge.so 与仓颉运行时（含 stdx 动态库），
# 少一个的表象是「产物在、一跑就退」，很容易被误读成构建问题。
if ! e2e_ensure_sdk; then
  e2e_fail "找不到仓颉 SDK（设 CANGJIE_HOME）：应用需要运行时库才能启动"
  exit 1
fi

if ! command -v python3 >/dev/null 2>&1; then
  e2e_skip "缺 python3，无法起 mock http 对端"
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

# ------------------------------------------------------------------ 2) 干净工作区
# 三类落盘文件（envs/collections/history）是**用户数据**：留着上一轮的内容，
# 「首次运行给默认集」这类断言就不再确定性（实测：自检拿上一轮的 base 去比本轮的 mock 地址，红）。
# 所以 E2E 每次从干净工作区起跑；目录本身由脚本保证存在（插件面里故意没有 mkdir）。
mkdir -p "$EXAMPLE/data"
rm -f "$EXAMPLE"/data/*.json

# ------------------------------------------------------------------ 3) 对端自检 + 起 mock http
# 对端先自己跑一遍自检（16 项）：对端坏掉时就在这一步失败，别让「对端不认请求」冒充成客户端的问题。
SELFTEST_LOG="$E2E_ROOT/dist/e2e-evidence/linux-http-client.selftest.log"
if ! python3 "$MOCK" --selftest >"$SELFTEST_LOG" 2>&1; then
  e2e_fail "mock http 自检没过，见 $SELFTEST_LOG"
  tail -20 "$SELFTEST_LOG" >&2
  exit 1
fi
e2e_info "mock http 对端自检通过（$(grep -c -F 'SELFTEST PASS' "$SELFTEST_LOG" || true) 项）"

# 只用 stdout 收口，**不再传 --log**：同一份证据写两遍会让 grep -c 计数翻倍（AGENTS §4 有实例）。
: >"$MOCK_LOG"
python3 "$MOCK" --port "$PORT" >"$MOCK_LOG" 2>&1 &
MOCK_PID=$!

cleanup() { [ -n "${MOCK_PID:-}" ] && kill "$MOCK_PID" 2>/dev/null || true; }
trap cleanup EXIT

# 就绪判据是对端自己打的那行 READY（不是固定 sleep：等固定时间会把慢启动读成失败）
READY_NEEDLE="[mock-http] READY port=$PORT"
READY=0
for _ in $(seq 1 40); do
  if grep -q -F "$READY_NEEDLE" "$MOCK_LOG" 2>/dev/null; then READY=1; break; fi
  if ! kill -0 "$MOCK_PID" 2>/dev/null; then break; fi
  sleep 0.25
done
if [ "$READY" != "1" ]; then
  e2e_fail "mock http 没起来（等「$READY_NEEDLE」超时）——见 $MOCK_LOG"
  tail -20 "$MOCK_LOG" >&2
  exit 1
fi
e2e_info "mock http 已就绪 127.0.0.1:$PORT pid=$MOCK_PID"

# ------------------------------------------------------------------ 4) 实机跑一轮
# 三样都由宿主经环境变量给页面（页面读不到进程环境）：
#   CJ_HTTP_MOCK_BASE  快捷端点按钮与自检的地址来源
#   CJ_HTTP_ALLOW      白名单（不给就只放行本机；example.invalid 那条**必须**被拒）
#   CJ_HTTP_SELFCHECK  自检开关
export CJ_HTTP_MOCK_BASE="http://127.0.0.1:$PORT"
export CJ_HTTP_ALLOW="127.0.0.1"
export CJ_HTTP_SELFCHECK=1

e2e_set_cwd "$EXAMPLE"
e2e_run_app "$APP"

rc=0
# 等的是**页面跑完整个自检之后打的那行**：只等「窗口出现」证明不了这一跳
# （窗口照起、连不上对端的情况会被判通过）。
if ! e2e_wait_log "[frontend] SELFCHECK DONE" 180; then
  rc=1
fi
e2e_stop_app
kill "$MOCK_PID" 2>/dev/null || true
MOCK_PID=""
trap - EXIT

# ------------------------------------------------------------------ 5) 对端日志并入同一份证据日志
# 两侧证据放一起，「谁没说话」靠前缀分流；对端自己那份仍单独留档给人看。
{
  printf '\n[merge] 下面是 mock http（对端）一侧日志，前缀 [mock-http]\n'
  cat "$MOCK_LOG" 2>/dev/null || true
  printf '[merge] 对端日志结束\n'
} >> "$E2E_LOG"

# ------------------------------------------------------------------ 6) 取证
# needle 用整行前缀或不撞词的长子串（AGENTS §4：中缀过滤器会骗人；断言名里不许带冒号）。
# --- 应用侧：启动与装配
e2e_assert "示例应用启动"                "[http-client] main start"
e2e_assert "自检开关与白名单已注入"      "[http-client] main start (selfcheck=true, allow=127.0.0.1"
e2e_assert "能力清单已加载"              "[cj-tauri] 已自动加载 capabilities/：1 个清单"
e2e_assert "窗口已创建"                  "[cj-bridge] set window: title=cj-tauri HTTP 客户端"
e2e_assert "页面已拿到桥内配置"          "[frontend] SELFCHECK enabled mockBase=http://127.0.0.1:$PORT"
# --- 页面侧：34 条自检逐条（每条都是页面自己算的结论）
e2e_assert "自检 白名单已描述"           "[frontend] SELFCHECK PASS allow.describe"
e2e_assert "自检 白名单有条目"           "[frontend] SELFCHECK PASS allow.entries"
e2e_assert "自检 变量展开"               "[frontend] SELFCHECK PASS var.expand"
e2e_assert "自检 未定义变量原样保留"     "[frontend] SELFCHECK PASS var.unknown.kept"
e2e_assert "自检 变量集已载入"           "[frontend] SELFCHECK PASS var.set.loaded"
e2e_assert "自检 落盘写成功"             "[frontend] SELFCHECK PASS fs.write.ok"
e2e_assert "自检 落盘往返一致"           "[frontend] SELFCHECK PASS fs.roundtrip"
e2e_assert "自检 变量集已落盘"           "[frontend] SELFCHECK PASS envs.persist"
e2e_assert "自检 越界读被拒"             "[frontend] SELFCHECK PASS fs.scope.denied"
e2e_assert "自检 JSON 状态码 200"        "[frontend] SELFCHECK PASS json.status"
e2e_assert "自检 Content-Type 已回投"    "[frontend] SELFCHECK PASS json.contenttype"
e2e_assert "自检 自定义头已回投"         "[frontend] SELFCHECK PASS json.custom.header"
e2e_assert "自检 同名头未合并（2 条）"   "[frontend] SELFCHECK PASS json.setcookie.notmerged"
e2e_assert "自检 响应体逐字一致"         "[frontend] SELFCHECK PASS json.body.exact"
e2e_assert "自检 体类型判定为文本"       "[frontend] SELFCHECK PASS json.bodykind"
e2e_assert "自检 页面状态码已显示"       "[frontend] SELFCHECK PASS ui.status.shown"
e2e_assert "自检 头部表格行数吻合"       "[frontend] SELFCHECK PASS ui.header.rows"
e2e_assert "自检 JSON 树已渲染"          "[frontend] SELFCHECK PASS ui.json.tree"
e2e_assert "自检 中文体 UTF-8 解码"      "[frontend] SELFCHECK PASS text.unicode"
e2e_assert "自检 回显自定义头"           "[frontend] SELFCHECK PASS echo.get.header"
e2e_assert "自检 回显查询串"             "[frontend] SELFCHECK PASS echo.get.query"
e2e_assert "自检 回显 POST 体"           "[frontend] SELFCHECK PASS echo.post.body"
e2e_assert "自检 请求体字节数双侧一致"   "[frontend] SELFCHECK PASS echo.post.bytes"
e2e_assert "自检 404 是正常结果"         "[frontend] SELFCHECK PASS status.404.resolves"
e2e_assert "自检 500 是正常结果"         "[frontend] SELFCHECK PASS status.500.resolves"
e2e_assert "自检 超时变成 reject"        "[frontend] SELFCHECK PASS slow.timeout.rejects"
e2e_assert "自检 大响应已截断"           "[frontend] SELFCHECK PASS big.truncated"
e2e_assert "自检 读到的就是上限字节"     "[frontend] SELFCHECK PASS big.bytes.limit"
e2e_assert "自检 Content-Length 如实报"  "[frontend] SELFCHECK PASS big.contentlength"
e2e_assert "自检 二进制体判定"           "[frontend] SELFCHECK PASS binary.kind"
e2e_assert "自检 二进制体只报字节数"     "[frontend] SELFCHECK PASS binary.bytes"
e2e_assert "自检 重定向已跟随"           "[frontend] SELFCHECK PASS redirect.followed"
e2e_assert "自检 白名单外被拒"           "[frontend] SELFCHECK PASS allow.blocked.host"
e2e_assert "自检 不支持的 scheme 被拒"   "[frontend] SELFCHECK PASS scheme.unsupported"
# --- 桥侧：每条请求的结局
e2e_assert "JSON 端点 200（桥侧）"       "[http-client] GET http://127.0.0.1:$PORT/json -> 200"
e2e_assert "404 不是异常（桥侧）"        "[http-client] GET http://127.0.0.1:$PORT/status/404 -> 404"
e2e_assert "500 不是异常（桥侧）"        "[http-client] GET http://127.0.0.1:$PORT/status/500 -> 500"
e2e_assert "超时如实报传输失败"          "/slow?ms=3000 -> failed: HttpTimeoutException"
e2e_assert "截断在桥侧留凭证"            "truncated=true"
# needle 里别夹耗时字段（"→ 200 4B 1ms truncated=false" 的毫秒每轮都变，夹进去必然假红——第一版就栽在这）
e2e_assert "二进制体只报字节数（桥侧）"  "/binary -> 200 4B"
e2e_assert "重定向已跟随（桥侧最终 200）" "/redirect -> 200 78B"
e2e_assert "白名单外被拒且不建客户端"    "refused: host=example.invalid not in allowlist"
e2e_assert "越界读在桥侧被拒"            "[cj-tauri] scope denied (fs)"
# --- 对端侧
e2e_assert "对端已监听"                  "[mock-http] READY port=$PORT"
e2e_assert "对端看见 POST /echo"         "[mock-http] REQ method=POST path=/echo"
e2e_assert "对端看见 404 请求"           "[mock-http] REQ method=GET path=/status/404"
e2e_assert "对端回了 404"                "[mock-http] RESP status=404 path=/status/404"
e2e_assert "对端回了 302（重定向起点）"  "[mock-http] RESP status=302 path=/redirect"
e2e_assert "对端看见二进制请求"          "[mock-http] REQ method=GET path=/binary"
e2e_assert "对端回了 2MiB（带字节数）"   "[mock-http] RESP status=200 path=/big bytes=2097152"

# --- 外部证据①：页内自检计数逐字对账（只有「跑完了」不算，得看 34/0 且 0 条 FAIL 行）
DONE_LINE="$(grep -F '[frontend] SELFCHECK DONE' "$E2E_LOG" | tail -1 || true)"
PASS_N="$(printf '%s' "$DONE_LINE" | sed -n 's/.*passed=\([0-9]*\).*/\1/p')"
FAIL_N="$(printf '%s' "$DONE_LINE" | sed -n 's/.*failed=\([0-9]*\).*/\1/p')"
FAIL_LINES="$(grep -c -F '[frontend] SELFCHECK FAIL' "$E2E_LOG" || true)"
if [ "${PASS_N:-0}" = "34" ] && [ "${FAIL_N:-1}" = "0" ] && [ "${FAIL_LINES:-1}" = "0" ]; then
  e2e_info "页内自检 34/0，且日志里 0 条 FAIL 行"
else
  e2e_fail "页内自检计数不对：passed=${PASS_N:-空} failed=${FAIL_N:-空} FAIL 行=${FAIL_LINES:-空}"
  rc=1
fi

# --- 外部证据②：截断三侧对账（对端说发了多少 / 桥说读了多少）
PEER_BIG="$(grep -F '[mock-http] RESP status=200 path=/big' "$E2E_LOG" | tail -1 || true)"
PEER_BIG_BYTES="$(printf '%s' "$PEER_BIG" | sed -n 's/.*bytes=\([0-9]*\).*/\1/p')"
BRIDGE_BIG="$(grep -F "/big?kb=2048 -> 200" "$E2E_LOG" | tail -1 || true)"
BRIDGE_BIG_BYTES="$(printf '%s' "$BRIDGE_BIG" | sed -n 's/.*-> 200 \([0-9]*\)B.*/\1/p')"
if [ "${PEER_BIG_BYTES:-0}" = "2097152" ] && [ "${BRIDGE_BIG_BYTES:-0}" = "1048576" ]; then
  e2e_info "截断对账成立：对端发出 $PEER_BIG_BYTES 字节，桥只读了 $BRIDGE_BIG_BYTES 字节（页面侧 bodyBytes 同值、contentLength 报全量）"
else
  e2e_fail "截断对账不成立：对端 bytes=${PEER_BIG_BYTES:-空} 桥读到=${BRIDGE_BIG_BYTES:-空}"
  rc=1
fi

# --- 外部证据③：对端 REQ/RESP 计数 —— 差 1 就是被超时中断的 /slow（超时路径必须在对端侧看得见）
REQ_N="$(grep -c -F '[mock-http] REQ method=' "$E2E_LOG" || true)"
RESP_N="$(grep -c -F '[mock-http] RESP status=' "$E2E_LOG" || true)"
SLOW_REQ_N="$(grep -c -F '[mock-http] REQ method=GET path=/slow' "$E2E_LOG" || true)"
SLOW_RESP_N="$(grep -c -F '[mock-http] RESP status=200 path=/slow' "$E2E_LOG" || true)"
if [ "${SLOW_REQ_N:-0}" = "1" ] && [ "${SLOW_RESP_N:-0}" = "0" ] \
   && [ "${RESP_N:-0}" = "$(( ${REQ_N:-0} - 1 ))" ]; then
  e2e_info "对端侧对账成立：REQ=$REQ_N RESP=$RESP_N（差的那 1 条正是被超时中断的 /slow）"
else
  e2e_fail "对端侧对账不成立：REQ=${REQ_N:-空} RESP=${RESP_N:-空} slow_req=${SLOW_REQ_N:-空} slow_resp=${SLOW_RESP_N:-空}"
  rc=1
fi

# --- 外部证据④：请求体字节数双侧一致（页面按 UTF-8 自算 22 / 对端 Content-Length 数出 22）
POST_LINE="$(grep -F '[mock-http] REQ method=POST path=/echo' "$E2E_LOG" | tail -1 || true)"
POST_LEN="$(printf '%s' "$POST_LINE" | sed -n 's/.*len=\([0-9]*\).*/\1/p')"
if [ "${POST_LEN:-0}" = "22" ]; then
  e2e_info "POST 体长双侧一致：对端收到 $POST_LEN 字节（页面侧 TextEncoder 同值）"
else
  e2e_fail "POST 体长对不上：对端收到 ${POST_LEN:-空} 字节（应为 22）"
  rc=1
fi

# --- 负向证据：授权/注册这条路一次都不该响（响了就是能力清单与注册对不上）
MISREPORT_N="$(grep -c -E 'command not allowed|command not registered|command does not exist' "$E2E_LOG" || true)"
if [ "${MISREPORT_N:-0}" = "0" ]; then
  e2e_info "无 command not allowed / not registered 误报"
else
  e2e_fail "出现 $MISREPORT_N 条授权/注册误报（能力清单与注册对不上）"
  grep -E 'command not allowed|command not registered|command does not exist' "$E2E_LOG" | head -5 >&2
  rc=1
fi

# --- 负向证据：越界读**必须**被拒且只拒这一次（多了说明页面别处也在越界）
SCOPE_N="$(grep -c -F 'scope denied' "$E2E_LOG" || true)"
if [ "${SCOPE_N:-0}" = "1" ]; then
  e2e_info "越界读被拒 1 次（就是自检里那次故意越界）"
else
  e2e_fail "scope denied 出现 ${SCOPE_N:-0} 次（应为 1：自检故意越界那条）"
  grep -F 'scope denied' "$E2E_LOG" | head -5 >&2
  rc=1
fi

# --- 负向证据：传输层失败不许吞掉「为什么发不出去」（调试工具的核心语义）
REJECT_N="$(grep -c -F 'command rejected (http:send)' "$E2E_LOG" || true)"
if [ "${REJECT_N:-0}" -ge 3 ]; then
  e2e_info "被拒的 http:send 都在桥侧留了原因（$REJECT_N 条：超时 + 白名单 + scheme）"
else
  e2e_fail "桥侧只留了 ${REJECT_N:-0} 条 http:send 拒绝原因（应有超时/白名单/scheme 至少 3 条）"
  rc=1
fi

e2e_finalize || rc=1
exit $rc
