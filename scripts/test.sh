#!/usr/bin/env bash
# 单元测试入口：cjpm test（框架自身逻辑，不创建窗口，可在无 GUI 环境跑）
#
# 用法:
#   bash scripts/test.sh                 # 跑全部用例
#   bash scripts/test.sh --filter greet  # 参数透传给 cjpm test
#
# 环境变量（未设置时按常见安装路径猜；猜不到就报错退出）:
#   CANGJIE_HOME   仓颉 SDK 根目录
#   CANGJIE_STDX   stdx 动态库目录（Windows 需要；Linux 走 LD_LIBRARY_PATH）
#
# 坑：Windows 上桥的 DLL（libcjtbridge / WebView2Loader）必须在 PATH 里，
#     否则测试二进制能编译出来但一运行就 0xC0000135（DLL not found）。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

# Windows 下把 D:\a\b、D:/a/b 统一成 /d/a/b：
# 环境里继承来的 CANGJIE_HOME 常是 Windows 形式，直接拼进 PATH 会让 cjpm 变成
# 「找不到命令」(exit 127)。
to_posix() {
    local p="$1"
    if command -v cygpath >/dev/null 2>&1; then
        cygpath -u "$p"
    else
        printf '%s' "$p" | sed 's|\\|/|g; s|^\([A-Za-z]\):|/\L\1|'
    fi
}

if [ -z "${CANGJIE_HOME:-}" ]; then
    for c in "/d/Program Files (x86)/Cangjie" "/opt/cangjie/cangjie"; do
        if [ -d "$c" ]; then
            CANGJIE_HOME="$c"
            break
        fi
    done
fi
if [ -z "${CANGJIE_HOME:-}" ]; then
    echo "[test] 找不到仓颉 SDK，请设置 CANGJIE_HOME 指向 SDK 根目录" >&2
    exit 1
fi

case "$(uname -s)" in
    MINGW*|MSYS*|CYGWIN*)
        CANGJIE_HOME="$(to_posix "$CANGJIE_HOME")"
        if [ -n "${CANGJIE_STDX:-}" ]; then
            CANGJIE_STDX="$(to_posix "$CANGJIE_STDX")"
        fi
        ;;
esac

if [ ! -d "$CANGJIE_HOME" ]; then
    echo "[test] CANGJIE_HOME 不存在: $CANGJIE_HOME" >&2
    exit 1
fi
export CANGJIE_HOME

case "$(uname -s)" in
    MINGW*|MSYS*|CYGWIN*)
        export PATH="$CANGJIE_HOME/bin:$CANGJIE_HOME/tools/bin:$CANGJIE_HOME/runtime/lib/windows_x86_64_cjnative:$CANGJIE_HOME/tools/lib:$PATH"
        export PATH="$ROOT/native:$ROOT/native/webview2:$PATH"
        if [ -z "${CANGJIE_STDX:-}" ] && [ -d "/d/cangjie-stdx/windows_x86_64_cjnative/dynamic/stdx" ]; then
            CANGJIE_STDX="/d/cangjie-stdx/windows_x86_64_cjnative/dynamic/stdx"
        fi
        if [ -n "${CANGJIE_STDX:-}" ]; then
            export PATH="$CANGJIE_STDX:$PATH"
        fi
        ;;
    *)
        export PATH="$CANGJIE_HOME/bin:$CANGJIE_HOME/tools/bin:$PATH"
        STDX_PART=""
        if [ -n "${CANGJIE_STDX:-}" ]; then
            STDX_PART="$CANGJIE_STDX:"
        fi
        export LD_LIBRARY_PATH="$ROOT/native:${STDX_PART}$CANGJIE_HOME/runtime/lib/linux_x86_64_cjnative:$CANGJIE_HOME/third_party/llvm/lib:${LD_LIBRARY_PATH:-}"
        ;;
esac

echo "[test] platform=$(uname -s) CANGJIE_HOME=$CANGJIE_HOME"
# C 桥公共核心的自检先跑：它不需要 SDK / 图形栈（本机没有 C 编译器时脚本自己跳过），
# 跟 cjpm test 分开，出问题时一眼能看出是哪一层。
bash "$ROOT/scripts/test-bridge-core.sh"
exec cjpm test --no-color "$@"
