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
