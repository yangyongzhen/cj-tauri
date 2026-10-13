#!/usr/bin/env bash
# e2e/test-linux-redis-client.sh — Linux 实机 E2E：Redis 调试台示例（examples/redis-client）
#
# 验的是完整一跳：**页面 → 桥 → IPC → 能力校验 → redis:connect/scan/value/valueWrite/…
# → 仓颉侧 RESP2 客户端（std.net TCP，两条连接：命令 + 订阅）→ 对端 →（回推）→ 订阅读线程
# → 事件 redis:message + 缓冲 redis:messages → 页面**。
#
# 为什么不装一个真 redis-server：本机没有，装一个还要跟版本与配置漂移较劲；而这里要验的东西很窄——
# **我们发出去的 RESP 字节对端认不认、对端发回来的字节我们认不认**。自写对端的另一个好处是
# 两侧都有日志（应用侧 `[frontend] REDIS ` / `[cj-tauri] redis`，对端侧 `[mock-redis]`），
# 于是「到底谁没说话」一眼可分——收尾时对端日志会并入同一份证据日志，断言一起进 JSON。
#
# 用法：bash scripts/e2e/test-linux-redis-client.sh
#   - 无 DISPLAY 时自动在 Xvfb 下重跑（lib.sh 的 e2e_ensure_display）
#   - 在非 Linux 上默认跳过；CI 里设 CJ_TAURI_E2E_REQUIRE=linux 可让「错机」变成失败
#
# 证据：dist/e2e-evidence/linux-redis-client.json
#   ~.log            应用 + 对端合并日志（前缀可分流）
#   ~-mock.log       对端（mock redis）单独一份
#   ~.build.log      示例构建日志
set -u

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

e2e_require_platform linux
e2e_ensure_display
e2e_begin "linux-redis-client"

EXAMPLE="$E2E_ROOT/examples/redis-client"
APP="$EXAMPLE/target/release/bin/main"
MOCK="$EXAMPLE/mock-redis.py"
BUILD_LOG="$E2E_ROOT/dist/e2e-evidence/linux-redis-client.build.log"
MOCK_LOG="$E2E_ROOT/dist/e2e-evidence/linux-redis-client-mock.log"
PORT=63790
E2E_NOTE="对端是本仓自写的 RESP2 mock redis（python3，无第三方依赖，启动即 seed 14 个键 + 1 个 db1 键）；应用侧探针自动 连接→INFO/SLOWLOG→SCAN(全量/match/type)→六种类型取值→写与回读→EXPIRE/PERSIST/RENAME/DEL→订阅(频道+模式)→发布→messages 对账→状态→断开→重连→自退。收尾时对端日志并入同一份证据日志（前缀 [mock-redis]）"

# ------------------------------------------------------------------ 1) 环境与构建
# SDK 环境无条件准备：应用要加载 libcjtbridge.so 与仓颉运行时（含 stdx 动态库），
# 少一个的表象是「产物在、一跑就退」，很容易被误读成构建问题。
if ! e2e_ensure_sdk; then
  e2e_fail "找不到仓颉 SDK（设 CANGJIE_HOME）：应用需要运行时库才能启动"
  exit 1
fi

if ! command -v python3 >/dev/null 2>&1; then
  e2e_skip "缺 python3，无法起 mock redis 对端"
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

# ------------------------------------------------------------------ 2) 对端自检 + 起 mock redis
# 对端先自己跑一遍自检（12 项）：对端坏掉时先在这里失败，别让「对端不认命令」冒充成客户端的问题。
SELFTEST_LOG="$E2E_ROOT/dist/e2e-evidence/linux-redis-client.selftest.log"
if ! python3 "$MOCK" --selftest >"$SELFTEST_LOG" 2>&1; then
  e2e_fail "mock redis 自检没过，见 $SELFTEST_LOG"
  tail -20 "$SELFTEST_LOG" >&2
  exit 1
fi
e2e_info "mock redis 对端自检通过（$(grep -c -F 'PASS' "$SELFTEST_LOG" || true) 项）"

: >"$MOCK_LOG"
python3 "$MOCK" --port "$PORT" >"$MOCK_LOG" 2>&1 &
MOCK_PID=$!

cleanup() { [ -n "${MOCK_PID:-}" ] && kill "$MOCK_PID" 2>/dev/null || true; }
trap cleanup EXIT

# 就绪判据是对端自己打的那行「已监听」，不是固定 sleep（AGENTS §4：等固定时间会把慢启动读成失败）
LISTEN_NEEDLE="[mock-redis] listening on 127.0.0.1:$PORT"
READY=0
for _ in $(seq 1 40); do
  if grep -q -F "$LISTEN_NEEDLE" "$MOCK_LOG" 2>/dev/null; then READY=1; break; fi
  if ! kill -0 "$MOCK_PID" 2>/dev/null; then break; fi
  sleep 0.25
done
if [ "$READY" != "1" ]; then
  e2e_fail "mock redis 没起来（等「$LISTEN_NEEDLE」超时）——见 $MOCK_LOG"
  tail -20 "$MOCK_LOG" >&2
  exit 1
fi
e2e_info "mock redis 已就绪 127.0.0.1:$PORT pid=$MOCK_PID"

# ------------------------------------------------------------------ 3) 探针模式跑一轮
# 配置由宿主经 document-start 预执行脚本注入页面（窗口创建前就定稿），页面加载即自动开跑。
export CJ_REDIS_PROBE_HOST=127.0.0.1
export CJ_REDIS_PROBE_PORT="$PORT"
export CJ_REDIS_PROBE_DB=0
export CJ_REDIS_PROBE_MS=8000
export CJ_REDIS_PROBE_QUIT=1

e2e_set_cwd "$EXAMPLE"
e2e_run_app "$APP"

rc=0
# 等的是**页面自己跑完整个流程之后打的那行**：只等「窗口出现」证明不了这一跳
# （窗口照起、连不上对端的情况会被判通过）。
if ! e2e_wait_log "[frontend] REDIS probe done verdict=ok" 120; then
  rc=1
fi
e2e_stop_app
kill "$MOCK_PID" 2>/dev/null || true
MOCK_PID=""
trap - EXIT

# ------------------------------------------------------------------ 4) 对端日志并入同一份证据日志
# 两侧证据放一起，「谁没说话」靠前缀分流；对端自己那份仍单独留档给人看。
{
  printf '\n[merge] 下面是 mock redis（对端）一侧日志，前缀 [mock-redis]\n'
  cat "$MOCK_LOG" 2>/dev/null || true
  printf '[merge] 对端日志结束\n'
} >> "$E2E_LOG"

# ------------------------------------------------------------------ 5) 取证
# needle 用整行前缀或不撞词的长子串（AGENTS §4：中缀过滤器会骗人；跨字段的字面量也匹配不上）。
# --- 应用侧：启动与装配
e2e_assert "示例应用启动"              "[redis-client] main start"
e2e_assert "探针配置已注入"            "[redis-client] 探针模式："
e2e_assert "能力清单已加载"            "[cj-tauri] 已自动加载 capabilities/：1 个清单"
e2e_assert "redis 插件已装配（短名注册）" "redis  redis:connect"
# --- 连接
e2e_assert "页面报告连接成功"          "[frontend] REDIS probe connect ok host=127.0.0.1"
e2e_assert "未认证服务器如实报 auth=false" "auth=false"
e2e_assert "状态查询回投"              "[frontend] REDIS probe status state=connected"
# --- 服务器诊断
e2e_assert "INFO 已取回并解析"         "[frontend] REDIS probe info bytes="
e2e_assert "SLOWLOG 已取回"            "[frontend] REDIS probe slowlog count="
# --- 键空间
e2e_assert "SCAN 全量拿到 14 个键"     "[frontend] REDIS probe scan all keys=14"
e2e_assert "SCAN 每个键都补了 TYPE/TTL" "[frontend] REDIS probe scan all keys=14 done=true enriched=14"
e2e_assert "SCAN MATCH 生效"           "[frontend] REDIS probe scan match=user:* keys=3"
e2e_assert "SCAN TYPE 过滤生效"        "[frontend] REDIS probe scan type=hash keys=1"
# --- 六种类型取值
e2e_assert "string 取值（whole）"      "[frontend] REDIS probe value key=user:1 type=string mode=whole"
e2e_assert "二进制值按字节保真（hex）"  "hex=0001FFFE"
e2e_assert "hash 游标分页取值"         "[frontend] REDIS probe value key=user:1:profile type=hash mode=cursor total=3"
e2e_assert "list 区间取值"             "[frontend] REDIS probe value key=queue:jobs type=list mode=range total=3"
e2e_assert "set 游标分页取值"          "[frontend] REDIS probe value key=tags:news type=set mode=cursor total=3"
e2e_assert "zset 带分值取值"           "[frontend] REDIS probe value key=board:score type=zset mode=range total=3"
e2e_assert "stream 条目取值"           "[frontend] REDIS probe value key=events:app type=stream mode=range total=2"
# --- 写与键操作
e2e_assert "写 string 成功"            "[frontend] REDIS probe write SET probe:greeting reply=simple(OK)"
e2e_assert "追加成功"                  "[frontend] REDIS probe write APPEND reply=number(16)"
e2e_assert "写后回读一致"              "[frontend] REDIS probe read back probe:greeting text=hello-probe-tail bytes=16"
e2e_assert "写 hash 字段成功"          "[frontend] REDIS probe write HSET probe:hash reply=number(1)"
e2e_assert "EXPIRE 生效（keyInfo 读到 ttl）" "[frontend] REDIS probe keyInfo key=probe:greeting ttl="
e2e_assert "PERSIST 生效"              "[frontend] REDIS probe keyPersist applied=true"
e2e_assert "RENAME 生效"               "[frontend] REDIS probe keyRename newKey=probe:renamed"
e2e_assert "DEL 生效（两个都在）"      "[frontend] REDIS probe keyDelete requested=2 deleted=2"
# --- 发布订阅
e2e_assert "订阅（频道 + 模式）成功"   "[frontend] REDIS probe subscribe ok=true channels=1 patterns=1"
e2e_assert "发布回投接收者数"          "[frontend] REDIS probe publish channel=demo/rx"
e2e_assert "频道消息经事件通道到达"    "[frontend] REDIS message seq=1 kind=message ch=demo/rx"
e2e_assert "模式消息经事件通道到达"    "[frontend] REDIS message seq=2 kind=pmessage ch=demo/rx"
e2e_assert "载荷逐字到达"              "payload=hello-from-cj-tauri"
e2e_assert "拉取通道对账"              "[frontend] REDIS probe messages count=2 seen=2 dropped=0"
# --- 收尾
e2e_assert "断开时带走了订阅连接"      "[frontend] REDIS probe disconnect hadSub=true droppedChannels=1"
e2e_assert "重连成功"                  "[frontend] REDIS probe reconnect ok state=connected"
e2e_assert "探针跑完（verdict=ok）"    "[frontend] REDIS probe done verdict=ok"
# --- 对端侧
e2e_assert "对端已监听"                "[mock-redis] listening on 127.0.0.1:$PORT"
e2e_assert "对端看见客户端接入"        "[mock-redis] client connected 127.0.0.1:"
e2e_assert "HSCAN 已到达对端"          "[mock-redis] HSCAN rx args="
e2e_assert "SSCAN 已到达对端"          "[mock-redis] SSCAN rx args="
e2e_assert "DEL 已到达对端"            "[mock-redis] DEL rx args="
e2e_assert "EXPIRE 已到达对端"         "[mock-redis] EXPIRE rx args="
e2e_assert "RENAME 已到达对端"         "[mock-redis] RENAME rx args="
e2e_assert "SUBSCRIBE 已到达对端"      "[mock-redis] SUBSCRIBE rx args="
e2e_assert "PUBLISH 已到达对端"        "[mock-redis] PUBLISH rx args="
e2e_assert "对端把消息推给了订阅连接"  "[mock-redis] PUBLISH push ch="

# 外部证据①：接收者数与消息条数要立得住（只写「有回推」是空话）
PUB_LINE="$(grep -F "[frontend] REDIS probe publish channel=demo/rx" "$E2E_LOG" | tail -1 || true)"
PUB_N="$(printf '%s' "$PUB_LINE" | sed -n 's/.*receivers=\([0-9]*\).*/\1/p')"
if [ -n "$PUB_N" ] && [ "$PUB_N" -ge 1 ]; then
  e2e_info "发布时对端报告 receivers=$PUB_N（>=1：订阅连接确实在频道上）"
else
  e2e_fail "receivers 读不出或为 0（读到「${PUB_N:-空}」）：$PUB_LINE"
  rc=1
fi

# 外部证据②：INFO 的字节数要真的解析出段来（只有「拿到了」不算，得证明解出了内容）
INFO_LINE="$(grep -F "[frontend] REDIS probe info bytes=" "$E2E_LOG" | tail -1 || true)"
INFO_BYTES="$(printf '%s' "$INFO_LINE" | sed -n 's/.*bytes=\([0-9]*\).*/\1/p')"
INFO_PARSED="$(printf '%s' "$INFO_LINE" | sed -n 's/.*parsed=\([0-9]*\).*/\1/p')"
if [ -n "$INFO_BYTES" ] && [ "$INFO_BYTES" -gt 0 ] && [ -n "$INFO_PARSED" ] && [ "$INFO_PARSED" -ge 3 ]; then
  e2e_info "INFO 取回 $INFO_BYTES 字节、解析出 $INFO_PARSED 段"
else
  e2e_fail "INFO 字节数/段数不达标（bytes=${INFO_BYTES:-空} parsed=${INFO_PARSED:-空}）：$INFO_LINE"
  rc=1
fi

# 外部证据③：重连不是页面自己说的，而是对端**第二次**看见客户端接入
CONN_N="$(grep -c -F "[mock-redis] client connected 127.0.0.1:" "$MOCK_LOG" 2>/dev/null || true)"
if [ -n "$CONN_N" ] && [ "$CONN_N" -ge 2 ]; then
  e2e_info "对端共看见 $CONN_N 次客户端接入（断开后重连成立）"
else
  e2e_fail "对端只看见 ${CONN_N:-0} 次接入：重连没被对端看见，见 $MOCK_LOG"
  rc=1
fi

# 负向证据：授权/注册这条路一次都不该响（响了就是能力清单与注册对不上）
MISREPORT_N="$(grep -c -E 'command not allowed|command not registered|command does not exist' "$E2E_LOG" 2>/dev/null || true)"
if [ "${MISREPORT_N:-0}" = "0" ]; then
  e2e_info "无 command not allowed / not registered 误报"
else
  e2e_fail "出现 $MISREPORT_N 条授权/注册误报（能力清单与插件注册对不上）"
  grep -E 'command not allowed|command not registered|command does not exist' "$E2E_LOG" | head -5 >&2
  rc=1
fi

# 负向证据：取值的两条分页通道（HSCAN/SSCAN）在实机那一轮曾整条失败过，这里不许再复现
SHAPE_N="$(grep -c -E 'HSCAN 回复形状不对|SSCAN 回复形状不对|REDIS value failed' "$E2E_LOG" 2>/dev/null || true)"
if [ "${SHAPE_N:-0}" = "0" ]; then
  e2e_info "无取值失败行（六种类型的取值路径都走通了）"
else
  e2e_fail "出现 $SHAPE_N 条取值失败行"
  grep -E 'HSCAN 回复形状不对|SSCAN 回复形状不对|REDIS value failed' "$E2E_LOG" | head -5 >&2
  rc=1
fi

e2e_finalize || rc=1
exit $rc
