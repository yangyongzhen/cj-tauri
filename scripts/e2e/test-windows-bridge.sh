#!/usr/bin/env bash
# e2e/test-windows-bridge.sh — Windows 实机 E2E：真实 WebView2 窗口 + 双向桥 + 能力拒绝
#
# 用法：bash scripts/e2e/test-windows-bridge.sh
#   - 在非 Windows 上默认跳过；CI/取证时设 CJ_TAURI_E2E_REQUIRE=windows 可让「错机」变成失败
#
# 证据：dist/e2e-evidence/windows-windows-bridge.json（断言命中次数、运行时版本、UTC 时间）
# 驱动的是 scripts/e2e/fixture-app（探针应用），页面在 ui/index.html，改页面不用重编译仓颉。
# 与 test-linux-bridge.sh 同构（同一探针、同一断言集）：平台差异只落在
# 产物名（main.exe）与「不需要 Xvfb」这两处——判据两侧同源，跨平台可比。
set -u

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

e2e_require_platform windows
e2e_begin "windows-bridge"

FIXTURE="$E2E_LIB_DIR/fixture-app"
APP="$FIXTURE/target/release/bin/main.exe"
BUILD_LOG="$E2E_ROOT/dist/e2e-evidence/windows-bridge.build.log"
E2E_NOTE="探针页：system:version / system:ping / 未授权 system:devtools；窗口 900x640"

# ------------------------------------------------------------------ 1) 构建探针应用
# SDK 环境**无条件**准备：不只是为了构建——应用启动要加载 libcjtbridge.dll、
# WebView2Loader.dll 与仓颉运行时（lib.sh 的 windows 分支已把这些目录都塞进 PATH），
# 少一个就是「产物在、一跑就退」（且报错往往只有一行 127）。这里失败要硬失败，不许当跳过。
if ! e2e_ensure_sdk; then
  e2e_fail "找不到仓颉 SDK（设 CANGJIE_HOME）：应用需要运行时库才能启动"
  exit 1
fi

# 产物不存在才构建：E2E 的价值在「跑起来」，构建只是前置（构建日志单独落盘，
# 别混进证据日志——断言按整行前缀 grep，构建输出会污染计数）。
# 注意本机坑：改过框架/示例后必须重建，否则跑的是旧产物——这里按「源码比产物新就重建」守一道。
STALE=0
if [ -x "$APP" ]; then
  NEWEST_SRC="$(cd "$FIXTURE" && ls -t src/*.cj cjpm.toml 2>/dev/null | head -1)"
  if [ -n "$NEWEST_SRC" ] && [ "$NEWEST_SRC" -nt "$APP" ]; then STALE=1; fi
fi
if [ ! -x "$APP" ] || [ "$STALE" = "1" ]; then
  [ "$STALE" = "1" ] && e2e_info "探针产物比源码旧，重建（防跑旧产物）"
  e2e_info "探针应用未构建，先 cjpm build（日志 $BUILD_LOG）"
  if ! ( cd "$FIXTURE" && cjpm build ) >"$BUILD_LOG" 2>&1; then
    e2e_fail "探针应用构建失败，见 $BUILD_LOG"
    tail -20 "$BUILD_LOG" >&2
    exit 1
  fi
  e2e_info "探针应用构建完成"
fi

# ------------------------------------------------------------------ 2) 跑到闭环
e2e_set_cwd "$FIXTURE"
e2e_run_app "$APP"

rc=0
# 等的那一行是**端到端闭环**本身：页面三条命令都回齐后整体回投给 probe:echo，
# 仓颉侧才打它。比等「窗口出现」强——窗口起来但桥不通的情况不会被判通过。
if ! e2e_wait_log "[e2e] probe:echo 收到:" 60; then
  rc=1
fi
e2e_stop_app

# ------------------------------------------------------------------ 3) 取证
# needle 一律用整行前缀或不会撞词的长子串（AGENTS §4：中缀过滤器会骗人）。
e2e_assert "探针应用启动"      "[e2e] fixture-app start"
e2e_assert "能力清单已加载"    "[cj-tauri] 已自动加载 capabilities/：1 个清单"
e2e_assert "桥脚本已注入"      "[cj-bridge] init scripts injected: "
e2e_assert "页面→宿主 IPC"     "[cj-bridge] js -> native ("
e2e_assert "端到端往返闭环"    "[e2e] probe:echo 收到:"
e2e_assert "未授权命令被拒"    "DENY-OK devtools"
# Windows 能力位的实机面：探针页经 system:host 读回并回投——真实现置位、桩如实报 0 是这条的判据。
e2e_assert "能力位如实上报"    "host=windows menu=true tray=false dragDrop=true"
# 拖放（Windows 真实现）：OLE IDropTarget 已挂载（关 WebView2 自带拖放后枚举子窗口覆盖注册）。
e2e_assert "拖放目标已挂载"    "[cj-bridge] drag dest attached (CF_HDROP)"
# 剪贴板（Windows 真实现）：写读回环值一致。
e2e_assert "剪贴板写读回环"    "clipboard roundtrip=OK"
# 通知（Windows toast 真实现）：PowerShell 投递成功即回成功；桥侧另有 "-> sent" 行可对照。
e2e_assert "通知 toast 已投递"  "notification SENT-OK"
# 串口（Windows 真实现）：QueryDosDeviceW 枚举链路通（有几个端口都行，0 也算通）。
e2e_assert "串口枚举链路"      "serial:list ports="

e2e_finalize || rc=1
exit $rc
