#!/usr/bin/env bash
# 鸿蒙 HAP 构建入口（examples/ohos/ohos-movie）
#
# 用法：bash build-hap.sh          # 同步业务层 + 编 hap
#       bash build-hap.sh --no-sync  # 跳过同步（改了鸿蒙侧代码、movie 那边没动时更快）
#
# 与 ohos-probe/build-hap.sh 的差别只有一处「多了一步同步」：
#   examples/movie/src/*.cj  →  entry/src/main/cangjie/movielib/（改包名，生成物不入库）
#   examples/movie/ui/index.html + capabilities/*.json → movielib/ohos_assets.cj（base64 内嵌）
# 其余（DevEco 路径探测、cjc/opt 同代、stdx 联接、--no-daemon）与探针逐字一致，
# 理由见那些注释与 docs/鸿蒙ArkWeb接入踩坑.md。
#
# 前置：
#   1. 装了 DevEco Studio 6.1（自带 hvigor 与 node）；安装根默认 D:\oh\DevEcoStudio，
#      不在那儿就 export DEVECO_WIN=<安装根>（Windows 形式，hvigor 自己要这种路径）。
#   2. 装了鸿蒙版 stdx，并 export CANGJIE_STDX_OHOS=<stdx>/linux_ohos_aarch64_cjnative/dynamic/stdx
#      —— 缺它 cjpm 会报成「框架缺依赖」，看着像 cjpm.toml 少写了一条（AGENTS §4 有这条坑）。
set -e

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
MOVIE_DIR="$ROOT_DIR/../../movie"
GEN_DIR="$ROOT_DIR/entry/src/main/cangjie/movielib"

# 环境里可能预置着另一份 DevEco 的路径（本机就有 D:\Program Files\Huawei\DevEco Studio\sdk
# 这种不存在的旧值），hvigor 会直接判「Invalid value of 'DEVECO_SDK_HOME'」——
# 给了但目录不存在就回退到 DEVECO_WIN 下，并说明忽略了谁。
pick_deveco_path() {
    local cand="$1" fb="$2"
    if [ -n "$cand" ] && [ -d "$(cygpath -u "$cand")" ]; then
        printf '%s' "$cand"
        return 0
    fi
    [ -n "$cand" ] && echo "[ohos-movie] 忽略无效路径：$cand，改用 $fb" >&2
    printf '%s' "$fb"
}

DEVECO_WIN="${DEVECO_WIN:-D:\\oh\\DevEcoStudio}"
# 注意分隔符：hvigor 会校验 DEVECO_SDK_HOME，混合斜杠会被判「Invalid value」。
export DEVECO_SDK_HOME="$(pick_deveco_path "${DEVECO_SDK_HOME:-}" "$DEVECO_WIN\\sdk")"
export NODE_HOME="$(pick_deveco_path "${NODE_HOME:-}" "$DEVECO_WIN\\tools\\node")"

cd "$ROOT_DIR"

# ── 同步第 1 步：业务层（命令层逐字沿用 examples/movie，只换包名）──────────────────
sync_movie_sources() {
    if [ ! -d "$MOVIE_DIR/src" ]; then
        echo "[ohos-movie] 找不到 examples/movie/src，无法同步业务层" >&2
        exit 1
    fi
    mkdir -p "$GEN_DIR"
    local n=0
    for f in "$MOVIE_DIR"/src/*.cj; do
        local base
        base="$(basename "$f")"
        # main.cj 是桌面装配（main() 起进程、读 ui/ 与 capabilities/），鸿蒙侧由
        # entry 的 movie_host.cj 承担同样职责，所以不带过来。
        if [ "$base" = "main.cj" ]; then
            continue
        fi
        # 只改包声明一行：`package movie_app` → `package ohos_app_cangjie_entry.movielib`
        sed 's/^package movie_app$/package ohos_app_cangjie_entry.movielib/' "$f" > "$GEN_DIR/$base"
        n=$((n + 1))
    done
    echo "[ohos-movie] 已同步业务层 ${n} 个文件 -> entry/src/main/cangjie/movielib/"

    # ── 同步第 2 步：页面与能力清单（hap 里没有 ui/ 与 capabilities/，只能内嵌）──────
    local page="$MOVIE_DIR/ui/index.html"
    if [ ! -f "$page" ]; then
        echo "[ohos-movie] 找不到页面 $page" >&2
        exit 1
    fi
    local page_b64 caps_b64
    page_b64="$(base64 -w0 "$page")"
    caps_b64="$(base64 -w0 "$MOVIE_DIR/capabilities/default.json")"
    {
        echo "package ohos_app_cangjie_entry.movielib"
        echo
        echo '/*'
        echo ' * **生成物，不要手改**：build-hap.sh 从 examples/movie 的两份源文件编出本文件。'
        echo ' *'
        echo ' * 为什么页面要 base64 而不是直接写成三引号/raw string：'
        echo ' * ① 三引号会先吃反斜杠转义（AGENTS §4），页面里的 JS 正则与换行会被拆断；'
        echo ' * ② raw string 的收尾符是 " + #，而页面里 `color="#fff"` 这种字符序列一抓一大把，'
        echo ' *    原样写进去会让字符串在第一个颜色值处提前收尾。'
        echo ' * 解码复用 movielib 自己的 decodeBase64（与桌面单文件包同一条路）。'
        echo ' */'
        echo
        printf 'let OHOS_MOVIE_PAGE_B64: String = "%s"\n\n' "$page_b64"
        printf 'let OHOS_MOVIE_CAPS_B64: String = "%s"\n\n' "$caps_b64"
        echo '/** 前端页面（examples/movie/ui/index.html 的 base64 解码结果） */'
        echo 'public func ohosMoviePageHtml(): String {'
        echo '    return decodeBase64(OHOS_MOVIE_PAGE_B64)'
        echo '}'
        echo
        echo '/** 能力清单（examples/movie/capabilities/default.json 原文） */'
        echo 'public func ohosMovieCapsJson(): String {'
        echo '    return decodeBase64(OHOS_MOVIE_CAPS_B64)'
        echo '}'
    } > "$GEN_DIR/ohos_assets.cj"
    echo "[ohos-movie] 已生成内嵌资源：页面 base64 ${#page_b64} 字节，能力清单 base64 ${#caps_b64} 字节"
}

if [ "${1:-}" = "--no-sync" ]; then
    echo "[ohos-movie] 跳过同步（--no-sync）"
else
    sync_movie_sources
fi

: "${CANGJIE_STDX_OHOS:?请先 export CANGJIE_STDX_OHOS=<鸿蒙版 stdx>/linux_ohos_aarch64_cjnative/dynamic/stdx}"

# hvigor 拿的是 Windows 形式的环境变量，bash 这边起 node 用 POSIX 形式（MSYS 只认后者）
dev_posix="$(cygpath -u "$DEVECO_WIN")"
node_exe="$dev_posix/tools/node/node.exe"
hvigor_js="$dev_posix/tools/hvigor/bin/hvigorw.js"

# 仓颉插件的位置由 hvigorw 自己按顺序找，找到后它自己把工程 node_modules/@ohos 下的 junction
# 建起来（不用手工 mklink）。headless 从命令行起必须自己给，否则报的是
# 「property name must be valid: cangjieOptions」——看着像工程配置写错，其实是插件没被加载。
if [ -z "${DEVECO_HVIGOR_CANGJIE_PLUGIN:-}" ]; then
    appdata_posix="$(cygpath -u "${APPDATA:-$USERPROFILE\\AppData\\Roaming}")"
    cjb="$(ls -d "$appdata_posix"/Huawei/DevEcoStudio*/plugins/devecostudio-cangjie-plugin-*/lib/hvigor/cangjie-build-support 2>/dev/null | head -1)"
    if [ -n "$cjb" ]; then
        export DEVECO_HVIGOR_CANGJIE_PLUGIN="$(cygpath -w "$cjb")"
    else
        echo "[ohos-movie] 找不到仓颉构建插件（DevEco 用户目录 plugins/devecostudio-cangjie-plugin-*/lib/hvigor/cangjie-build-support），请手动 export DEVECO_HVIGOR_CANGJIE_PLUGIN=<该目录>" >&2
        exit 1
    fi
fi

# 插件「能 require 到」≠「被判定为已启用」：未启用时 handleCangjieSchema() 走 deleteSchema()，
# 主动把 cangjie 的 schema 删掉且不报错（终端只剩 00303038）。两个开关都给上。
export DEVECO_CANGJIE_PLUGIN_ENABLED=true
export NODE_PATH="$(cygpath -w "$(pwd)/node_modules")"

# SDK 自带的 cjpm.exe 硬依赖 libcangjie-runtime.dll（不在 cjpm.exe 旁边，在 runtime/lib 下）：
# 缺它 hvigor 只报 01101000，底层退出码 0xC0000139，21ms 就「跑完」。
CANGJIE_SDK="${CANGJIE_SDK:-$(ls -d "$HOME"/.cangjie-sdk/*/cangjie 2>/dev/null | sort -V | tail -1)}"
cjsdk_rt="$CANGJIE_SDK/build-tools/runtime/lib/windows_x86_64_cjnative"
cjsdk_bin="$CANGJIE_SDK/build-tools/bin"
cjsdk_tools_bin="$CANGJIE_SDK/build-tools/tools/bin"
if [ -d "$cjsdk_rt" ]; then
    export PATH="$cjsdk_rt:$PATH"
else
    echo "[ohos-movie] 找不到仓颉运行库目录（$cjsdk_rt），cjpm 会以 0xC0000139 退出；请 export CANGJIE_SDK=<.cangjie-sdk/<版本>/cangjie>" >&2
fi

# cjc 与 opt 必须来自**同一套** SDK：cjc 按 CANGJIE_HOME 找 opt，PATH 上钉 cjc 而 CANGJIE_HOME
# 指向桌面 SDK 时会出现「1.1.3 的 cjc + 1.2.0 的 opt」→ EnumReflection format: operand numbers error!
if [ -d "$cjsdk_bin" ]; then
    export PATH="$cjsdk_bin:$cjsdk_tools_bin:$PATH"
    export CANGJIE_HOME="$(cygpath -w "$CANGJIE_SDK/build-tools")"
    echo "[ohos-movie] cjc = $(command -v cjc 2>/dev/null) ($(cjc --version 2>/dev/null | head -1))"
    echo "[ohos-movie] CANGJIE_HOME = $CANGJIE_HOME"
    echo "[ohos-movie] opt = $(command -v opt 2>/dev/null || echo "<不在 PATH>")"
else
    echo "[ohos-movie] 找不到仓颉编译器目录（$cjsdk_bin），编鸿蒙包会退化成 PATH 上任意一个 cjc" >&2
fi

# entry/cjpm.toml 里 stdx 那条写相对路径 "../stdx"，指向**工程根上的 stdx 联接**：
# hvigor 只替换它自己的模板变量（${AARCH64_LIBS} 那组），写别的 ${...} 会变空串，
# 而空串让整条 path-option 一起失效（报错却是「not added as a dependency」，像漏配）。
stdx_link="$(pwd)/stdx"
if [ ! -e "$stdx_link" ]; then
    : "${CANGJIE_STDX_OHOS:?工程根上没有 stdx 联接，请先 export CANGJIE_STDX_OHOS=<鸿蒙版 stdx>/linux_ohos_aarch64_cjnative/dynamic/stdx}"
    stdx_src="$(cygpath -u "$CANGJIE_STDX_OHOS")"
    if [ ! -d "$stdx_src" ]; then
        echo "[ohos-movie] CANGJIE_STDX_OHOS 指向的目录不存在：$CANGJIE_STDX_OHOS" >&2
        exit 1
    fi
    if command -v cmd >/dev/null 2>&1; then
        cmd //c mklink //J "$(cygpath -w "$stdx_link")" "$(cygpath -w "$stdx_src")" >/dev/null || {
            echo "[ohos-movie] 建 stdx 联接失败：" "$stdx_link -> $stdx_src" >&2
            exit 1
        }
    else
        ln -s "$stdx_src" "$stdx_link"
    fi
    echo "[ohos-movie] 已建 stdx 联接：$stdx_link -> $stdx_src"
fi

# **必须 `--no-daemon`**：hvigor 的常驻 daemon 里 CompileCangjie 用的是它启动时那份 env，
# 本脚本 export 的 PATH / CANGJIE_HOME 根本进不去（表现为「手跑 cjpm 成功、hvigor 一跑就 opt 崩」）。
mkdir -p .buildlog
"$node_exe" "$hvigor_js" --no-daemon --mode module -p product=default -p module=entry@default assembleHap 2>&1 | tee .buildlog/last-build.log
