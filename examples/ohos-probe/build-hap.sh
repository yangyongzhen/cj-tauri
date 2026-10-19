#!/usr/bin/env bash
# 鸿蒙 HAP 构建入口（ohos-probe 示例）
#
# 用法：bash build-hap.sh
#
# 前置：
#   1. 装了 DevEco Studio 6.1（自带 hvigor 与 node）；安装根默认 D:\oh\DevEcoStudio，
#      不在那儿就 export DEVECO_WIN=<安装根>（Windows 形式，hvigor 自己要这种路径）。
#   2. 装了鸿蒙版 stdx，并 export CANGJIE_STDX_OHOS=<stdx>/linux_ohos_aarch64_cjnative/dynamic/stdx
#      —— 缺它 cjpm 会报成「框架缺依赖」，看着像 cjpm.toml 少写了一条（AGENTS §4 有这条坑）。
set -e

# 环境里可能预置着另一份 DevEco 的路径（本机就有 D:\Program Files\Huawei\DevEco Studio\sdk
# 这种不存在的旧值），hvigor 会直接判「Invalid value of 'DEVECO_SDK_HOME'」——
# 给了但目录不存在就回退到 DEVECO_WIN 下，并说明忽略了谁。
pick_deveco_path() {
    local cand="$1" fb="$2"
    if [ -n "$cand" ] && [ -d "$(cygpath -u "$cand")" ]; then
        printf '%s' "$cand"
        return 0
    fi
    [ -n "$cand" ] && echo "[ohos-probe] 忽略无效路径：$cand，改用 $fb" >&2
    printf '%s' "$fb"
}

DEVECO_WIN="${DEVECO_WIN:-D:\\oh\\DevEcoStudio}"
# 注意分隔符：hvigor 会校验 DEVECO_SDK_HOME，混合斜杠（D:\oh\DevEcoStudio/sdk）会被判
# 「Invalid value of 'DEVECO_SDK_HOME'」——给 hvigor 的一律全反斜杠，给 bash 起进程的走 cygpath。
export DEVECO_SDK_HOME="$(pick_deveco_path "${DEVECO_SDK_HOME:-}" "$DEVECO_WIN\\sdk")"
export NODE_HOME="$(pick_deveco_path "${NODE_HOME:-}" "$DEVECO_WIN\\tools\\node")"

: "${CANGJIE_STDX_OHOS:?请先 export CANGJIE_STDX_OHOS=<鸿蒙版 stdx>/linux_ohos_aarch64_cjnative/dynamic/stdx}"

cd "$(dirname "$0")"

# hvigor 拿的是 Windows 形式的环境变量，bash 这边起 node 用 POSIX 形式（MSYS 只认后者）
dev_posix="$(cygpath -u "$DEVECO_WIN")"
node_exe="$dev_posix/tools/node/node.exe"
hvigor_js="$dev_posix/tools/hvigor/bin/hvigorw.js"

# 仓颉插件的位置由 hvigorw 自己按这个顺序找：hvigor-config.json5 的 dependencies →
# CANGJIE_BUILD_SUPPORT_PATH → DevEco 安装根 → DEVECO_CANGJIE_PATH → DEVECO_HVIGOR_CANGJIE_PLUGIN，
# 找到后它自己把工程 node_modules/@ohos 下的 junction 建起来（不用手工 mklink）。
# DevEco IDE 构建时是 IDE 喂这些变量的；headless 从命令行起就必须自己给，
# 否则 hvigor 报的是 schema 不认识 entry/build-profile.json5 的 buildOption.cangjieOptions
# （「property name must be valid」），看着像工程配置写错，实际是插件没被加载。
if [ -z "${DEVECO_HVIGOR_CANGJIE_PLUGIN:-}" ]; then
    appdata_posix="$(cygpath -u "${APPDATA:-$USERPROFILE\\AppData\\Roaming}")"
    cjb="$(ls -d "$appdata_posix"/Huawei/DevEcoStudio*/plugins/devecostudio-cangjie-plugin-*/lib/hvigor/cangjie-build-support 2>/dev/null | head -1)"
    if [ -n "$cjb" ]; then
        export DEVECO_HVIGOR_CANGJIE_PLUGIN="$(cygpath -w "$cjb")"
    else
        echo "[ohos-probe] 找不到仓颉构建插件（DevEco 用户目录 plugins/devecostudio-cangjie-plugin-*/lib/hvigor/cangjie-build-support），请手动 export DEVECO_HVIGOR_CANGJIE_PLUGIN=<该目录>" >&2
        exit 1
    fi
fi

# entry/cjpm.toml 里 stdx 那条留的是 ${CANGJIE_STDX_OHOS} 占位符，必须在这里落地：
# hvigor 起的 cjpm **不展开进程环境变量**（同一份 toml 直接跑 cjpm 时是展开的，别被这点骗了），
# 占位符会变成空串，而空串会让整条 path-option 一起失效，报错却是
# 「imports package 'stdx.encoding.json' ... not added as a dependency」。
# 替换值用 cygpath -m（D:/… 正斜杠）：cjpm 认它，也避开 sed 替换串里反斜杠的转义。
toml=entry/cjpm.toml
if grep -q 'CANGJIE_STDX_OHOS' "$toml"; then
    stdx_mixed="$(cygpath -m "$CANGJIE_STDX_OHOS")"
    cp "$toml" "$toml.orig"
    trap 'mv -f "$toml.orig" "$toml"' EXIT INT TERM
    sed -i "s|\\\${CANGJIE_STDX_OHOS}|$stdx_mixed|g" "$toml"
fi

"$node_exe" "$hvigor_js" --mode module -p product=default -p module=entry@default assembleHap
