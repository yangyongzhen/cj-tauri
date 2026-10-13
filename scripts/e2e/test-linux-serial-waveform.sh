#!/usr/bin/env bash
# e2e/test-linux-serial-waveform.sh — Linux 实机 E2E：串口实时波形示例（examples/serial-waveform）
#
# 验的是完整一跳：**页面 → 桥 → IPC → 能力校验 → serial:open/write/read → C 桥 → 内核 pty → 页面解析成波形**。
# 与 linux-bridge 的区别在「有没有真设备链路」：那条链只到命令往返，这条多了一段真实字节流
# （pty 对端按行协议吐样本），并让页面自己给出形状结论（verdict=ok），而不是只说「命令成功了」。
#
# 用法：bash scripts/e2e/test-linux-serial-waveform.sh
#   - 无 DISPLAY 时自动在 Xvfb 下重跑（lib.sh 的 e2e_ensure_display）
#   - 在非 Linux 上默认跳过；CI 里设 CJ_TAURI_E2E_REQUIRE=linux 可让「错机」变成失败
#
# 证据：dist/e2e-evidence/linux-serial-waveform.json
#   ~-rx.bin  应用写到线路上的原始字节（外部证据：SCAN 真的出了这个进程）
#   ~-peer.log 对端日志（pty 从端路径、收到 SCAN、退出原因）
set -u

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

e2e_require_platform linux
e2e_ensure_display
e2e_begin "linux-serial-waveform"

EXAMPLE="$E2E_ROOT/examples/serial-waveform"
APP="$EXAMPLE/target/release/bin/main"
PEER="$EXAMPLE/serial-wave-peer.py"
BUILD_LOG="$E2E_ROOT/dist/e2e-evidence/linux-serial-waveform.build.log"
DEV_FILE="$E2E_ROOT/dist/e2e-evidence/linux-serial-waveform.dev"
RX_FILE="$E2E_ROOT/dist/e2e-evidence/linux-serial-waveform-rx.bin"
PEER_LOG="$E2E_ROOT/dist/e2e-evidence/linux-serial-waveform-peer.log"
E2E_NOTE="pty 虚拟示波器对端 400Hz；页面自动连接→发 SCAN→收样本→自检形状（verdict=ok）后自退"

# ------------------------------------------------------------------ 1) 环境与构建
# SDK 环境**无条件**准备：应用要加载 libcjtbridge.so 与仓颉运行时（含 stdx 动态库），
# 少一个的表象是「产物在、一跑就退」，很容易被误读成构建问题。
if ! e2e_ensure_sdk; then
  e2e_fail "找不到仓颉 SDK（设 CANGJIE_HOME）：应用需要运行时库才能启动"
  exit 1
fi

# 对端要 python3：本机用它开 pty（不依赖 socat；socat 造的也是内核 pty）。
if ! command -v python3 >/dev/null 2>&1; then
  e2e_skip "缺 python3，无法开 pty 虚拟串口对端"
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

# ------------------------------------------------------------------ 2) 起虚拟示波器对端
# 对端自己开 pty、把从端路径写进 DEV_FILE；调用方据此设 CJ_SERIAL_PROBE_PATH。
: >"$DEV_FILE"; : >"$RX_FILE"; : >"$PEER_LOG"
python3 "$PEER" "$DEV_FILE" --rx-file "$RX_FILE" --hz 400 --idle-exit 25 --max-life 120 \
  >"$PEER_LOG" 2>&1 &
PEER_PID=$!

cleanup() { [ -n "${PEER_PID:-}" ] && kill "$PEER_PID" 2>/dev/null || true; }
trap cleanup EXIT

DEV_PATH=""
for _ in $(seq 1 40); do
  DEV_PATH="$(tr -d '\n' < "$DEV_FILE" 2>/dev/null || true)"
  [ -n "$DEV_PATH" ] && break
  # 对端夭折就别等了（多半是 python/termios 的问题）
  kill -0 "$PEER_PID" 2>/dev/null || break
  sleep 0.25
done
if [ -z "$DEV_PATH" ]; then
  e2e_fail "对端没给出 pty 从端路径——见 $PEER_LOG"
  tail -20 "$PEER_LOG" >&2
  exit 1
fi
e2e_info "虚拟示波器对端从端 = $DEV_PATH（hz=400）"

# ------------------------------------------------------------------ 3) 探针模式跑一轮
# 配置由宿主经 document-start 预执行脚本注入页面（窗口创建前就定稿），页面加载即自动开跑。
export CJ_SERIAL_PROBE_PATH="$DEV_PATH"
export CJ_SERIAL_PROBE_BAUD=115200
export CJ_SERIAL_PROBE_MS=3000
export CJ_SERIAL_PROBE_QUIT=1

e2e_set_cwd "$EXAMPLE"
e2e_run_app "$APP"

rc=0
# 等的是**页面自己算出来的结论行**：样本收齐、解析成波形、形状自检完成之后才打它。
# 只等「窗口出现」证明不了串口这一跳（窗口照起、串口打不开的情况会被判通过）。
if ! e2e_wait_log "[wave] DONE samples=" 60; then
  rc=1
fi
e2e_stop_app
kill "$PEER_PID" 2>/dev/null || true
PEER_PID=""
trap - EXIT

# ------------------------------------------------------------------ 4) 取证
# needle 用整行前缀或不撞词的长子串（AGENTS §4：中缀过滤器会骗人）。
e2e_assert "示例应用启动"        "[serial-waveform] main start"
e2e_assert "探针配置已注入"      "[serial-waveform] 探针模式："
e2e_assert "能力清单已加载"      "[cj-tauri] 已自动加载 capabilities/：1 个清单"
e2e_assert "串口 open（C 桥）"   "[cj-bridge] serial open: handle="
e2e_assert "SCAN 已写到线路"     "[wave] SCAN 已写出 5/5 字节"
e2e_assert "样本解析成波形"      "[wave] SHAPE"
e2e_assert "形状自检结论 ok"     "verdict=ok"
e2e_assert "采集统计收口"        "[wave] DONE samples="
e2e_assert "无丢帧（序号连续）"  "gaps=0"
e2e_assert "画布随视口尺寸"      "canvas="

# 外部证据：应用写进 pty 主端的字节就是 "SCAN\n"，落盘在 ~-rx.bin（对端写的，不是应用自己报的）
if grep -q "SCAN" "$RX_FILE" 2>/dev/null; then
  e2e_info "对端侧收到 SCAN（$RX_FILE）"
else
  e2e_fail "对端侧没收到 SCAN——页面那句「已写出」不算数，见 $RX_FILE"
  rc=1
fi

e2e_finalize || rc=1
exit $rc
