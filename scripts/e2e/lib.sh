#!/usr/bin/env bash
# e2e/lib.sh — 实机 E2E 的公共层（被 scripts/e2e/test-*.sh 与 run-all.sh source）
#
# 解决三件事（都要在多个平台入口之间共用，不能各写一份）：
#   1. 平台守卫：入口声明「我必须在哪个平台上跑」。宿主不匹配时**默认报错退出 1**，
#      而不是静默跳过——「没跑」被记成「跳过」是本仓历史上最容易出假绿的地方。
#      确实要在别的机器上跑全套时，显式设 CJ_TAURI_E2E_SKIP_OTHER=1（并会打印 SKIP 行）。
#   2. 断言收集 + 证据收口：断言集中登记，收口时交给 scripts/e2e-evidence.sh 落成可对账 JSON
#      （有断言未命中断言即非零退出，证据里 summary.ok=false）。
#   3. 应用启动/收尾：切工作目录、日志重定向、轮询就绪、先子后父递归 kill——踩过的坑不再重写。
#
# 约定：调用方在 source 之后按顺序用
#   e2e_require_platform linux      # 平台守卫（声明目标平台；不匹配即失败/跳过）
#   e2e_ensure_display               # 无 DISPLAY 时自动换到 Xvfb（Linux）
#   e2e_begin "名字"                 # 设置证据名与日志路径
#   e2e_assert "断言名" "整行前缀"     # 可重复
#   e2e_run_app <命令行...>           # 启动应用（在 E2E_CWD 下，输出进证据日志）
#   e2e_wait_log "needle" 30         # 轮询等某行出现（秒）
#   e2e_stop_app                     # 收尾（先子后父）
#   e2e_finalize                     # 落证据 JSON 并返回其退出码
#
# 环境变量：
#   CJ_TAURI_E2E_REQUIRE=linux,all   本机**必须**跑的平台清单（CI 用它把错机绿灯变成失败）
#   CJ_TAURI_E2E_SKIP_OTHER=1        未在 REQUIRE 里的平台，允许跳过而不是失败
#   CJ_TAURI_E2E_HOST                覆盖宿主判定（仅用于守卫自测；别在生产脚本里设）
set -u

E2E_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
E2E_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
E2E_ENTRY="${E2E_ENTRY:-${BASH_SOURCE[1]:-}}"

E2E_NAME=""
E2E_LOG=""
E2E_CWD="$E2E_ROOT"
E2E_APP_PID=""
E2E_ASSERTS=()

e2e_info() { printf '[e2e] %s\n' "$1" >&2; }
e2e_fail() { printf '[e2e] FAIL  %s\n' "$1" >&2; }
e2e_skip() { printf '[e2e] SKIP  %s\n' "$1" >&2; }

# ------------------------------------------------------------------ 平台
# uname 只认 linux / windows(Git Bash) / macos；别发明未验证的平台标识（AGENTS §4）。
e2e_host_platform() {
  if [ -n "${CJ_TAURI_E2E_HOST:-}" ]; then
    printf '%s' "$CJ_TAURI_E2E_HOST"
    return
  fi
  case "$(uname -s)" in
    Linux)                  printf 'linux' ;;
    MINGW*|MSYS*|CYGWIN*)   printf 'windows' ;;
    Darwin)                 printf 'macos' ;;
    *)                      printf 'unknown' ;;
  esac
}

# e2e_require_platform <平台>... —— 入口的第一个实质动作。
# 宿主在声明里            → 返回 0，继续跑；
# 宿主不在、但它在 REQUIRE 里 → 失败（这就是「错机绿灯」的堵口）；
# 宿主不在、也没被要求    → SKIP 并 exit 0（除非设了 SKIP_OTHER=0 想强制失败）。
e2e_require_platform() {
  local host want
  host="$(e2e_host_platform)"
  for want in "$@"; do
    if [ "$want" = "$host" ]; then
      e2e_info "平台守卫：目标 $want == 宿主 $host，开始验证"
      return 0
    fi
  done
  local require_raw="${CJ_TAURI_E2E_REQUIRE:-}"
  local req
  for req in ${require_raw//,/ }; do
    if [ "$req" = "all" ] || [ "$req" = "$host" ]; then
      e2e_fail "平台守卫：本机 $host 被声明为必须运行，但本测试的目标平台是 [$*]——拒绝在错误的机器上通过"
      exit 1
    fi
  done
  if [ "${CJ_TAURI_E2E_SKIP_OTHER:-1}" = "0" ]; then
    e2e_fail "平台守卫：本机 $host 不是目标平台 [$*]，且 CJ_TAURI_E2E_SKIP_OTHER=0"
    exit 1
  fi
  e2e_skip "平台守卫：本机 $host 不是目标平台 [$*]（未列入 CJ_TAURI_E2E_REQUIRE，跳过）"
  exit 0
}

# ------------------------------------------------------------------ 显示（Linux）
# DISPLAY 存在 ≠ 显示器可用：SSH 转发失效时变量还在（本机实测 localhost:15.0 连不上），
# 只看变量非空会让应用死在 `cannot open display`，而 E2E 还把那次失败记成「窗口起不来」。
# 所以真去连一下；xdpyinfo / xdotool / xset 谁在就用谁，都没有就当作不可用。
_e2e_display_ok() {
  [ -n "${DISPLAY:-}" ] || return 1
  if command -v xdpyinfo >/dev/null 2>&1; then
    xdpyinfo >/dev/null 2>&1 && return 0
  fi
  if command -v xdotool >/dev/null 2>&1; then
    xdotool getdisplaygeometry >/dev/null 2>&1 && return 0
  fi
  if command -v xset >/dev/null 2>&1; then
    xset q >/dev/null 2>&1 && return 0
  fi
  return 1
}

# 本机 X11 转发常失效，无可用显示器时统一走 Xvfb；已在 Xvfb 内则不再套一层。
e2e_ensure_display() {
  if _e2e_display_ok; then return 0; fi
  [ -n "${CJ_TAURI_E2E_IN_XVFB:-}" ] && return 0
  if [ -n "${DISPLAY:-}" ]; then
    e2e_info "DISPLAY=$DISPLAY 连不上（探测失败），改用 Xvfb"
  fi
  if ! command -v xvfb-run >/dev/null 2>&1; then
    e2e_skip "无可用显示器且没有 xvfb-run（跳过窗口验证）"
    exit 0
  fi
  [ -n "$E2E_ENTRY" ] || { e2e_fail "e2e_ensure_display 需要在入口脚本里 source lib.sh"; exit 1; }
  export CJ_TAURI_E2E_IN_XVFB=1
  e2e_info "改在 Xvfb 下重跑 $E2E_ENTRY"
  # env -u DISPLAY：把那个连不上的 DISPLAY 摘掉，避免 xvfb-run 之外的子进程再去连它。
  exec env -u DISPLAY xvfb-run -a --server-args="-screen 0 1280x800x24" bash "$E2E_ENTRY" "$@"
}

# ------------------------------------------------------------------ SDK
# 与 scripts/test.sh 同一套探测：cjc 与 cjpm 分属 bin/ 与 tools/bin，运行时库走 LD_LIBRARY_PATH。
# 缺 SDK 时返回 1 而不是退出——调用方决定这是「跳过」还是「失败」。
e2e_ensure_sdk() {
  if [ -z "${CANGJIE_HOME:-}" ]; then
    local c
    for c in "/opt/cangjie/cangjie" "/d/Program Files (x86)/Cangjie"; do
      if [ -d "$c" ]; then CANGJIE_HOME="$c"; break; fi
    done
  fi
  [ -n "${CANGJIE_HOME:-}" ] && [ -d "$CANGJIE_HOME" ] || return 1
  export CANGJIE_HOME
  export PATH="$CANGJIE_HOME/bin:$CANGJIE_HOME/tools/bin:$PATH"
  case "$(e2e_host_platform)" in
    linux)
      # stdx 的动态库**不在 SDK 目录里**，而仓颉运行时只认 LD_LIBRARY_PATH（不查 PATH）：
      # 少它一条的表象是「应用启动即退、stderr 只有一行
      # cannot open shared object file: libstdx.encoding.json.so」，很容易被读成构建问题。
      if [ -z "${CANGJIE_STDX:-}" ]; then
        local d
        for d in "$HOME"/.cangjie/stdx/*/dynamic/stdx; do
          if [ -d "$d" ]; then CANGJIE_STDX="$d"; break; fi
        done
      fi
      export LD_LIBRARY_PATH="$E2E_ROOT/native:${CANGJIE_STDX:+$CANGJIE_STDX:}${CANGJIE_HOME}/runtime/lib/linux_x86_64_cjnative:${CANGJIE_HOME}/third_party/llvm/lib:${LD_LIBRARY_PATH:-}"
      ;;
    windows)
      export PATH="$E2E_ROOT/native:$E2E_ROOT/native/webview2:$CANGJIE_HOME/runtime/lib/windows_x86_64_cjnative:$PATH"
      # CANGJIE_STDX 常被设成盘符形式（D:/...，cjpm.toml 的 path-option 就是这个写法）：
      # 但 PATH 里的盘符形式条目会破坏 MSYS 的路径转换，依赖运行时 DLL 的原生进程
      # 轻则找不到 libcjtbridge.dll、重则 127 无输出（AGENTS §4）——进 PATH 前统一转 POSIX。
      if [ -n "${CANGJIE_STDX:-}" ]; then
        local stdx_path="$CANGJIE_STDX"
        command -v cygpath >/dev/null 2>&1 && stdx_path="$(cygpath -u "$CANGJIE_STDX")"
        export PATH="$stdx_path:$PATH"
      fi
      ;;
  esac
  return 0
}

# ------------------------------------------------------------------ 证据
e2e_begin() {
  E2E_NAME="$1"
  local plat; plat="$(e2e_host_platform)"
  E2E_LOG="$E2E_ROOT/dist/e2e-evidence/${plat}-${E2E_NAME}.log"
  mkdir -p "$(dirname "$E2E_LOG")"
  : > "$E2E_LOG"
  E2E_ASSERTS=()
  e2e_info "证据名=$E2E_NAME 日志=$E2E_LOG"
}

# e2e_assert <断言名> <needle>：needle 用**整行前缀**（如 `[cj-bridge]`）或任意子串，
# 别名用「撞词的中缀」会被正文骗过（AGENTS §4 有实例）。
e2e_assert() { E2E_ASSERTS+=("$1"$'\t'"$2"); }

# 落证据：断言交给 scripts/e2e-evidence.sh（同一份格式，证据自己也要过 check-static）。
e2e_finalize() {
  [ -n "$E2E_NAME" ] || { e2e_fail "e2e_finalize 前要先 e2e_begin"; return 1; }
  local args=(--name "$E2E_NAME" --log "$E2E_LOG")
  local a
  for a in "${E2E_ASSERTS[@]}"; do
    args+=(--assert "${a%%$'\t'*}:${a#*$'\t'}")
  done
  [ "${E2E_NOTE:-}" != "" ] && args+=(--note "$E2E_NOTE")
  [ "${E2E_ALLOW_MISSING:-0}" = "1" ] && args+=(--allow-missing)
  bash "$E2E_ROOT/scripts/e2e-evidence.sh" "${args[@]}"
}

# ------------------------------------------------------------------ 应用
# 应用按**相对路径**读 capabilities/ 与 ui/，所以必须切到它的工程根再启动。
e2e_set_cwd() { E2E_CWD="$1"; }

e2e_run_app() {
  # Windows：WebView2 的用户数据目录默认在 exe 旁边，两个实例先后运行会撞
  # `create WebView2 controller failed: 0x800700aa`（目录被上一个残留实例占用）。
  # WebView2 认 WEBVIEW2_USER_DATA_FOLDER 环境变量——每轮给一个独立目录，运行之间互不锁。
  if [ "$(e2e_host_platform)" = "windows" ]; then
    export WEBVIEW2_USER_DATA_FOLDER="$E2E_ROOT/dist/e2e-evidence/.webview2-$E2E_NAME-$$"
  fi
  ( cd "$E2E_CWD" && exec "$@" ) >>"$E2E_LOG" 2>&1 &
  E2E_APP_PID=$!
  e2e_info "应用已启动 pid=$E2E_APP_PID cwd=$E2E_CWD cmd=$*"
}

# 轮询日志等某行出现（秒）。等窗口别用固定 sleep：首次运行可能还在编译/初始化。
e2e_wait_log() {
  local needle="$1" timeout="${2:-30}" i=0
  while [ "$i" -lt "$((timeout * 4))" ]; do
    if grep -q -F -- "$needle" "$E2E_LOG" 2>/dev/null; then
      e2e_info "就绪：日志已出现「$needle」"
      return 0
    fi
    if [ -n "$E2E_APP_PID" ] && ! kill -0 "$E2E_APP_PID" 2>/dev/null; then
      e2e_fail "等待「$needle」期间应用已退出（pid=$E2E_APP_PID）"
      return 1
    fi
    sleep 0.25
    i=$((i + 1))
  done
  e2e_fail "等「$needle」超时（${timeout}s）"
  return 1
}

# 先子后父递归 kill：应用会起宿主线程/子进程，只杀父会留下继续写同一份日志的残留实例。
# Windows 的关键差异：pgrep -P 看不见原生进程（AGENTS §4），WebView2 的 msedgewebview2.exe
# 收不干净，下一个实例就撞 0x800700aa——所以 Windows 用 taskkill /T 按整棵树杀：
# 先用 ps -W 把 MSYS pid 映射成 Windows pid，再交给 taskkill 递归。
e2e_kill_tree() {
  local pid="$1" child winpid
  if [ "$(e2e_host_platform)" = "windows" ] && command -v taskkill >/dev/null 2>&1; then
    winpid="$(ps -W 2>/dev/null | awk -v m="$pid" '$1 == m { print $4; exit }')"
    if [ -n "$winpid" ]; then
      taskkill //F //T //PID "$winpid" >/dev/null 2>&1 && return 0
    fi
  fi
  for child in $(pgrep -P "$pid" 2>/dev/null || true); do
    e2e_kill_tree "$child"
  done
  kill "$pid" 2>/dev/null || true
}

e2e_stop_app() {
  [ -n "$E2E_APP_PID" ] || return 0
  e2e_kill_tree "$E2E_APP_PID"
  local i=0
  while kill -0 "$E2E_APP_PID" 2>/dev/null && [ "$i" -lt 40 ]; do
    sleep 0.25
    i=$((i + 1))
  done
  kill -0 "$E2E_APP_PID" 2>/dev/null && kill -9 "$E2E_APP_PID" 2>/dev/null || true
  e2e_info "应用已收尾 pid=$E2E_APP_PID"
  E2E_APP_PID=""
}
