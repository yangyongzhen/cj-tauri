#!/usr/bin/env bash
# 单文件打包（Linux x64）：把一个示例打成**一个可执行文件**——没有 lib/、没有 ui/、没有 capabilities/。
#
# 用法:
#   bash scripts/pack-linux-single.sh                      # 打包 examples/cjnote
#   bash scripts/pack-linux-single.sh examples/cjnote /tmp/out
#
# 示例要接进来的三件套（缺一不可，本脚本逐条 die 说明）：
#   · `src/packed_assets.cj`：`public let PACKED_*_B64: String = ""` 空存根——**声明了哪几个，
#     本脚本就生成哪几个**（cjnote 有 PACKED_VENDOR_B64，examples/music 没有）；
#   · `src/packed_resources.cj`：`decodeBase64` / `splitBy` / `textOrFile`（内嵌优先、否则读盘）；
#   · `capabilities/` 下至少一份 json：单文件产物没有随行清单，必须编进二进制，否则命令全被拒。
#
# 与 scripts/pack-linux.sh（目录包）的分工：
#   pack-linux.sh         动态链接，交付一个**目录**（可执行文件 + lib/ 一坨仓颉运行时 + stdx +
#                         libcjtbridge.so + ui/ + capabilities/）；
#   pack-linux-single.sh  静态链接，交付**一个文件**。
#
# Linux 侧的「静态」有硬天花板，先说清：**系统 WebKitGTK / GTK 没有静态库**（本机在
# /usr/lib/x86_64-linux-gnu 下查无 libwebkit2gtk-4.1.a / libgtk-3.a），所以全静态 ELF 在 Linux 上
# 不可得——产物仍动态依赖系统那一套图形栈。能静态下来的是「本框架带来的依赖」：
#   ① 仓颉运行时与 std：`--static --static-std`；框架各包（cjTauri / 各插件）用 `--static-libs`——
#      cjc 会对它打一行 deprecated 提示，但它是当前唯一能让**非 std 模块**也静态进来的开关；
#      不写它就会得到一串 libcjTauri*.so 依赖，单文件立刻不成立。这行提示只出现在打包构建里，
#      仓库内的 `cjpm build` 不带这些开关、照旧零警告。
#   ② stdx 必须用 **static** 包：dynamic 包只有 .so，静态链接要 .a（两个包 .cjo 数量一致，
#      靠 CANGJIE_STDX 反推同级目录，或显式给 CANGJIE_STDX_ROOT）。
#   ③ C 桥编成静态归档 libcjtbridge.a 直接链进可执行文件（产物里不再有 libcjtbridge.so）。
#   ④ 页面 / vendor 库 / 能力清单由本脚本生成 src/packed_assets.cj（标准 base64）编进二进制。
#
# 产物：<示例>/dist-single/<示例名>（这份可执行文件随仓库分发，work/ 临时副本不入库）。
# 注意：产物**不含 cjh**——cjnote 按 `vendor/cjh/bin/<平台>/` 找现成二进制，随包放哪就在哪找，
# 它是个独立进程，不参与静态链接（要连 cjh 一起交付就把 vendor/cjh/ 一并拷走）。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

die() { echo "[pack-single] $*" >&2; exit 1; }

case "$(uname -s)" in
    Linux) ;;
    *) die "本脚本只做 Linux 单文件包（Windows 用 scripts/pack-win-single.sh）" ;;
esac
[ "$(uname -m)" = "x86_64" ] || die "本脚本只覆盖 x86_64（当前 $(uname -m)）：静态链的 stdx 与桥都要按架构各备一份"

EXAMPLE="${1:-$ROOT/examples/cjnote}"
[ -d "$EXAMPLE" ] || die "示例不存在: $EXAMPLE"
EXAMPLE="$(cd "$EXAMPLE" && pwd)"   # 取绝对路径：构建副本要 cd 进去跑，相对路径会飘
OUT_ROOT="${2:-$EXAMPLE/dist-single}"
NAME="$(basename "$EXAMPLE")"
EXE="$OUT_ROOT/$NAME"

# ---------- 环境 ----------
[ -n "${CANGJIE_HOME:-}" ] || die "找不到仓颉 SDK，请设置 CANGJIE_HOME"
SDK_LIB="$CANGJIE_HOME/runtime/lib/linux_x86_64_cjnative"

# stdx 静态包：CANGJIE_STDX 习惯指 dynamic/stdx（cjpm 展开 ${CANGJIE_STDX} 用的那个），
# 静态包是它的**同级**目录，所以往上跳两级再进 static/stdx；要给别的布局就用 CANGJIE_STDX_ROOT。
if [ -n "${CANGJIE_STDX_ROOT:-}" ]; then
    STDX_ROOT="$CANGJIE_STDX_ROOT"
elif [ -n "${CANGJIE_STDX:-}" ]; then
    STDX_ROOT="$(dirname "$(dirname "$CANGJIE_STDX")")"
else
    die "请设置 CANGJIE_STDX（指 dynamic/stdx）或 CANGJIE_STDX_ROOT"
fi
STDX_STATIC="$STDX_ROOT/static/stdx"
[ -d "$STDX_STATIC" ] || die "缺 stdx 静态包: $STDX_STATIC（static 包与 dynamic 包同级，见 stdx 解压目录）"

NATIVE="$ROOT/native"
[ -f "$NATIVE/core/bridge_core.c" ] || die "缺 C 桥共享层: $NATIVE/core/bridge_core.c"
[ -f "$NATIVE/platforms/linux/bridge_linux.c" ] || die "缺 C 桥平台实现: $NATIVE/platforms/linux/bridge_linux.c"
[ -d "$EXAMPLE/src" ] || die "示例不存在或没有 src/: $EXAMPLE"

for t in gcc ar pkg-config objdump base64 strip; do
    command -v "$t" >/dev/null 2>&1 || die "缺工具 $t（gcc/ar/objdump/strip 来自 binutils，base64 来自 coreutils）"
done

# ---------- ① 静态桥：编 libcjtbridge.a ----------
# 可选依赖的口径与 native/build_linux.sh 保持一致（同一份源码、同一套开关），否则「目录包能跑的
# 能力，单文件包里没有」——最典型的是全局快捷键（CJ_HAVE_X11）与托盘（CJ_HAVE_TRAY）。
PKGS="webkit2gtk-4.1 gtk+-3.0"
# shellcheck disable=SC2086
pkg-config --exists $PKGS || die "缺 webkit2gtk-4.1 / gtk+-3.0 开发包（apt install libwebkit2gtk-4.1-dev libgtk-3-dev）"

X11_FLAGS=""; X11_LIBS=""
if pkg-config --exists x11; then
    X11_FLAGS="-DCJ_HAVE_X11"; X11_LIBS="$(pkg-config --libs x11)"
    echo "[pack-single] X11 可用：全局快捷键编入（CJ_HAVE_X11）"
else
    echo "[pack-single] 警告：无 X11 开发包，全局快捷键能力位如实不置位" >&2
fi

TRAY_FLAGS=""; TRAY_CFLAGS=""; TRAY_LIBS=""
if pkg-config --exists ayatana-appindicator3-0.1; then
    TRAY_FLAGS="-DCJ_HAVE_TRAY"
    TRAY_CFLAGS="$(pkg-config --cflags ayatana-appindicator3-0.1)"
    TRAY_LIBS="$(pkg-config --libs ayatana-appindicator3-0.1)"
    echo "[pack-single] appindicator 可用：托盘编入（CJ_HAVE_TRAY）"
else
    echo "[pack-single] 警告：无 ayatana-appindicator3，托盘能力位如实不置位" >&2
fi

WORK="$OUT_ROOT/work"
rm -rf "$WORK" "$EXE"
mkdir -p "$WORK/bridge" "$WORK/app" "$OUT_ROOT"

echo "[pack-single] 编译静态桥 libcjtbridge.a"
# -I$NATIVE/core 不能省：native/ 按平台重整后 bridge_linux.c 在 platforms/linux/、bridge_core.h 在
# core/，`#include "bridge_core.h"` 的同目录回落够不着（native/build_linux.sh 里的 `-Icore` 同一件事）。
# shellcheck disable=SC2086
( cd "$WORK/bridge" && gcc -c -O2 -fstack-protector-all \
    -I"$NATIVE/core" $X11_FLAGS $TRAY_FLAGS $TRAY_CFLAGS $(pkg-config --cflags $PKGS) \
    "$NATIVE/core/bridge_core.c" "$NATIVE/platforms/linux/bridge_linux.c" && \
    ar rcs libcjtbridge.a bridge_core.o bridge_linux.o )
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
# 就是「这个示例要内嵌它」——examples/music 没有 vendor 库，生成时就不写那一条。
ASSET_STUB="$EXAMPLE/src/packed_assets.cj"
[ -f "$ASSET_STUB" ] || die "示例还没接内嵌资源：缺 $ASSET_STUB（空存根 + 取用函数，见 examples/music/src/packed_resources.cj）"
has_asset() { grep -q "^public let $1" "$ASSET_STUB"; }
has_asset PACKED_UI_B64 || die "$ASSET_STUB 里没有 PACKED_UI_B64 存根"

b64() { base64 -w0 "$1" 2>/dev/null || base64 "$1" | tr -d '\n'; }

# 页面必填
UI_FILE="$WORK/app/ui/index.html"
[ -f "$UI_FILE" ] || die "示例缺前端页面: $UI_FILE"
UI_B64="$(b64 "$UI_FILE")"

# three.js 只有用它的示例才有（typing-poem）：这个示例的页面是 run(html) 的内联来源（无真实来源），
# 相对 <script src> 与 ES module 都不成立，只能把整份 UMD 走 document-start 注入，所以必须内嵌。
THREE_B64=""
if has_asset PACKED_THREE_B64; then
    THREE_FILE="$WORK/app/ui/vendor/three.min.js"
    [ -f "$THREE_FILE" ] || die "存根声明了 PACKED_THREE_B64，但缺 $THREE_FILE"
    THREE_B64="$(b64 "$THREE_FILE")"
fi

# vendor 库：只有存根声明了 PACKED_VENDOR_B64 的示例才打。示例自带 ui/vendor/pack-files.txt 时
# 按它逐行给相对路径（各示例的文件与数量不同）；没有该文件时回落到 markdown-notes 那套默认清单。
# 无论走哪条路，**顺序**都是契约：与应用侧 packed_resources.cj 的 vendorSegments() 逐条对齐。
VENDOR_B64=""; VENDOR_N=0
if has_asset PACKED_VENDOR_B64; then
    VENDOR_LIST_FILE="$WORK/app/ui/vendor/pack-files.txt"
    if [ -f "$VENDOR_LIST_FILE" ]; then
        VENDOR_FILES=()
        while IFS= read -r vline; do
            vline="${vline%$'\r'}"
            if [ -n "$vline" ]; then
                VENDOR_FILES+=("$vline")
                VENDOR_N=$((VENDOR_N + 1))
            fi
        done < "$VENDOR_LIST_FILE"
        [ "$VENDOR_N" -ge 1 ] || die "vendor 清单是空的：$VENDOR_LIST_FILE"
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
    VENDOR_N="${#VENDOR_FILES[@]}"
fi

# 能力清单：每个 capabilities/*.json 各自 base64，再用 "," 拼起来
# （base64 字符表里没有逗号，所以逗号是安全的分隔符；应用侧按逗号切开逐个挂载）
CAPS_B64=""; CAPS_N=0
for f in "$EXAMPLE"/capabilities/*.json; do
    [ -f "$f" ] || continue
    piece="$(b64 "$f")"
    if [ -z "$CAPS_B64" ]; then CAPS_B64="$piece"; else CAPS_B64="$CAPS_B64,$piece"; fi
    CAPS_N=$((CAPS_N + 1))
done
[ "$CAPS_N" -ge 1 ] || die "capabilities/ 下没有 json：单文件包必须把清单编进去，否则命令全被拒"

# 存根里若还有本脚本不认识的内嵌常量，**当场报错**而不是悄悄跳过——漏一个的表现是「构建照过、
# 运行到那处才发现资源是空的」，比打包当场失败难查得多（typing-poem 的 PACKED_THREE_B64 就是这类）。
while IFS= read -r cst; do
    case "$cst" in
        PACKED_UI_B64|PACKED_VENDOR_B64|PACKED_THREE_B64|PACKED_CAPS_B64) ;;
        *) die "$ASSET_STUB 声明了本脚本不认识的内嵌常量 $cst：在脚本里接上它，或去掉存根那一行" ;;
    esac
done < <(grep -o '^public let PACKED_[A-Z0-9_]*' "$ASSET_STUB" | sed 's/^public let //')

echo "[pack-single] 内嵌：页面 ${#UI_B64} / three.js ${#THREE_B64} / vendor ${VENDOR_N} 份 ${#VENDOR_B64} / 清单 ${CAPS_N} 份 —— 均为 base64 字节数"
{
    printf 'package %s\n\n' "$PKG_NAME"
    printf '/* 由 scripts/pack-linux-single.sh 生成：内嵌资源（标准 base64，无换行）。**不要手工编辑**。\n'
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

# ---------- ③ cjpm.toml：静态链接 + 静态桥 ----------
# sqlite 只在示例**真的**引用了该插件时才链：cjc 把 link-option 直接交给 ld.lld，没有 gcc 那套
# `--as-needed` 默认行为，写在链接行上的库一定会进产物的 DT_NEEDED（实测 cjnote：不引用 sqlite
# 插件，产物里却挂着 libsqlite3.so.0，而 `objdump -T` 里 0 个 sqlite3_ 符号——纯粹的幽灵依赖，
# 交付到没装 libsqlite3 的机器上会当场起不来）。
SQLITE_LIB=""
if grep -rqs 'cjTauri\.plugins\.sqlite' "$EXAMPLE/src"; then
    pkg-config --exists sqlite3 || die "示例引用了 sqlite 插件，但本机没有 sqlite3 开发包（apt install libsqlite3-dev）"
    SQLITE_LIB="-lsqlite3"
    echo "[pack-single] 示例引用 sqlite 插件：链入 -lsqlite3"
fi

# 链接行 = 静态桥 + 系统图形栈（与框架 cjpm.toml 的 Linux 段同名单）+ 可选 X11/托盘。
# 注意 heredoc **不加引号**（$PKG_NAME / $BRIDGE_LIB 等要展开），所以下面注释里的反引号
# 全都写成「反斜杠 + 反引号」——不转义时 bash 会把反引号里的内容当命令执行（见 AGENTS §4）。
LINK_OPTION="$BRIDGE_LIB $SQLITE_LIB -lwebkit2gtk-4.1 -lgtk-3 -lgdk-3 -lglib-2.0 -lgio-2.0 -lsoup-3.0 -ljavascriptcoregtk-4.1 -lgobject-2.0 $X11_LIBS $TRAY_LIBS"
cat > "$WORK/app/cjpm.toml" <<TOML
[package]
  cjc-version = "1.0.5"
  name = "$PKG_NAME"
  version = "0.1.0"
  output-type = "executable"
  # \`--static\` 静态链仓颉运行时、\`--static-std\` 静态链 std、\`--static-libs\` 静态链**其他模块**
  # （框架各包）。三者缺一：少 --static-libs 时框架仍是 libcjTauri*.so，单文件立刻不成立。
  # cjc 会对 --static-libs 打一行 deprecated 提示——当前没有等效的替代开关，留着并在末尾自检里
  # 用「产物有没有 libcjTauri* 依赖」兜住：一旦将来它失效，自检会红，而不是悄悄产出半动态的包。
  compile-option = "--static --static-std --static-libs"

[dependencies]
  cjTauri = { path = "$ROOT" }

[target.x86_64-unknown-linux-gnu]
  # 静态桥的绝对路径写在最前：它优先于框架 cjpm.toml 里的 \`-Lnative -lcjtbridge\`，
  # 于是链进来的是我们刚编的归档，而不是 native/ 下那份 .so（末尾自检会复核产物没有 libcjtbridge 依赖）。
  link-option = "$LINK_OPTION"

[target.x86_64-unknown-linux-gnu.bin-dependencies]
    path-option = ["$STDX_STATIC"]
TOML

# ---------- ④ 构建 + strip ----------
export PATH="$SDK_LIB:$CANGJIE_HOME/bin:$CANGJIE_HOME/tools/bin:$CANGJIE_HOME/tools/lib:$PATH"
export LD_LIBRARY_PATH="$NATIVE:$SDK_LIB:${CANGJIE_STDX:-$STDX_ROOT/dynamic/stdx}${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
echo "[pack-single] 静态构建 $WORK/app"
( cd "$WORK/app" && cjpm build )

BUILT="$WORK/app/target/release/bin/main"
[ -f "$BUILT" ] || die "没找到产物: $BUILT"

SIZE_RAW="$(stat -c%s "$BUILT")"
cp "$BUILT" "$EXE"
SIZE_STRIPPED="$SIZE_RAW"
# strip 失败不是致命问题（只是大一点）：与 pack-win-single.sh 同样的教训——把失败吞进 2>/dev/null
# 会让它换一个更贵的样子出现，所以这里如实报出来，不静默。
if strip "$EXE" 2>/dev/null; then
    SIZE_STRIPPED="$(stat -c%s "$EXE")"
    echo "[pack-single] strip: $SIZE_RAW → $SIZE_STRIPPED 字节"
else
    echo "[pack-single] 警告: strip 失败，保留未裁剪的产物（$SIZE_RAW 字节）" >&2
fi

# ---------- ⑤ 自检：本框架带来的动态依赖必须清零 ----------
# 判据是产物的 DT_NEEDED，不是「链接命令里写了什么」——静态链接有没有生效只有它能回答。
NEEDED="$(objdump -p "$EXE" | awk '/NEEDED/{print $2}')"
BAD="$(printf '%s\n' "$NEEDED" | grep -E 'libcangjie|libboundscheck|libstdx|libcjtbridge|libcjTauri' || true)"
if [ -n "$BAD" ]; then
    printf '%s\n' "$BAD" >&2
    die "产物仍依赖上面这些本框架带来的库 —— 静态链接没生效，检查 compile-option 与 stdx 是否指到 static 包"
fi

# 再按「裸机」复核一次：不带 LD_LIBRARY_PATH 时必须能解析全部依赖（缺一个就是交付到别人机器上
# 启动即退，而本机上因为 LD_LIBRARY_PATH 里有 SDK 目录反而看不出问题）。
MISSING="$(env -u LD_LIBRARY_PATH ldd "$EXE" 2>/dev/null | grep -c 'not found' || true)"
[ "$MISSING" = "0" ] || die "摘掉 LD_LIBRARY_PATH 后有 $MISSING 个依赖解析不到：交付到别的机器会启动即退"

echo "[pack-single] 单文件: $EXE（$(du -h "$EXE" | cut -f1)，未 strip $SIZE_RAW → strip 后 $SIZE_STRIPPED 字节）"
echo "[pack-single] 目录: $OUT_ROOT（产物只有这一个文件 + work/ 临时副本）"
echo "[pack-single] 剩余动态依赖（应全是系统库；WebKitGTK/GTK 无静态库，Linux 上躲不开）:"
printf '%s\n' "$NEEDED" | sed 's/^/  /'
echo "[pack-single] 提示：产物不含 cjh（独立进程，cjnote 按 vendor/cjh/bin/<平台>/ 找现成二进制），"
echo "[pack-single]       要连 AI 后端一起交付就把它一并拷到同级 vendor/ 下。"
