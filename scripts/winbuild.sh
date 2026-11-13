#!/usr/bin/env bash
# winbuild.sh — 在 **Linux** 上交叉打包 Windows 单文件 exe（cjh 仓 scripts/winbuild.sh 的思路 + 本仓
# pack-win-single.sh 的产物流程）。
#
# 为什么存在：pack-win-single.sh 第一道守卫就限死 MINGW/MSYS/CYGWIN，没有 Windows 机器时打不了单文件包；
# 而 cjh 已实测「Linux 交叉编译 Windows 包」这条路走得通（cjc --target + mingw 交叉工具链 + stdx 的
# windows static 包）。本脚本把那条路与本仓的单文件产物流程拼起来，产物与 pack-win-single.sh 可直接互换。
#
# 用法:
#   bash scripts/winbuild.sh                    # 打包 examples/ai-chat（缺省）
#   bash scripts/winbuild.sh examples/music     # 指定示例
#
# 前置（一次性）：
#   · 交叉工具链：apt install gcc-mingw-w64-x86-64（gcc/ar/objdump/strip 都在）
#   · WebView2 SDK：nuget 的 Microsoft.Web.WebView2 zip 解到 $WEBVIEW2_SDK_ROOT
#     （build/native/include/WebView2.h + build/native/x64/WebView2Loader.dll），
#     并把那份 Loader.dll 复制到 native/webview2/（gitignore 挡住，不入库）
#   · stdx 的 windows **static** 包 $WINDOWS_STDX（缺 dynamic 的 12 个 libstdx.*.dll 依赖，
#     cjh v1.3.5 同款回归）。**版本必须与 cjc 配套**（本条下面第 ⑤ 段有运行时守卫）：cjc 1.2.0 配
#     stdx 1.0.5.1 是跨版本混配——`cjpm build` 照过、产物也能生成，只是真机启动即崩，而 GUI 子系统
#     双击时 stderr 无效、一行凭证都没有，表象就是「双击没反应」（2026-11-06 实测，cookie-export）。
#     缺配套包就按 AtomGit Cangjie/cangjie_stdx 的 releases 下同名 zip 解到 ~/.cangjie/stdx/ 下
#
# 与 pack-win-single.sh 的三点已知差异（都来自交叉环境，产物不受影响）：
#   · 工具全是 Linux 原生交叉版（路径一律 POSIX，没有 to_win/cygpath 那层）
#   · cjpm 以 --target x86_64-w64-mingw32 构建，产物在 target/<三元组>/release/bin/
#   · 框架 toml 的 ${CANGJIE_STDX} 靠进程环境展开，构建前 export 成 windows static 包
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

die() { echo "[winbuild] $*" >&2; exit 1; }

EXAMPLE="${1:-examples/ai-chat}"
[ -d "$EXAMPLE/src" ] || die "示例不存在或没有 src/: $EXAMPLE"
NAME="$(basename "$EXAMPLE")"
# 绝对路径：桥编译那段会 cd 进 work/bridge 再用 -I 引这些目录，相对路径从新 cwd 解析就指错
# （实测：-I"$WORK/bridge" 相对化后 gcc 报 EventToken.h / webview2_loader_embed.h 找不到）
OUT_ROOT="$ROOT/$EXAMPLE/dist-single"
# CJ_WINBUILD_CONSOLE=1 → 打 console 子系统的**诊断版**（产物名带 -console 后缀）：
# GUI 子系统双击时 stderr 句柄无效，桥的每一行 [cj-bridge] 日志都会丢，「点了没反应」无从下手；
# console 版双击会弹一扇黑窗、日志与仓颉运行时异常全部可见，用于定位「启动即死」。
# 注意它只是诊断产物，交付版仍是 --subsystem=windows（不弹黑窗）。
SUBSYS_ARG="--subsystem=windows"
SUBSYS_EXPECT="00000002"
SUBSYS_LABEL="Windows GUI（双击不弹控制台）"
EXE_SUFFIX=""
if [ "${CJ_WINBUILD_CONSOLE:-0}" = "1" ]; then
    SUBSYS_ARG="--subsystem=console"
    SUBSYS_EXPECT="00000003"
    SUBSYS_LABEL="console（诊断版：双击弹黑窗，日志可见）"
    EXE_SUFFIX="-console"
fi
EXE="$OUT_ROOT/$NAME$EXE_SUFFIX.exe"

CANGJIE_HOME="${CANGJIE_HOME:-/opt/cangjie/cangjie}"
[ -x "$CANGJIE_HOME/bin/cjc" ] || die "缺 cjc: $CANGJIE_HOME/bin/cjc（设 CANGJIE_HOME 指向 SDK 根）"

WINDOWS_STDX="${CJ_TAURI_WINDOWS_STDX:-$HOME/.cangjie/stdx/cangjie-stdx-windows-x64-1.2.0.1/windows_x86_64_cjnative/static/stdx}"
[ -d "$WINDOWS_STDX" ] || die "缺 windows stdx static 包: $WINDOWS_STDX（版本要与 $CANGJIE_HOME 的 cjc 配套）"

# stdx 与 cjc 必须配套：混配时编译链接全过、产物也在，只是真机启动即崩（GUI 子系统下连日志都没有，
# 表象是「双击没反应」）。取两边的主次版本号比一次，不一致就当场拒，别让它跑到真机上才暴露。
CJC_VER="$("$CANGJIE_HOME/bin/cjc" -v 2>/dev/null | awk -F': *' 'NR==1 {print $2; exit}' | awk '{print $1}')"
STDX_VER="$(printf '%s' "$WINDOWS_STDX" | sed -n 's#.*cangjie-stdx-[A-Za-z0-9_]*-x64-\([0-9][0-9.]*\)/.*#\1#p')"
mm() { printf '%s' "$1" | awk -F. '{print $1 "." $2}'; }
if [ -n "$CJC_VER" ] && [ -n "$STDX_VER" ] && [ "$(mm "$CJC_VER")" != "$(mm "$STDX_VER")" ]; then
    die "windows stdx $STDX_VER 与 cjc $CJC_VER 主次版本不配套（混配的产物真机启动即崩）：换配套的 stdx 包，或设 CJ_TAURI_WINDOWS_STDX 显式指"
fi
echo "[winbuild] cjc $CJC_VER + windows stdx ${STDX_VER:-未知版本}"

WEBVIEW2_SDK_ROOT="${WEBVIEW2_SDK_ROOT:-$HOME/.cache/webview2-sdk/1.0.2365.46}"
WEBVIEW2_INCLUDE="$WEBVIEW2_SDK_ROOT/build/native/include"
[ -f "$WEBVIEW2_INCLUDE/WebView2.h" ] || die "缺 WebView2 头文件: $WEBVIEW2_INCLUDE/WebView2.h（见脚本头部的 nuget 取法）"

NATIVE="$ROOT/native"
[ -f "$NATIVE/platforms/windows/bridge_win.c" ] || die "缺 C 桥源码: $NATIVE/platforms/windows/bridge_win.c"
LOADER_DLL="$NATIVE/webview2/WebView2Loader.dll"
[ -f "$LOADER_DLL" ] || die "缺 $LOADER_DLL（nuget 解包后复制 build/native/x64/WebView2Loader.dll 过来）"

for t in x86_64-w64-mingw32-gcc x86_64-w64-mingw32-ar x86_64-w64-mingw32-objdump x86_64-w64-mingw32-strip od base64; do
    command -v "$t" >/dev/null 2>&1 || die "缺交叉工具 $t（apt install gcc-mingw-w64-x86-64）"
done

WORK="$OUT_ROOT/work"
rm -rf "$WORK"
rm -f "$EXE"
mkdir -p "$WORK/bridge" "$WORK/app" "$OUT_ROOT"

# ---------- ① 静态桥：交叉编 libcjtbridge.a，并把 WebView2Loader.dll 的字节编进去 ----------
LOADER_BYTES="$(stat -c%s "$LOADER_DLL")"
echo "[winbuild] 内嵌 WebView2Loader.dll（$LOADER_BYTES 字节）"
{
    printf '#define CJ_WV2_LOADER_SIZE %su\n' "$LOADER_BYTES"
    printf 'static const unsigned char CJ_WV2_LOADER_BYTES[CJ_WV2_LOADER_SIZE] = {\n'
    od -An -v -tu1 "$LOADER_DLL" | awk '{for (i = 1; i <= NF; i++) printf "0x%02x,", $i; printf "\n"}'
    printf '};\n'
} > "$WORK/bridge/webview2_loader_embed.h"

# 随包资源（pack-assets.txt，一行一个相对示例根的路径；没有这个文件 = 不嵌任何东西）。
# 资源名只能用数字 ID（llvm-rc/windres 不认字符串资源名）；ID -> 文件名的表交给桥。
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
        # 绝对化：windres 在 work/bridge 里跑，RC 里的相对路径从那儿解析不到（原 MSYS 脚本
        # 用 cygpath -m 转盘符绝对路径，同理）；Linux 交叉版 windres 认 POSIX 绝对路径
        ASSET_SRC="$(cd "$(dirname "$ASSET_SRC")" && pwd)/$(basename "$ASSET_SRC")"
        printf '%d RCDATA "%s"\n' "$ASSET_NEXT_ID" "$ASSET_SRC" >> "$RC_FILE"
        printf '    { %d, "%s" },\n' "$ASSET_NEXT_ID" "$(basename "$ASSET_SRC")" >> "$MAP_HDR"
        ASSET_COUNT=$((ASSET_COUNT + 1))
        ASSET_NEXT_ID=$((ASSET_NEXT_ID + 1))
    done < "$PACK_ASSETS_LIST"
fi
printf '};\n' >> "$MAP_HDR"

ASSET_OBJ=""
EMBED_DEF=""
ASSET_LINK_ARG=""   # set -u：示例没有 pack-assets.txt 时不进赋值分支，这里先给空串
if [ "$ASSET_COUNT" -gt 0 ]; then
    command -v x86_64-w64-mingw32-windres >/dev/null 2>&1 || die "需要 x86_64-w64-mingw32-windres 编内嵌资源"
    echo "[winbuild] 内嵌随包资源 $ASSET_COUNT 个"
    ( cd "$WORK/bridge" && x86_64-w64-mingw32-windres -O coff -i pack_assets.rc -o pack_assets.o ) || die "windres 编译资源失败"
    ASSET_OBJ="pack_assets.o"
    EMBED_DEF="-DCJ_PACK_ASSETS_EMBEDDED"
fi

echo "[winbuild] 交叉编译静态桥 libcjtbridge.a"
# Linux 交叉工具链的 Windows SDK 头不齐：WebView2.h 引 EventToken.h，而 mingw-w64 的 deb 包
# 不带它。这个头在 Windows SDK 里只有 EventRegistrationToken 一个结构，直接生成最小版本
# （与 MSYS mingw / Windows SDK 的定义一致），脚本保持自包含
cat > "$WORK/bridge/EventToken.h" <<'EOF'
/* 最小 EventToken.h：mingw-w64 deb 包不带这个 Windows SDK 头，WebView2.h 需要 */
#ifndef __EventToken_h__
#define __EventToken_h__
typedef struct EventRegistrationToken {
    long long value;
} EventRegistrationToken;
#endif
EOF
# -I 四个目录：work/bridge（内嵌头/资源表/EventToken.h）、native/core（bridge_core.h / bridge_js.h，
# 同目录回落在 native/ 重整后已够不着）、WebView2 SDK 的 include（bridge_win.c 引 WebView2.h）、
# 交叉工具链的 Windows SDK 头目录（windows.h 等）
( cd "$WORK/bridge" && x86_64-w64-mingw32-gcc -c -O2 -fstack-protector-all -DCJ_EMBED_WEBVIEW2_LOADER $EMBED_DEF \
    -I"$WORK/bridge" -I"$NATIVE/core" -I"$WEBVIEW2_INCLUDE" -I/usr/x86_64-w64-mingw32/include \
    "$NATIVE/core/bridge_core.c" "$NATIVE/platforms/windows/bridge_win.c" && \
    x86_64-w64-mingw32-ar rcs libcjtbridge.a bridge_core.o bridge_win.o )
BRIDGE_LIB="$WORK/bridge/libcjtbridge.a"
[ -f "$BRIDGE_LIB" ] || die "静态桥编译失败"

# ---------- ② 构建副本：拷示例 + 生成内嵌资源 ----------
# 布局两套都收（与 pack-win-single.sh 同一口径）：老示例是工程根的 `ui/` + `capabilities/`；
# 新形态（`cj-tauri.toml` 清单 + 业务 static 包）放在 `assets/ui` + `assets/capabilities`，
# 也允许混搭（cookie-export 就是页面在 `assets/ui`、清单留在根）。构建副本按来源原样摆放，
# 应用侧的读盘兜底路径（如 `assets/ui/index.html`）因此仍然对得上。
UI_SRC="$EXAMPLE/ui"
[ -d "$UI_SRC" ] || UI_SRC="$EXAMPLE/assets/ui"
CAP_SRC="$EXAMPLE/capabilities"
[ -d "$CAP_SRC" ] || CAP_SRC="$EXAMPLE/assets/capabilities"
[ -d "$UI_SRC" ] || die "示例缺页面目录：$EXAMPLE/ui 与 $EXAMPLE/assets/ui 都不存在"
[ -d "$CAP_SRC" ] || die "示例缺能力清单目录：$EXAMPLE/capabilities 与 $EXAMPLE/assets/capabilities 都不存在"
cp -r "$EXAMPLE/src" "$WORK/app/"
if [ "$UI_SRC" = "$EXAMPLE/assets/ui" ]; then
    mkdir -p "$WORK/app/assets"
    cp -r "$UI_SRC" "$WORK/app/assets/ui"
    UI_REL="assets/ui"
else
    cp -r "$UI_SRC" "$WORK/app/"
    UI_REL="ui"
fi
# Vite 工程：依赖树不上产物（桌面链路读 dist/，鸿蒙 rawfile 同样跳过 node_modules）
rm -rf "$WORK/app/$UI_REL/node_modules"

# 页面文件：Vite 工程在 dist/index.html，内联单页在 index.html——单文件内嵌取构建产物
if [ -f "$WORK/app/$UI_REL/dist/index.html" ]; then
    UI_FILE="$WORK/app/$UI_REL/dist/index.html"
    PAGE_REL="$UI_REL/dist/index.html"
else
    UI_FILE="$WORK/app/$UI_REL/index.html"
    PAGE_REL="$UI_REL/index.html"
fi
[ -f "$UI_FILE" ] || die "示例缺前端页面: $UI_FILE"

PKG_NAME="$(awk -F'"' '/^[[:space:]]*name[[:space:]]*=/ {print $2; exit}' "$EXAMPLE/cjpm.toml")"
[ -n "$PKG_NAME" ] || die "读不到 $EXAMPLE/cjpm.toml 的 package.name"

ASSET_STUB="$EXAMPLE/src/packed_assets.cj"
[ -f "$ASSET_STUB" ] || die "示例还没接内嵌资源：缺 $ASSET_STUB"
has_asset() { grep -q "^public let $1" "$ASSET_STUB"; }
has_asset PACKED_UI_B64 || die "$ASSET_STUB 里没有 PACKED_UI_B64 存根"

b64() { base64 -w0 "$1"; }
UI_B64="$(b64 "$UI_FILE")"

VENDOR_B64=""
if has_asset PACKED_VENDOR_B64; then
    VENDOR_LIST_FILE="$WORK/app/$UI_REL/vendor/pack-files.txt"
    if [ -f "$VENDOR_LIST_FILE" ]; then
        VENDOR_FILES=()
        while IFS= read -r vline; do
            vline="${vline%$'\r'}"
            [ -n "$vline" ] && VENDOR_FILES+=("$vline")
        done < "$VENDOR_LIST_FILE"
        [ "${#VENDOR_FILES[@]}" -ge 1 ] || die "vendor 清单是空的：$VENDOR_LIST_FILE"
    else
        VENDOR_FILES=("$UI_REL/vendor/marked.min.js" "$UI_REL/vendor/highlight.min.js" \
            "$UI_REL/vendor/github-dark-dimmed.min.css" "$UI_REL/vendor/github-dark.min.css" "$UI_REL/vendor/atom-one-dark.min.css")
    fi
    for vf in "${VENDOR_FILES[@]}"; do
        vf_file="$WORK/app/$vf"
        [ -f "$vf_file" ] || die "存根声明了 PACKED_VENDOR_B64，但缺 $vf_file"
        vf_piece="$(b64 "$vf_file")"
        if [ -z "$VENDOR_B64" ]; then VENDOR_B64="$vf_piece"; else VENDOR_B64="$VENDOR_B64,$vf_piece"; fi
    done
fi

CAPS_B64=""
CAPS_N=0
for f in "$CAP_SRC"/*.json; do
    [ -f "$f" ] || continue
    piece="$(b64 "$f")"
    if [ -z "$CAPS_B64" ]; then CAPS_B64="$piece"; else CAPS_B64="$CAPS_B64,$piece"; fi
    CAPS_N=$((CAPS_N + 1))
done
[ "$CAPS_N" -ge 1 ] || die "capabilities/ 下没有 json：单文件包必须把清单编进去，否则命令全被拒"

echo "[winbuild] 生成内嵌资源：页面 ${#UI_B64} / vendor ${#VENDOR_B64} base64 字节，能力清单 $CAPS_N 份"
{
    printf 'package %s\n\n' "$PKG_NAME"
    printf '/* 由 scripts/winbuild.sh 生成：内嵌资源（标准 base64，无换行）。**不要手工编辑**。\n'
    printf '   常量非空即「内嵌模式」；仓库里的同名文件是空存根，正常构建仍按相对路径读盘。 */\n'
    printf 'public let PACKED_UI_B64: String = "%s"\n' "$UI_B64"
    if has_asset PACKED_VENDOR_B64; then
        printf 'public let PACKED_VENDOR_B64: String = "%s"\n' "$VENDOR_B64"
    fi
    printf 'public let PACKED_CAPS_B64: String = "%s"\n' "$CAPS_B64"
} > "$WORK/app/src/packed_assets.cj"

# ---------- ②a 新形态工程生成单文件入口 main() ----------
# 老形态示例自带 main()（页面由业务读）；新形态（cj-tauri.toml + 业务 static 包）只有 build()
# 装配点、页面归 launcher 按清单读盘——单文件包没有磁盘资产，得在这里生成一个 main()：
# 页面走 PACKED_UI_B64 内嵌（textOrFile 的内嵌分支），能力清单走 PACKED_CAPS_B64 →
# AppSpec.capabilityJson（launch 的 assemble 会逐条 addCapabilityJson，与显式挂载同一入口）。
if ! grep -rqlE "^main\(\)" "$WORK/app/src"; then
    echo "[winbuild] 新形态工程：生成单文件入口 main()（页面 $PAGE_REL）"
    {
        printf 'package %s\n\n' "$PKG_NAME"
        printf '/* 由 scripts/winbuild.sh 生成：单文件包的 main()。**不要手工编辑**。\n'
        printf '   页面/能力清单全部内嵌（PACKED_*），不再依赖磁盘上的 assets/ 与 capabilities/。 */\n'
        printf 'import cjTauri.*\n'
        printf 'import cjTauri.platform.*\n'
        printf 'import std.env.*\n'
        printf 'import std.fs.*\n\n'
        printf 'main(): Int64 {\n'
        printf '    let html = textOrFile(PACKED_UI_B64, "%s", "前端页面")\n' "$PAGE_REL"
        printf '    /* WebView2 的 NavigateToString 有 ~2MB 上限：实测 1.82MB 的页面 hr=0x80070057\n'
        printf '       （E_INVALIDARG，整页白屏），1.23MB 的正常——超阈值就把页面落盘走 file:// 导航\n'
        printf '       （cj_bridge_load_url 通道无尺寸限制；postMessage 从 file:// 照常到宿主）。 */\n'
        printf '    var spec: AppSpec\n'
        printf '    if (html.size > 1500000) {\n'
        printf '        let temp = getVariable("TEMP") ?? "."\n'
        printf '        let pagePath = temp + "\\\\cj-tauri-page-%s.html"\n' "$PKG_NAME"
        printf '        File.writeTo(pagePath, html.toArray())\n'
        printf '        let url = "file:///" + pagePath.replace("\\\\", "/")\n'
        printf '        eprintln("[app] 页面 ${html.size} 字节超内联上限，落盘走 file:// 导航：${url}")\n'
        printf '        spec = build().page(PageSource.Url(url))\n'
        printf '    } else {\n'
        printf '        spec = build().page(PageSource.Inline(html))\n'
        printf '    }\n'
        printf '    for (part in splitBy(PACKED_CAPS_B64, 44u8)) {\n'
        printf '        spec = spec.capabilityJson(decodeBase64(part))\n'
        printf '    }\n'
        printf '    launch(spec)\n'
        printf '    return 0\n'
        printf '}\n'
    } > "$WORK/app/src/packed_main.cj"
fi

# ---------- ②b 框架副本：按 stdx 版本决定是否打补丁 ----------
# 补丁针对 1.0.5.1（本机曾有唯一的 windows stdx）：ws 插件 import stdx.crypto.kit（DefaultCryptoKit
# 只做包初始化标记）与 TlsClientConfig.serverName（显式 SNI）都是 1.1+ API，1.0.5.1 没有；
# 而 1.0.5.1 的 http 栈没有 "Global crypto kit" 机制（libstdx.net.http.a 里无该报错串），摘掉等价。
# 1.2.0.1 起（AtomGit Cangjie/cangjie_stdx 公开直链可下）这两个 API 都在，**不打补丁**——
# 反过来在 1.2.0 的 http 栈上摘掉 kit 注册，ws 连接会运行时报 "Global crypto kit is not set"。
WORK_FRAMEWORK="$WORK/framework"
mkdir -p "$WORK_FRAMEWORK"
cp "$ROOT/cjpm.toml" "$WORK_FRAMEWORK/"
cp -r "$ROOT/src" "$WORK_FRAMEWORK/"
case "$WINDOWS_STDX" in
    *1.0.5.1*)
        WS_PLUGIN="$WORK_FRAMEWORK/src/plugins/ws/plugin_ws.cj"
        sed -i '/^import stdx.crypto.kit.\*/d; /kitMarker/d' "$WS_PLUGIN"
        # 校验只看代码行：文件头的注释原文里也引用了 stdx.crypto.kit 字样（stdx 的报错文案），不算数
        grep -n "stdx.crypto.kit" "$WS_PLUGIN" | grep -vE "^[0-9]+:[[:space:]]*//" | grep -q . && die "ws 插件副本补丁没打干净（仍有 stdx.crypto.kit 代码引用）"
        # 全副本删：http 与 ws 插件各有一处（http_desktop.cj / plugin_ws.cj），别按文件点名
        grep -rln "cfg\.serverName" "$WORK_FRAMEWORK/src" | while read -r f; do sed -i '/cfg\.serverName[[:space:]]*=/d' "$f"; done
        grep -rn "cfg\.serverName" "$WORK_FRAMEWORK/src" >/dev/null && die "serverName 副本补丁没打干净"
        echo "[winbuild] stdx 1.0.5.1：框架副本已打兼容补丁（crypto.kit / serverName）"
        ;;
    *)
        echo "[winbuild] stdx 1.2.0+：框架源码原样编译，不打补丁"
        ;;
esac

# ---------- ③ cjpm.toml 副本：静态链接三件套 + 静态桥（交叉 target 段） ----------
# 资源对象必须当链接输入直接给 ld.lld，不能塞进 libcjtbridge.a：静态库按需提取，资源对象
# 没有任何符号引用，放归档里链接器根本不取——那样打出的 exe 连 .rsrc 节都没有（AGENTS §4）
ASSET_LINK_ARG=""
if [ -n "$ASSET_OBJ" ]; then
    ASSET_LINK_ARG=" $WORK/bridge/pack_assets.o"
fi
# link-option 的系统库清单与 pack-win-single.sh 同款；-lws2_32 是 cjh winbuild 补的（winsock，
# stdx 的网络栈要）。crypt32：stdx.net.tls 读 Windows 证书库，碰 https 的示例必须链。
cat > "$WORK/app/cjpm.toml" <<TOML
[package]
  cjc-version = "1.0.5"
  name = "$PKG_NAME"
  version = "0.1.0"
  output-type = "executable"
  compile-option = "--static --static-std --static-libs"

[dependencies]
  cjTauri = { path = "$WORK_FRAMEWORK" }

[target.x86_64-w64-mingw32]
  link-option = "$BRIDGE_LIB$ASSET_LINK_ARG -L/usr/x86_64-w64-mingw32/lib -lole32 -loleaut32 -luuid -luser32 -lgdi32 -ladvapi32 -lcomdlg32 -lcrypt32 -lws2_32 $SUBSYS_ARG"

[target.x86_64-w64-mingw32.bin-dependencies]
    path-option = ["$WINDOWS_STDX"]
TOML

# ---------- ④ 交叉构建 + strip ----------
# CANGJIE_STDX 必须指 windows static 包：框架 cjpm.toml 的 bin-dependencies 按进程环境展开
# 这个变量，交叉构建时指 Linux 包就是给 lld 喂错架构的 import 库
export PATH="$CANGJIE_HOME/bin:$CANGJIE_HOME/tools/bin:$PATH"
export LD_LIBRARY_PATH="$CANGJIE_HOME/runtime/lib/linux_x86_64_cjnative:$CANGJIE_HOME/third_party/llvm/lib:${LD_LIBRARY_PATH:-}"
export CANGJIE_STDX="$WINDOWS_STDX"
echo "[winbuild] 交叉构建 $WORK/app（--target x86_64-w64-mingw32）"
( cd "$WORK/app" && cjpm build --target x86_64-w64-mingw32 )

BUILT="$WORK/app/target/x86_64-w64-mingw32/release/bin/main.exe"
[ -f "$BUILT" ] || die "没找到产物: $BUILT"

SIZE_RAW="$(stat -c%s "$BUILT")"
cp "$BUILT" "$EXE"
if x86_64-w64-mingw32-strip "$EXE" 2>/dev/null; then
    echo "[winbuild] strip: $SIZE_RAW → $(stat -c%s "$EXE") 字节"
else
    echo "[winbuild] 警告: strip 失败，保留未裁剪的 exe（$SIZE_RAW 字节）" >&2
fi

# ---------- ⑤ 自检：导入表 + 子系统（判据与 pack-win-single.sh 同款） ----------
FORBIDDEN="libcangjie-runtime.dll libcjtbridge.dll WebView2Loader.dll libboundscheck.dll"
BAD=""
for d in $FORBIDDEN; do
    if x86_64-w64-mingw32-objdump -p "$EXE" | awk '/DLL Name:/ {print $3}' | grep -qi "^$d$"; then
        BAD="$BAD $d"
    fi
done
if [ -n "$BAD" ]; then
    die "产物仍依赖:$BAD —— 静态链接没生效，检查 compile-option 与 link-option"
fi

SUBSYS=$(x86_64-w64-mingw32-objdump -p "$EXE" | grep -i "^Subsystem" | awk '{print $2}')
if [ "$SUBSYS" != "$SUBSYS_EXPECT" ]; then
    die "产物子系统是 $SUBSYS（应为 $SUBSYS_EXPECT）：link-option 里的 $SUBSYS_ARG 没生效"
fi

echo "[winbuild] 单文件: $EXE（$(du -h "$EXE" | cut -f1)）"
echo "[winbuild] 子系统: $SUBSYS ($SUBSYS_LABEL)"
echo "[winbuild] 导入的 DLL（应全是 Windows 系统库）:"
x86_64-w64-mingw32-objdump -p "$EXE" | awk '/DLL Name:/ {print "  " $3}'
