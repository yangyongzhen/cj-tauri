#!/usr/bin/env bash
# e2e/test-linux-clipboard-history.sh — Linux 实机 E2E：剪贴板历史管理器（examples/clipboard-history）
#
# 验的是框架两个新能力位的首跳 + 历史链路闭环：
#   托盘       —— appindicator 真建出图标（对端用 xclip 扮演剪贴板；托盘点击经 shell 通道回投）
#   全局快捷键 —— X11 grab 注册成功（hotkey grab 日志行）
#   历史链路   —— 页面经 clipboard:read 轮询捕获 xclip 写入 → 去重入史 → 点击回写 clipboard:write
#                 → **外部回读**（xclip -o，读回来的是应用写的才算数，页面自证不算）
#
# 双侧对账：页面侧每条断言经 report 回投成 [frontend] 行；托盘/快捷键/能力位在桥 stderr 留痕
# （hotkey grab / tray applied / hotkey=true），「能力位如实」由 system:host 的返回值断言。
#
# 用法：bash scripts/e2e/test-linux-clipboard-history.sh
#   - 无 DISPLAY 时自动在 Xvfb 下重跑（lib.sh 的 e2e_ensure_display）
#   - 非 Linux 默认跳过；CI 设 CJ_TAURI_E2E_REQUIRE=linux 让「错机」变失败
#
# 证据：dist/e2e-evidence/linux-clipboard-history.json（+ 同名 .log）
set -u

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

e2e_require_platform linux
e2e_ensure_display
e2e_begin "clipboard-history"

EXAMPLE="$E2E_ROOT/examples/clipboard-history"
APP="$EXAMPLE/target/release/bin/main"
BUILD_LOG="$E2E_ROOT/dist/e2e-evidence/linux-clipboard-history.build.log"
E2E_NOTE="xclip 扮演剪贴板：写入→轮询捕获→点击回写→xclip 外部回读；托盘/快捷键/能力位桥侧留痕"

# ------------------------------------------------------------------ 1) 环境与前置
if ! e2e_ensure_sdk; then
  e2e_fail "找不到仓颉 SDK（设 CANGJIE_HOME）：应用需要运行时库才能启动"
  exit 1
fi

if ! command -v xclip >/dev/null 2>&1; then
  e2e_fail "缺 xclip（apt install xclip）：本 E2E 用它扮演剪贴板对端"
  exit 1
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

# 上轮残留的剪贴板探针内容清掉：本轮「捕获了什么」才有确定性（基线行不包含 probe 字样才可信）
printf 'e2e-baseline-%s\n' "$$" | xclip -selection clipboard -i 2>/dev/null || true
sleep 0.3

# ------------------------------------------------------------------ 2) 探针模式跑一轮
# CJ_CLIP_PROBE_QUIT=0：页面探针跑完不退出——脚本要在它活着的时候做「外部回读」与快捷键取证。
export CJ_CLIP_PROBE=1
export CJ_CLIP_PROBE_QUIT=0
e2e_set_cwd "$EXAMPLE"
e2e_run_app "$APP"

rc=0
if ! e2e_wait_log "[selfcheck] 3/3 passed" 60; then
  rc=1
fi

# 探针收尾后再走一步外部对账：xclip 回读应用最后一次写入的内容
# （探针的 write-back 写的是历史首条 = 第二枪负载 clip-probe2-…；读回来一致才算闭环）
sleep 1
ext_read="$(xclip -selection clipboard -o 2>/dev/null | head -c 200 || true)"
e2e_stop_app

# ------------------------------------------------------------------ 3) 取证（断言名不带冒号与反引号）
e2e_assert "示例应用启动"            "[cj-clip] main start"
e2e_assert "能力清单已加载"          "[cj-tauri] 已自动加载 capabilities/"
e2e_assert "托盘线路已送达桥"        "[cj-bridge] set tray:"
e2e_assert "托盘真建出来"            "[cj-bridge] tray applied"
e2e_assert "快捷键线路已送达桥"      "[cj-bridge] set global hotkeys:"
e2e_assert "X11 grab 注册成功"       "[cj-bridge] hotkey grab: Ctrl+Alt+V"
e2e_assert "页面已载入"              "[cj-clip] 前端页面已载入"
# 基线内容是竞态的（探针基线枪若先于首拍轮询落板，基线就是 clip-probe-…——两种先后都合法），
# 断言只锚「基线已建立」这个事实，内容不锚。
e2e_assert "轮询基线已建立"          "[frontend] [clip] baseline:"
e2e_assert "探针基线枪写入"          "[frontend] [selfcheck] baseline-write: PASS clip-probe-"
e2e_assert "探针负载枪写入"          "[frontend] [selfcheck] write: PASS clip-probe2-"
e2e_assert "轮询捕获到外部写入"      "[frontend] [selfcheck] capture: PASS"
e2e_assert "点击回写成功"            "[frontend] [selfcheck] write-back: PASS clip-probe2-"
e2e_assert "页面自检聚合行"          "[frontend] [selfcheck] 3/3 passed"
e2e_assert "能力位如实上报快捷键"    '[clip] host caps: {"platform":"linux","menu":true,"tray":true,"dragDrop":true,"hotkey":true}'
e2e_assert "能力位如实上报托盘"      '[clip] host caps: {"platform":"linux","menu":true,"tray":true'

# 外部回读对账：应用写进剪贴板的（探针 write-back = clip-probe2-…），xclip 读回来必须一致
if printf '%s' "$ext_read" | grep -aq "clip-probe2-"; then
  e2e_info "外部回读一致（xclip -o = 应用写入的 clip-probe2-…）"
else
  e2e_fail "外部回读不一致——xclip -o 拿到「$ext_read」，期望包含 clip-probe2-（回写没真落到系统剪贴板？）"
  rc=1
fi

# 反面：不许有 FAIL 行（聚合行只代表 DONE 那一刻，明细红了必须抓出来）
if grep -aq "selfcheck] .*: FAIL\|write-back FAILED\|capture: FAIL" "$E2E_LOG" 2>/dev/null; then
  e2e_fail "页面自检出现 FAIL："
  grep -aE "selfcheck\].*FAIL" "$E2E_LOG" | tail -8 >&2
  rc=1
fi

# 托盘/快捷键没起来必须红：能力位 true 与实际组件至少要有一边落空就说明「报喜不报忧」
if ! grep -aq "tray applied" "$E2E_LOG" 2>/dev/null; then
  e2e_fail "托盘没建出来（tray applied 缺失）——Xvfb 下无通知守护进程？查 libayatana 运行环境"
  rc=1
fi
if ! grep -aq "hotkey grab:" "$E2E_LOG" 2>/dev/null; then
  e2e_fail "快捷键没注册上（hotkey grab 缺失）——查 X11 dev 与 grab 线程日志"
  rc=1
fi

e2e_finalize || rc=1
exit $rc
