#!/usr/bin/env bash
# cj-tauri CLI 启动器（Linux / macOS / Git Bash）
#
# 首次运行会用 cjpm 自动构建 CLI 本体，随后按 SDK envsetup 的目录布局
# （运行时库 + bin + tools/bin + tools/lib）设置 PATH 并执行。
# 可用 CANGJIE_HOME 指定 SDK 根目录。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# D:\a\b 或 D:/a/b → /d/a/b
# 注意：PATH 里必须放 POSIX 形式。Git Bash 下把 "D:/..." 形式直接塞进 PATH 时，
# MSYS 的路径转换会把条目弄坏，原生进程（依赖仓颉运行时 DLL）会启动失败(127)。
win_to_unix() {
  local p="${1//\\//}"
  if [[ "$p" =~ ^([A-Za-z]):(.*)$ ]]; then
    printf '/%s%s' "$(printf '%s' "${BASH_REMATCH[1]}" | tr 'A-Z' 'a-z')" "${BASH_REMATCH[2]}"
  else
    printf '%s' "$p"
  fi
}

# CANGJIE_HOME 未设置时探测常见安装位置（issue #11-③ 同族）：SDK 装在默认路径时
# 用户环境里这个变量常是空的，跳过整块会让 runtime 库不进 LD_LIBRARY_PATH，
# CLI 同样「零输出退出」（libcangjie-runtime.so 找不到）。
if [ -z "${CANGJIE_HOME:-}" ]; then
  for d in /opt/cangjie/cangjie "$HOME/cangjie" /usr/local/cangjie; do
    if [ -x "$d/bin/cjc" ]; then
      CANGJIE_HOME="$d"
      break
    fi
  done
fi

if [ -n "${CANGJIE_HOME:-}" ]; then
  CH="$(win_to_unix "${CANGJIE_HOME}")"
  # 运行时目录必须按宿主平台挑：SDK 里 linux* 与 windows* 同时存在时，find 的返回顺序
  # 不保证，挑到另一平台的目录会变成「找不到 libcangjie-runtime.so」。
  case "$(uname -s 2>/dev/null || echo unknown)" in
    MINGW*|MSYS*|CYGWIN*) RT_GLOB='windows*' ;;
    *)                    RT_GLOB='linux*' ;;
  esac
  RT_DIR="$(find "$CH/runtime/lib" -maxdepth 1 -type d -name "$RT_GLOB" 2>/dev/null | head -1 || true)"
  PATH="${RT_DIR:+$RT_DIR:}$CH/bin:$CH/tools/bin:$CH/tools/lib:$PATH:$HOME/.cjpm/bin"
  export PATH

  # Linux/macOS 上动态库不走 PATH：CLI 本体链接 libcangjie-runtime.so，
  # 少了这个只设 PATH 的写法会让 CLI 直接「loading shared libraries」失败。
  case "$(uname -s 2>/dev/null || echo unknown)" in
    MINGW*|MSYS*|CYGWIN*) ;;
    *)
      if [ -n "${RT_DIR:-}" ]; then
        LD_LIBRARY_PATH="$RT_DIR:$CH/third_party/llvm/lib:${LD_LIBRARY_PATH:-}"
        export LD_LIBRARY_PATH
      fi
      ;;
  esac
fi

# stdx 动态库（issue #11-③）：CLI 本体按名字链 libstdx.*.so，目录不进
# LD_LIBRARY_PATH（Linux）/ PATH（Git Bash）的表象是「CLI 零输出退出」
# （loader 报 cannot open shared object file，混进 stdout 管道里根本看不出来）。
# 这段**不依赖 CANGJIE_HOME 被设置**（实测：SDK 装在默认路径时用户环境里
# CANGJIE_HOME 常是空的，放进去探测永远不执行）。CANGJIE_STDX 显式优先；
# 没设就探测 ~/.cangjie/stdx 下版本最大的那份（sort -V）。
STDX_DIR=""
if [ -n "${CANGJIE_STDX:-}" ]; then
  STDX_DIR="$(win_to_unix "$CANGJIE_STDX")"
else
  case "$(uname -s 2>/dev/null || echo unknown)" in
    MINGW*|MSYS*|CYGWIN*) STDX_DIR="$(ls -d "$HOME"/.cangjie/stdx/*/windows_x86_64_cjnative/dynamic/stdx 2>/dev/null | sort -V | tail -1 || true)" ;;
    *)                    STDX_DIR="$(ls -d "$HOME"/.cangjie/stdx/*/dynamic/stdx 2>/dev/null | sort -V | tail -1 || true)" ;;
  esac
fi
if [ -n "$STDX_DIR" ] && [ -d "$STDX_DIR" ]; then
  case "$(uname -s 2>/dev/null || echo unknown)" in
    MINGW*|MSYS*|CYGWIN*) PATH="$STDX_DIR:$PATH"; export PATH ;;
    *)                    LD_LIBRARY_PATH="$STDX_DIR:${LD_LIBRARY_PATH:-}"; export LD_LIBRARY_PATH ;;
  esac
fi

CLI_BIN="$SCRIPT_DIR/target/release/bin/main"
case "$(uname -s 2>/dev/null || echo unknown)" in
  MINGW*|MSYS*|CYGWIN*) CLI_BIN="$SCRIPT_DIR/target/release/bin/main.exe" ;;
esac

if [ ! -f "$CLI_BIN" ]; then
  echo "[cj-tauri] 首次运行：正在构建 CLI 本体（cjpm build）..."
  ( cd "$SCRIPT_DIR" && cjpm build )
fi

if [ ! -f "$CLI_BIN" ]; then
  echo "[cj-tauri] 错误: 未找到 CLI 可执行文件: $CLI_BIN" >&2
  exit 1
fi

exec "$CLI_BIN" "$@"
