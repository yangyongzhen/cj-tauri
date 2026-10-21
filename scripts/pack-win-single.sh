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
#      首次运行时释放到 %TEMP%\cj-tauri-loader\ 再按绝对路径加载（幂等，见 native/platforms/windows/bridge_win.c）；
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
[ -f "$NATIVE/platforms/windows/bridge_win.c" ] || die "缺 C 桥源码: $NATIVE/platforms/windows/bridge_win.c"
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

# ---------- ①a 随包资源：把**外部程序**（cjh 这类）作为 PE 资源嵌进 exe ----------
# 单文件产物没有随行目录，而 cjh 是独立可执行程序 + 4 个运行时 DLL，既并不进静态库、也不在 PE
# 导入表里，只能作为 RT_RCDATA 资源跟着 exe 走，运行期由桥取出来写盘
# （native/platforms/windows/bridge_win.c 的 cj_plat_extract_assets）。
# 清单：$EXAMPLE/pack-assets.txt，一行一个相对示例根的路径；没有这个文件 = 不嵌任何东西。
# 资源名只能用**数字 ID**：llvm-rc 不认字符串资源名（实测
# `llvm-rc: Error parsing file: expected int or identifier, got "cjh.exe"`），
# 所以另生成一份「ID -> 文件名」的表交给桥，桥不认识应用的任何名字。
PACK_ASSETS_LIST="$EXAMPLE/pack-assets.txt"
RC_FILE="$WORK/bridge/pack_assets.rc"
MAP_HDR="$WORK/bridge/pack_assets_map.h"
ASSET_COUNT=0
ASSET_NEXT_ID=1001
: > "$RC_FILE"
{
    printf '/* 打包器生成：单文件产物内嵌的随包资源（资源 ID -> 释放出来的文件名）。不要手改。 */\n'
    printf 'typedef struct {\n    int id;\n    const char *name;\n} CjPackAsset;\n'
    printf 'static const CjPackAsset CJ_PACK_ASSETS[] = {\n'
} > "$MAP_HDR"
if [ -f "$PACK_ASSETS_LIST" ]; then
    while IFS= read -r line; do
        line="$(printf '%s' "$line" | tr -d '\r' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
        case "$line" in
            '' | '#'*) continue ;;
        esac
        ASSET_SRC="$EXAMPLE/$line"
        [ -f "$ASSET_SRC" ] || die "pack-assets.txt 里这一行指向的资产不存在: $ASSET_SRC"
        # 正斜杠盘符形式：windres 是原生 Windows 程序，认 C:/...（cjpm.toml 同口径）
        printf '%d RCDATA "%s"\n' "$ASSET_NEXT_ID" "$(cygpath -m "$ASSET_SRC")" >> "$RC_FILE"
        printf '    { %d, "%s" },\n' "$ASSET_NEXT_ID" "$(basename "$ASSET_SRC")" >> "$MAP_HDR"
        ASSET_COUNT=$((ASSET_COUNT + 1))
        ASSET_NEXT_ID=$((ASSET_NEXT_ID + 1))
    done < "$PACK_ASSETS_LIST"
fi
printf '};\n' >> "$MAP_HDR"

ASSET_OBJ=""
EMBED_DEF=""
if [ "$ASSET_COUNT" -gt 0 ]; then
    command -v windres >/dev/null 2>&1 || die "需要 windres 编内嵌资源（llvm-mingw 自带）"
    echo "[pack-single] 内嵌随包资源 $ASSET_COUNT 个（外部程序，静态链接进不来）"
    # 用相对名而不是 $RC_FILE：windres 可能是原生 Windows 程序（llvm-mingw 自带那份），
    # 它不认识 MSYS 的 /e/... 形式路径，报 "no such file or directory" 后 Preprocessing failed。
    ( cd "$WORK/bridge" && windres -O coff -i pack_assets.rc -o pack_assets.o ) || die "windres 编译资源失败"
    ASSET_OBJ="pack_assets.o"
    EMBED_DEF="-DCJ_PACK_ASSETS_EMBEDDED"
fi

echo "[pack-single] 编译静态桥 libcjtbridge.a"
# -I 要同时给两个目录：$WORK/bridge（本脚本刚生成的内嵌 loader 头与资源表）与 $NATIVE/core
# （bridge_core.h / bridge_js.h）。后者不能省——native/ 按平台重整后 bridge_win.c 在
# platforms/windows/、bridge_core.h 在 core/，不再是同一目录，#include "..." 的同目录
# 回落也就够不着了（实测报 `bridge_core.h file not found`）；native/build_win.bat 里的
# `-Icore` 是同一件事。
( cd "$WORK/bridge" && gcc -c -O2 -fstack-protector-all -DCJ_EMBED_WEBVIEW2_LOADER $EMBED_DEF \
    -I"$(to_win "$WORK/bridge")" -I"$(to_win "$NATIVE/core")" -I"$(to_win "$WEBVIEW2_INCLUDE")" \
    "$(to_win "$NATIVE/core/bridge_core.c")" "$(to_win "$NATIVE/platforms/windows/bridge_win.c")" && \
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

# vendor 库：只有存根声明了 PACKED_VENDOR_B64 的示例才打。清单默认是 markdown-notes 的
# marked / highlight.js / 三份 hljs 主题；示例自带 ui/vendor/pack-files.txt 时按它逐行给的
# 相对路径打（各示例的文件与数量不同，如 leetcode-gui 只有 CodeMirror 两份）。
# 无论走哪条路，**顺序**都是契约：与应用侧 packed_resources.cj 的 VENDOR_FILES 逐字对齐，
# 两边改一边就会错位。
VENDOR_B64=""
if has_asset PACKED_VENDOR_B64; then
    VENDOR_LIST_FILE="$WORK/app/ui/vendor/pack-files.txt"
    if [ -f "$VENDOR_LIST_FILE" ]; then
        VENDOR_FILES=()
        VENDOR_N=0
        while IFS= read -r vline; do
            vline="${vline%$'\r'}"
            if [ -n "$vline" ]; then
                VENDOR_FILES+=("$vline")
                VENDOR_N=$((VENDOR_N + 1))
            fi
        done < "$VENDOR_LIST_FILE"
        if [ "$VENDOR_N" -lt 1 ]; then die "vendor 清单是空的：$VENDOR_LIST_FILE"; fi
    else
        VENDOR_FILES=(ui/vendor/marked.min.js ui/vendor/highlight.min.js \
            ui/vendor/github-dark-dimmed.min.css ui/vendor/github-dark.min.css ui/vendor/atom-one-dark.min.css)
    fi
    for vf in "${VENDOR_FILES[@]}"; do
        vf_file="$WORK/app/$vf"
        [ -f "$vf_file" ] || die "存根声明了 PACKED_VENDOR_B64，但缺 $vf_file"
        vf_piece="$(b64 "$vf_file")"
        if [ -z "$VENDOR_B64" ]; then VENDOR_B64="$vf_piece"; else VENDOR_B64="$VENDOR_B64,$vf_piece"; fi
    done
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

echo "[pack-single] 生成内嵌资源：页面 ${#UI_B64} / three.js ${#THREE_B64} / vendor ${#VENDOR_B64} base64 字节，能力清单 $CAPS_N 份"
{
    printf 'package %s\n\n' "$PKG_NAME"
    printf '/* 由 scripts/pack-win-single.sh 生成：内嵌资源（标准 base64，无换行）。**不要手工编辑**。\n'
    printf '   常量非空即「内嵌模式」；仓库里的同名文件是空存根，正常构建仍按相对路径读盘。 */\n'
    printf 'public let PACKED_UI_B64: String = "%s"\n' "$UI_B64"
    if has_asset PACKED_THREE_B64; then
        printf 'public let PACKED_THREE_B64: String = "%s"\n' "$THREE_B64"
    fi
    if has_asset PACKED_VENDOR_B64; then
        printf 'public let PACKED_VENDOR_B64: String = "%s"\n' "$VENDOR_B64"
    fi
    printf 'public let PACKED_CAPS_B64: String = "%s"\n' "$CAPS_B64"
} > "$WORK/app/src/packed_assets.cj"

# ---------- ③ cjpm.toml：静态链接三件套 + 静态桥 ----------
# 包名上面已经从示例抄好（PKG_NAME），这里只负责写构建配置。

# cjpm.toml 里出现的路径都要盘符形式（cjpm 与它拉起的 gcc 都是原生 Windows 程序，
# 看到 /d/... 会当成「当前盘根目录下的 d 目录」）
DEP_PATH="$(to_win "$ROOT")"
BRIDGE_ARG="$(to_win "$BRIDGE_LIB")"
# 资源对象必须**当链接输入直接给 ld.lld**，不能放进 libcjtbridge.a：静态库按需提取，
# 资源对象没有任何符号引用，塞进去链接器根本不取——实测那样打出来的 exe 连 `.rsrc` 节
# 都没有（体积也一点没涨），运行期 findCjhBin 找不到 cjh，页面照旧显示「AI 后端未就绪」。
ASSET_LINK_ARG=""
if [ -n "$ASSET_OBJ" ]; then
    ASSET_LINK_ARG=" $(to_win "$WORK/bridge/pack_assets.o")"
fi
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
  # 注意：本 heredoc **不加引号**（$PKG_NAME / $BRIDGE_ARG 等要展开），所以下面注释里的反引号
  # 全都写成「反斜杠 + 反引号」的转义形式——不转义时 bash 会把反引号里的内容当命令去执行
  # （实测打 serial-waveform 时刷出一串 "-lcrypt32: command not found"）：不致命，
  # 但等于把注释变成了执行，还会让生成的 toml 注释缺字。
  # \`-lcrypt32\`：stdx.net.tls 的根证书读取走 Windows 证书库（CertOpenSystemStoreA /
  # CertEnumCertificatesInStore / CertCloseStore 都在 crypt32.dll），静态链接的示例只要碰
  # https 就得链上它，否则 ld.lld 在链接期报一串 undefined symbol（examples/music 实测：
  # 它的封面走 https，而 typing-poem 不用 TLS，所以这条直到打音乐示例才暴露）。
  # 用不到的示例多链一个系统库无副作用（import 表里不会出现，见脚本末尾的自检）。
  # \`--subsystem=windows\`：产物按 GUI 子系统链接（PE Subsystem=2，脚本末尾有事后悔核）。
  # 缺了它 Windows 就按 console 程序对待产物——**双击时自动分配一个黑窗口（DOS 窗口）**，
  # 这是 music.exe 交付后拿到的最直接反馈。cjc 的 \`--link-options\` 是直接交给 ld.lld 的，
  # 所以只能用 lld 的写法：\`-mwindows\`（gcc 驱动方言）会被拒（实测 \`lld: error: unknown
  # parameter: -mwindows\`），取值也只有 GNU 那套（console/windows/native/posix——写 \`gui\`
  # 会报 \`ld.lld: error: unknown subsystem: gui\`）。
  # 子系统只管「分不分配控制台」：从终端带重定向启动时 stderr 照旧落到文件，取证链路不变。
  link-option = "$BRIDGE_ARG$ASSET_LINK_ARG -lole32 -loleaut32 -luuid -luser32 -lgdi32 -ladvapi32 -lcomdlg32 -lcrypt32 --subsystem=windows"

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
# 原生 llvm 工具（strip / llvm-objcopy / objdump 都是 Windows 程序）只认 C:/ 形式路径：传 MSYS 的
# /e/... 会得到 "No such file or directory"，而 strip 那条还被 2>/dev/null 吞掉，表象是「strip 失败
# 但 exe 好端端的」。所以给它们单独一份转换后的路径（stat / du / cp 仍用 POSIX 形式）。
EXE_W="$(to_win "$EXE")"
# strip 失败不是致命问题（只是大一点），保留未 strip 的副本继续。
# 已知坑：llvm-mingw 的 strip.exe 是包装器，实际调用同目录的 llvm-strip——有的发行包里
# 这个真身缺失（2026-10-11 实测 C:\tool\llvm-mingw-* 报 "llvm-strip: No such file or directory"），
# 而 `strip 2>/dev/null` 会把真实报错吞掉，看起来像「strip 对这个 exe 无效」。
# 所以失败后回退 SDK 自带的 llvm-objcopy --strip-all（同为 llvm 工具链，对 PE 等效）。
if strip "$EXE_W" 2>/dev/null; then
    echo "[pack-single] strip: $SIZE_RAW → $(stat -c%s "$EXE") 字节"
elif command -v llvm-objcopy >/dev/null 2>&1 && [ -f "$CANGJIE_HOME/third_party/llvm/bin/llvm-objcopy.exe" ] \
     && "$CANGJIE_HOME/third_party/llvm/bin/llvm-objcopy.exe" --strip-all "$EXE_W" 2>/dev/null; then
    echo "[pack-single] strip(llvm-objcopy 回退): $SIZE_RAW → $(stat -c%s "$EXE") 字节"
else
    echo "[pack-single] 警告: strip 失败，保留未裁剪的 exe（$SIZE_RAW 字节）" >&2
fi

# ---------- ⑤ 自检：导入表里不能还有运行时要找的 DLL ----------
FORBIDDEN="libcangjie-runtime.dll libcjtbridge.dll WebView2Loader.dll libboundscheck.dll"
BAD=""
for d in $FORBIDDEN; do
    if objdump -p "$EXE_W" | awk '/DLL Name:/ {print $3}' | grep -qi "^$d$"; then
        BAD="$BAD $d"
    fi
done
if [ -n "$BAD" ]; then
    die "产物仍依赖:$BAD —— 静态链接没生效，检查 compile-option 与 link-option"
fi

# 子系统事后复核：必须是 GUI(2)。写成 console(3) 时双击产物会弹 DOS 窗口，
# 而链接期一切正常、日志也照打——所以不能让这条只靠人眼发现。
SUBSYS=$(objdump -p "$EXE_W" | grep -i "^Subsystem" | awk '{print $2}')
if [ "$SUBSYS" != "00000002" ]; then
    die "产物子系统是 $SUBSYS（应为 00000002 / Windows GUI）：link-option 少了 --subsystem=windows，双击会弹 DOS 窗口"
fi

echo "[pack-single] 单文件: $EXE（$(du -h "$EXE" | cut -f1)）"
echo "[pack-single] 子系统: $SUBSYS (Windows GUI，双击不弹控制台)"
echo "[pack-single] 目录: $OUT_ROOT（应只有这一个文件 + work/）"
echo "[pack-single] 导入的 DLL（应全是 Windows 系统库）:"
objdump -p "$EXE_W" | awk '/DLL Name:/ {print "  " $3}'
