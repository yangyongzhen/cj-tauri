#!/usr/bin/env bash
# 单文件打包（Windows x64）：把一个示例打成**一个 exe**——没有 DLL、没有 ui/、没有 capabilities/。
#
# 用法:
#   bash scripts/pack-win-single.sh                        # 打包 examples/typing-poem
#   bash scripts/pack-win-single.sh examples/music          # 指定示例
#   bash scripts/pack-win-single.sh examples/music /tmp/out
#
# 示例要接进来的三件套（缺一不可，本脚本会逐条 die 说明）：
#   · `src/packed_assets.cj`：`public let PACKED_*_B64: String = ""` 空存根——**声明了哪几个，
#     本脚本就生成哪几个**（typing-poem 多一个 three.js，examples/music 没有），
#     仓库内正常构建仍按相对路径读盘；
#   · `src/packed_resources.cj`：`decodeBase64` / `splitBy` / `textOrFile`（内嵌优先、否则读盘）；
#   · `capabilities/` 下至少一份 json：单文件产物没有随行清单，必须编进二进制，否则命令全被拒。
#
# 与 scripts/pack-win.sh（目录 + zip 的便携包）的分工：
#   pack-win.sh        动态链接，交付一个**目录**（exe + 十来个 DLL + ui/ + capabilities/ + run.bat）；
#   pack-win-single.sh 静态链接，交付**一个文件**，双击即玩、可以单独发出去。
#
# 单文件靠四件事凑齐，缺一件就会在运行时缺文件（详见 docs/使用文档.md 的「单文件打包」一节）：
#   ① 仓颉运行时 / std / stdx 静态链接：`--static --static-std --static-libs` + stdx 的 **static** 包；
#   ② C 桥编成静态归档 libcjtbridge.a 直接链进 exe（不再有 libcjtbridge.dll）；
#   ③ WebView2Loader.dll **没法**静态链——MSVC 编的 WebView2LoaderStatic.lib 要 /GS 的
#      __security_cookie 与 C++ 运行时符号，mingw 接不住（2026-10-07 实测 `ld.lld: undefined
#      symbol: __security_cookie`）。于是把它的字节编进桥（-DCJ_EMBED_WEBVIEW2_LOADER），
#      首次运行时释放到 %TEMP%\cj-tauri-loader\ 再按绝对路径加载（幂等，见 native/bridge_win.c）；
#   ④ 页面 / three.js（只有用它的示例）/ 能力清单由本脚本生成 src/packed_assets.cj（base64），编进二进制。
#
# 产物：<示例>/dist-single/<示例名>.exe（实测 typing-poem：28.8 MB → strip 后 5.5 MB；
#       这份 exe 随仓库分发，work/ 临时副本与 *.WebView2/ 用户数据不入库）
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

die() { echo "[pack-single] $*" >&2; exit 1; }

case "$(uname -s)" in
    MINGW*|MSYS*|CYGWIN*) ;;
    *) die "本脚本只做 Windows 单文件包（Linux 用系统 WebKitGTK，不需要这种打包）" ;;
esac

# Windows 下把 D:\a\b、D:/a/b 统一成 /d/a/b（PATH 里混进盘符形式会让原生进程 exit 127）
to_posix() {
    local p="$1"
    if command -v cygpath >/dev/null 2>&1; then
        cygpath -u "$p"
    else
        printf '%s' "$p" | sed 's|\\|/|g; s|^\([A-Za-z]\):|/\L\1|'
    fi
}

# 反过来：写进 cjpm.toml 的路径要给 cjpm/gcc 这些原生程序看，必须是盘符形式。
# 路径一律用**正斜杠**（D:/cangjie-stdx/...）：TOML 基本字符串里 `\c` 是非法转义
# （实测 errLexEscape → cjpm build failed），写反斜杠就得再叠一层转义，正斜杠两边都认。
to_win()     { printf '%s' "$1" | sed -e 's|^/\([A-Za-z]\)/|\U\1:/|'; }

EXAMPLE="${1:-$ROOT/examples/typing-poem}"
[ -d "$EXAMPLE" ] || die "示例不存在: $EXAMPLE"
EXAMPLE="$(cd "$EXAMPLE" && pwd)"   # 取绝对路径：构建副本要 cd 进去跑，相对路径会飘
OUT_ROOT="${2:-$EXAMPLE/dist-single}"
NAME="$(basename "$EXAMPLE")"
EXE="$OUT_ROOT/$NAME.exe"

# ---------- 环境 ----------
if [ -z "${CANGJIE_HOME:-}" ]; then
    for c in "/d/Program Files (x86)/Cangjie" "/opt/cangjie/cangjie"; do
        [ -d "$c" ] && { CANGJIE_HOME="$c"; break; }
    done
fi
[ -n "${CANGJIE_HOME:-}" ] || die "找不到仓颉 SDK，请设置 CANGJIE_HOME"
CANGJIE_HOME="$(to_posix "$CANGJIE_HOME")"
SDK_LIB="$CANGJIE_HOME/runtime/lib/windows_x86_64_cjnative"

# stdx 必须用 **static** 包：dynamic 包只有 .dll，静态链接的 exe 需要 .a（两个包 .cjo 数量一致）
STDX_ROOT="${CANGJIE_STDX_ROOT:-/d/cangjie-stdx/windows_x86_64_cjnative}"
STDX_ROOT="$(to_posix "$STDX_ROOT")"
STDX_STATIC="$STDX_ROOT/static/stdx"
[ -d "$STDX_STATIC" ] || die "缺 stdx 静态包: $STDX_STATIC（设 CANGJIE_STDX_ROOT 指向解压目录）"

WEBVIEW2_SDK_ROOT="${WEBVIEW2_SDK_ROOT:-D:\\webview2sdk\\sdk-1.0.2365.46}"
WEBVIEW2_SDK_ROOT="$(to_posix "$WEBVIEW2_SDK_ROOT")"
WEBVIEW2_INCLUDE="$WEBVIEW2_SDK_ROOT/build/native/include"
[ -f "$WEBVIEW2_INCLUDE/WebView2.h" ] || die "缺 WebView2 头文件: $WEBVIEW2_INCLUDE/WebView2.h"

NATIVE="$ROOT/native"
[ -f "$NATIVE/bridge_win.c" ] || die "缺 C 桥源码: $NATIVE/bridge_win.c"
[ -f "$NATIVE/webview2/WebView2Loader.dll" ] || die "缺 native/webview2/WebView2Loader.dll（先跑 native\\build_win.bat）"
[ -d "$EXAMPLE/src" ] || die "示例不存在或没有 src/: $EXAMPLE"

for t in gcc ar objdump base64 strip; do
    command -v "$t" >/dev/null 2>&1 || die "缺工具 $t（gcc/ar/strip 来自 mingw-w64，base64 来自 Git Bash coreutils）"
done

WORK="$OUT_ROOT/work"
rm -rf "$WORK" "$EXE"
mkdir -p "$WORK/bridge" "$WORK/app" "$OUT_ROOT"

# ---------- ① 静态桥：编 libcjtbridge.a，并把 WebView2Loader.dll 的字节编进去 ----------
LOADER_DLL="$NATIVE/webview2/WebView2Loader.dll"
LOADER_BYTES="$(stat -c%s "$LOADER_DLL")"
echo "[pack-single] 内嵌 WebView2Loader.dll（$LOADER_BYTES 字节）"
{
    printf '#define CJ_WV2_LOADER_SIZE %su\n' "$LOADER_BYTES"
    printf 'static const unsigned char CJ_WV2_LOADER_BYTES[CJ_WV2_LOADER_SIZE] = {\n'
    od -An -v -tu1 "$LOADER_DLL" | awk '{for (i = 1; i <= NF; i++) printf "0x%02x,", $i; printf "\n"}'
    printf '};\n'
} > "$WORK/bridge/webview2_loader_embed.h"

echo "[pack-single] 编译静态桥 libcjtbridge.a"
( cd "$WORK/bridge" && gcc -c -O2 -fstack-protector-all -DCJ_EMBED_WEBVIEW2_LOADER \
    -I"$WORK/bridge" -I"$WEBVIEW2_INCLUDE" \
    "$NATIVE/bridge_core.c" "$NATIVE/bridge_win.c" && \
    ar rcs libcjtbridge.a bridge_core.o bridge_win.o )
BRIDGE_LIB="$WORK/bridge/libcjtbridge.a"
[ -f "$BRIDGE_LIB" ] || die "静态桥编译失败"

# ---------- ② 构建副本：拷示例 + 生成内嵌资源 ----------
[ -d "$EXAMPLE/ui" ] || die "示例缺 ui/: $EXAMPLE/ui"
[ -d "$EXAMPLE/capabilities" ] || die "示例缺 capabilities/: $EXAMPLE/capabilities"
cp -r "$EXAMPLE/src" "$WORK/app/"
cp -r "$EXAMPLE/ui" "$WORK/app/"

# 包名从示例的 cjpm.toml 抄（仓颉按包名找模块，生成的 packed_assets.cj 必须与源码同包）
PKG_NAME="$(awk -F'"' '/^[[:space:]]*name[[:space:]]*=/ {print $2; exit}' "$EXAMPLE/cjpm.toml")"
[ -n "$PKG_NAME" ] || die "读不到 $EXAMPLE/cjpm.toml 的 package.name"

# 内嵌哪几个常量以示例的存根为准：存根里 `public let PACKED_*_B64: String = ""` 的一行
# 就是「这个示例要内嵌它」——examples/music 没有 three.js，生成时就不写那一条。
ASSET_STUB="$EXAMPLE/src/packed_assets.cj"
[ -f "$ASSET_STUB" ] || die "示例还没接内嵌资源：缺 $ASSET_STUB（空存根 + 取用函数，见 examples/music/src/packed_resources.cj）"
has_asset() { grep -q "^public let $1" "$ASSET_STUB"; }
has_asset PACKED_UI_B64 || die "$ASSET_STUB 里没有 PACKED_UI_B64 存根"

b64() { base64 -w0 "$1" 2>/dev/null || base64 "$1" | tr -d '\n'; }

# 页面必填；three.js 只有用它的示例才有
UI_FILE="$WORK/app/ui/index.html"
[ -f "$UI_FILE" ] || die "示例缺前端页面: $UI_FILE"
UI_B64="$(b64 "$UI_FILE")"
THREE_B64=""
if has_asset PACKED_THREE_B64; then
    THREE_FILE="$WORK/app/ui/vendor/three.min.js"
    [ -f "$THREE_FILE" ] || die "存根声明了 PACKED_THREE_B64，但缺 $THREE_FILE"
    THREE_B64="$(b64 "$THREE_FILE")"
fi

# 能力清单：每个 capabilities/*.json 各自 base64，再用 "," 拼起来
# （base64 字符表里没有逗号，所以逗号是安全的分隔符；应用侧按逗号切开逐个挂载）
CAPS_B64=""
CAPS_N=0
for f in "$EXAMPLE"/capabilities/*.json; do
    [ -f "$f" ] || continue
    piece="$(b64 "$f")"
    if [ -z "$CAPS_B64" ]; then CAPS_B64="$piece"; else CAPS_B64="$CAPS_B64,$piece"; fi
    CAPS_N=$((CAPS_N + 1))
done
[ "$CAPS_N" -ge 1 ] || die "capabilities/ 下没有 json：单文件包必须把清单编进去，否则命令全被拒"

echo "[pack-single] 生成内嵌资源：页面 ${#UI_B64} / three.js ${#THREE_B64} base64 字节，能力清单 $CAPS_N 份"
{
    printf 'package %s\n\n' "$PKG_NAME"
    printf '/* 由 scripts/pack-win-single.sh 生成：内嵌资源（标准 base64，无换行）。**不要手工编辑**。\n'
    printf '   常量非空即「内嵌模式」；仓库里的同名文件是空存根，正常构建仍按相对路径读盘。 */\n'
    printf 'public let PACKED_UI_B64: String = "%s"\n' "$UI_B64"
    if has_asset PACKED_THREE_B64; then
        printf 'public let PACKED_THREE_B64: String = "%s"\n' "$THREE_B64"
    fi
    printf 'public let PACKED_CAPS_B64: String = "%s"\n' "$CAPS_B64"
} > "$WORK/app/src/packed_assets.cj"

# ---------- ③ cjpm.toml：静态链接三件套 + 静态桥 ----------
# 包名上面已经从示例抄好（PKG_NAME），这里只负责写构建配置。

# cjpm.toml 里出现的路径都要盘符形式（cjpm 与它拉起的 gcc 都是原生 Windows 程序，
# 看到 /d/... 会当成「当前盘根目录下的 d 目录」）
DEP_PATH="$(to_win "$ROOT")"
BRIDGE_ARG="$(to_win "$BRIDGE_LIB")"
STDX_PATH="$(to_win "$STDX_STATIC")"

cat > "$WORK/app/cjpm.toml" <<TOML
[package]
  cjc-version = "1.0.5"
  name = "$PKG_NAME"
  version = "0.1.0"
  output-type = "executable"
  compile-option = "--static --static-std --static-libs"

[dependencies]
  cjTauri = { path = "$DEP_PATH" }

[target.x86_64-w64-mingw32]
  # `-lcrypt32`：stdx.net.tls 的根证书读取走 Windows 证书库（CertOpenSystemStoreA /
  # CertEnumCertificatesInStore / CertCloseStore 都在 crypt32.dll），静态链接的示例只要碰
  # https 就得链上它，否则 ld.lld 在链接期报一串 undefined symbol（examples/music 实测：
  # 它的封面走 https，而 typing-poem 不用 TLS，所以这条直到打音乐示例才暴露）。
  # 用不到的示例多链一个系统库无副作用（import 表里不会出现，见脚本末尾的自检）。
  # `--subsystem=windows`：产物按 GUI 子系统链接（PE Subsystem=2，脚本末尾有事后悔核）。
  # 缺了它 Windows 就按 console 程序对待产物——**双击时自动分配一个黑窗口（DOS 窗口）**，
  # 这是 music.exe 交付后拿到的最直接反馈。cjc 的 `--link-options` 是直接交给 ld.lld 的，
  # 所以只能用 lld 的写法：`-mwindows`（gcc 驱动方言）会被拒（实测 `lld: error: unknown
  # parameter: -mwindows`），取值也只有 GNU 那套（console/windows/native/posix——写 `gui`
  # 会报 `ld.lld: error: unknown subsystem: gui`）。
  # 子系统只管「分不分配控制台」：从终端带重定向启动时 stderr 照旧落到文件，取证链路不变。
  link-option = "$BRIDGE_ARG -lole32 -loleaut32 -luuid -luser32 -lgdi32 -ladvapi32 -lcomdlg32 -lcrypt32 --subsystem=windows"

[target.x86_64-w64-mingw32.bin-dependencies]
    path-option = ["$STDX_PATH"]
TOML

# ---------- ④ 构建 + strip ----------
export PATH="$SDK_LIB:$CANGJIE_HOME/bin:$CANGJIE_HOME/tools/bin:$CANGJIE_HOME/tools/lib:$STDX_STATIC:$PATH"
echo "[pack-single] 静态构建 $WORK/app"
( cd "$WORK/app" && cjpm build )

BUILT="$WORK/app/target/release/bin/main.exe"
[ -f "$BUILT" ] || die "没找到产物: $BUILT"

SIZE_RAW="$(stat -c%s "$BUILT")"
cp "$BUILT" "$EXE"
# strip 失败不是致命问题（只是大一点），保留未 strip 的副本继续
if strip "$EXE" 2>/dev/null; then
    echo "[pack-single] strip: $SIZE_RAW → $(stat -c%s "$EXE") 字节"
else
    echo "[pack-single] 警告: strip 失败，保留未裁剪的 exe（$SIZE_RAW 字节）" >&2
fi

# ---------- ⑤ 自检：导入表里不能还有运行时要找的 DLL ----------
FORBIDDEN="libcangjie-runtime.dll libcjtbridge.dll WebView2Loader.dll libboundscheck.dll"
BAD=""
for d in $FORBIDDEN; do
    if objdump -p "$EXE" | awk '/DLL Name:/ {print $3}' | grep -qi "^$d$"; then
        BAD="$BAD $d"
    fi
done
if [ -n "$BAD" ]; then
    die "产物仍依赖:$BAD —— 静态链接没生效，检查 compile-option 与 link-option"
fi

# 子系统事后复核：必须是 GUI(2)。写成 console(3) 时双击产物会弹 DOS 窗口，
# 而链接期一切正常、日志也照打——所以不能让这条只靠人眼发现。
SUBSYS=$(objdump -p "$EXE" | grep -i "^Subsystem" | awk '{print $2}')
if [ "$SUBSYS" != "00000002" ]; then
    die "产物子系统是 $SUBSYS（应为 00000002 / Windows GUI）：link-option 少了 --subsystem=windows，双击会弹 DOS 窗口"
fi

echo "[pack-single] 单文件: $EXE（$(du -h "$EXE" | cut -f1)）"
echo "[pack-single] 子系统: $SUBSYS (Windows GUI，双击不弹控制台)"
echo "[pack-single] 目录: $OUT_ROOT（应只有这一个文件 + work/）"
echo "[pack-single] 导入的 DLL（应全是 Windows 系统库）:"
objdump -p "$EXE" | awk '/DLL Name:/ {print "  " $3}'
