#!/usr/bin/env bash
# e2e/test-linux-mqtt-client.sh — Linux 实机 E2E：MQTT 调试台示例（examples/mqtt-client）
#
# 验的是完整一跳：**页面 → 桥 → IPC → 能力校验 → mqtt:connect/subscribe/publish
# → 仓颉侧 MQTT 3.1.1 客户端（std.net TCP）→ 对端 broker →（回推）→ 读线程
# → 事件 mqtt:message + 缓冲 mqtt:recent → 页面**。
#
# 为什么不装一个真 broker：本机没有，装一个还要跟版本与 systemd 较劲；而这里要验的东西很窄——
# **我们发出去的字节对端认不认、对端发回来的字节我们认不认**。自写对端的另一个好处是
# 两侧都有日志（应用侧 `[cj-tauri] mqtt:` / `[frontend] MQTT `，对端侧 `[mock-broker]`），
# 于是「到底谁没说话」一眼可分——收尾时对端日志会并入同一份证据日志，断言一起进 JSON。
#
# 用法：bash scripts/e2e/test-linux-mqtt-client.sh
#   - 无 DISPLAY 时自动在 Xvfb 下重跑（lib.sh 的 e2e_ensure_display）
#   - 在非 Linux 上默认跳过；CI 里设 CJ_TAURI_E2E_REQUIRE=linux 可让「错机」变成失败
#
# 证据：dist/e2e-evidence/linux-mqtt-client.json
#   ~.log        应用 + 对端合并日志（前缀可分流）
#   ~-broker.log 对端（mock broker）单独一份
#   ~.build.log  示例构建日志
set -u

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

e2e_require_platform linux
e2e_ensure_display
e2e_begin "linux-mqtt-client"

EXAMPLE="$E2E_ROOT/examples/mqtt-client"
APP="$EXAMPLE/target/release/bin/main"
BROKER="$EXAMPLE/mock-broker.py"
BUILD_LOG="$E2E_ROOT/dist/e2e-evidence/linux-mqtt-client.build.log"
BROKER_LOG="$E2E_ROOT/dist/e2e-evidence/linux-mqtt-client-broker.log"
PORT=18830
E2E_NOTE="对端是本仓自写的 MQTT 3.1.1 mock broker（python3，无第三方依赖）；应用侧探针自动 连接→订阅→发布(QoS1)→发布(QoS2)→等回推（含 1s 保活心跳）→recent 对账→断开→重连→自退。收尾时对端日志并入同一份证据日志（前缀 [mock-broker]）"

# ------------------------------------------------------------------ 1) 环境与构建
# SDK 环境无条件准备：应用要加载 libcjtbridge.so 与仓颉运行时（含 stdx 动态库），
# 少一个的表象是「产物在、一跑就退」，很容易被误读成构建问题。
if ! e2e_ensure_sdk; then
  e2e_fail "找不到仓颉 SDK（设 CANGJIE_HOME）：应用需要运行时库才能启动"
  exit 1
fi

if ! command -v python3 >/dev/null 2>&1; then
  e2e_skip "缺 python3，无法起 mock broker 对端"
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

# ------------------------------------------------------------------ 2) 起 mock broker 对端
: >"$BROKER_LOG"
python3 "$BROKER" --port "$PORT" >"$BROKER_LOG" 2>&1 &
BROKER_PID=$!

cleanup() { [ -n "${BROKER_PID:-}" ] && kill "$BROKER_PID" 2>/dev/null || true; }
trap cleanup EXIT

# 就绪判据是对端自己打的那行「已监听」，不是固定 sleep（AGENTS §4：等固定时间会把慢启动读成失败）
LISTEN_NEEDLE="[mock-broker] listening on 127.0.0.1:$PORT"
READY=0
for _ in $(seq 1 40); do
  if grep -q -F "$LISTEN_NEEDLE" "$BROKER_LOG" 2>/dev/null; then READY=1; break; fi
  if ! kill -0 "$BROKER_PID" 2>/dev/null; then break; fi
  sleep 0.25
done
if [ "$READY" != "1" ]; then
  e2e_fail "mock broker 没起来（等「$LISTEN_NEEDLE」超时）——见 $BROKER_LOG"
  tail -20 "$BROKER_LOG" >&2
  exit 1
fi
e2e_info "mock broker 已就绪 127.0.0.1:$PORT pid=$BROKER_PID"

# ------------------------------------------------------------------ 3) 探针模式跑一轮
# 配置由宿主经 document-start 预执行脚本注入页面（窗口创建前就定稿），页面加载即自动开跑。
export CJ_MQTT_PROBE_HOST=127.0.0.1
export CJ_MQTT_PROBE_PORT="$PORT"
export CJ_MQTT_PROBE_MS=6000
export CJ_MQTT_PROBE_QUIT=1

e2e_set_cwd "$EXAMPLE"
e2e_run_app "$APP"

rc=0
# 等的是**页面自己跑完整个流程之后打的那行**：只等「窗口出现」证明不了这一跳
# （窗口照起、连不上 broker 的情况会被判通过）。
if ! e2e_wait_log "[frontend] MQTT probe done" 90; then
  rc=1
fi
e2e_stop_app
kill "$BROKER_PID" 2>/dev/null || true
BROKER_PID=""
trap - EXIT

# ------------------------------------------------------------------ 4) 对端日志并入同一份证据日志
# 两侧证据放一起，「谁没说话」靠前缀分流；对端自己那份仍单独留档给人看。
{
  printf '\n[merge] 下面是 mock broker（对端）一侧日志，前缀 [mock-broker]\n'
  cat "$BROKER_LOG" 2>/dev/null || true
  printf '[merge] 对端日志结束\n'
} >> "$E2E_LOG"

# ------------------------------------------------------------------ 5) 取证
# needle 用整行前缀或不撞词的长子串（AGENTS §4：中缀过滤器会骗人）。
e2e_assert "示例应用启动"            "[mqtt-client] main start"
e2e_assert "探针配置已注入"          "[mqtt-client] 探针模式："
e2e_assert "能力清单已加载"          "[cj-tauri] 已自动加载 capabilities/：1 个清单"
e2e_assert "会话进入已连接（stderr 取证行）" "[cj-tauri] mqtt: state=connected"
e2e_assert "页面报告连接成功"        "[frontend] MQTT connect ok state=connected"
e2e_assert "订阅回执已处理"          "[frontend] MQTT subscribe result state=subscribed"
e2e_assert "QoS1 发布成功"           "[frontend] MQTT publish ok topic=demo/tx"
e2e_assert "QoS2 发布已发出"         "[frontend] MQTT probe publish qos2 topic=demo/tx"
e2e_assert "recent 拉取通道有数据"   "[frontend] MQTT probe recent count="
e2e_assert "对端回推报文进了缓冲"    "rx:PUBLISH:demo/hash"
e2e_assert "状态查询收口"            "[frontend] MQTT probe status state=connected"
e2e_assert "重连成功"                "[frontend] MQTT probe reconnect state=connected"
e2e_assert "探针跑完"                "[frontend] MQTT probe done"
e2e_assert "对端已监听"              "[mock-broker] listening on 127.0.0.1:$PORT"
e2e_assert "CONNECT 已到达对端"      "[mock-broker] CONNECT proto=MQTT level=4"
e2e_assert "CONNACK 已发出"          "[mock-broker] CONNACK tx rc=0"
e2e_assert "SUBSCRIBE/SUBACK 往返"   "[mock-broker] SUBACK tx pid="
e2e_assert "对端收到 QoS1 发布"      "[mock-broker] PUBLISH rx topic=demo/tx qos=1 retain=False"
e2e_assert "QoS1 载荷逐字到达对端"   "payload=hello-mock"
e2e_assert "对端收到 QoS2 发布"      "[mock-broker] PUBLISH rx topic=demo/tx qos=2 retain=False"
e2e_assert "QoS2 载荷逐字到达对端"   "payload=hello-qos2"
e2e_assert "QoS2 第一步 PUBREC 已发" "[mock-broker] PUBREC tx pid="
e2e_assert "QoS2 第二步 PUBREL 已到" "[mock-broker] PUBREL rx pid="
e2e_assert "对端回推了报文"          "[mock-broker] PUBLISH tx topic=demo/hash qos=1"
e2e_assert "客户端对回推回了 PUBACK" "[mock-broker] PUBACK rx pid="
e2e_assert "保活心跳往返"            "[mock-broker] PINGRESP tx"
e2e_assert "客户端主动断线"          "[mock-broker] DISCONNECT rx"

# 外部证据①：recent 拉到的条数要够（CONNACK/SUBACK/两条回推/心跳都在缓冲里），否则「有数据」是空话
RECENT_LINE="$(grep -F "[frontend] MQTT probe recent count=" "$E2E_LOG" | tail -1 || true)"
RECENT_N="$(printf '%s' "$RECENT_LINE" | sed -n 's/.*count=\([0-9]*\).*/\1/p')"
if [ -n "$RECENT_N" ] && [ "$RECENT_N" -ge 4 ]; then
  e2e_info "recent 拉到 $RECENT_N 条（>=4：连接应答/订阅回执/两条回推/心跳）"
else
  e2e_fail "recent 条数不足或读不出（读到「${RECENT_N:-空}」）：$RECENT_LINE"
  rc=1
fi

# 外部证据②：重连不是页面自己说的，而是对端**第二次**收到 CONNECT
CONNECT_N="$(grep -c -F "[mock-broker] CONNECT proto=MQTT level=4" "$BROKER_LOG" 2>/dev/null || true)"
if [ -n "$CONNECT_N" ] && [ "$CONNECT_N" -ge 2 ]; then
  e2e_info "对端共收到 $CONNECT_N 次 CONNECT（断开后重连成立）"
else
  e2e_fail "对端只收到 ${CONNECT_N:-0} 次 CONNECT：重连没被对端看见，见 $BROKER_LOG"
  rc=1
fi

e2e_finalize || rc=1
exit $rc
