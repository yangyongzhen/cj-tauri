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

# 插件「能 require 到」和插件「被判定为已启用」是两件事，必须都满足：
#   - require("@ohos/cangjie-build-support/index") 的解析起点是 **hvigor 安装目录**
#     （node 会对工程内 junction 做 realpath），所以给 NODE_PATH 才能解析到；
#   - 仅解析到还不够：插件里 isPluginEnabled() 为假时，handleCangjieSchema() 会走 deleteSchema()
#     ——**主动把 cangjie 的 schema 删掉且不报错**，终端只剩
#     『00303038 Configuration Error … propertyName: 'cangjieOptions'』，真因只在
#     <工程>/.hvigor/outputs/build-logs/build.log（debug 级）。
# 启用判定的开关是环境变量（DEVECO_CANGJIE_PATH 指向含 oh-uni-package.json 的 SDK 根，
# 或 DEVECO_CANGJIE_PLUGIN_ENABLED=true），这里直接给后者。
export DEVECO_CANGJIE_PLUGIN_ENABLED=true
export NODE_PATH="$(cygpath -w "$(pwd)/node_modules")"

# 鸿蒙 SDK 自带的 cjpm.exe（1.1.3）**硬依赖 libcangjie-runtime.dll**，而这份 DLL 在
# <SDK>/build-tools/runtime/lib/windows_x86_64_cjnative 里、不在 cjpm.exe 旁边；缺它时
# hvigor 只报 `01101000 Tools execution failed.`，底层退出码是 0xC0000139
# （STATUS_ENTRYPOINT_NOT_FOUND，命令 21ms 就「跑完」），日志里才看得到真命令行。
# 注意：往 PATH 里塞桌面 SDK 的运行时**不管用**（那是另一代 ABI），必须用 SDK 自带的这份。
CANGJIE_SDK="${CANGJIE_SDK:-$(ls -d "$HOME"/.cangjie-sdk/*/cangjie 2>/dev/null | sort -V | tail -1)}"
cjsdk_rt="$CANGJIE_SDK/build-tools/runtime/lib/windows_x86_64_cjnative"
if [ -d "$cjsdk_rt" ]; then
    export PATH="$cjsdk_rt:$PATH"
else
    echo "[ohos-probe] 找不到仓颉运行库目录（$cjsdk_rt），cjpm 会以 0xC0000139 退出；请 export CANGJIE_SDK=<.cangjie-sdk/<版本>/cangjie>" >&2
fi

# entry/cjpm.toml 里 stdx 那条写的是相对路径 "../stdx"，指向**工程根上的 stdx 联接**。
# 为什么不是占位符：hvigor 只替换它自己的模板变量（${AARCH64_LIBS} 那组），写别的 ${...}
# 会被替换成空串，而空串会让整条 path-option 一起失效，报错却是
# 「imports package 'stdx.encoding.json' ... not added as a dependency」，看着像 cjpm.toml 漏配。
# 为什么不是本机绝对路径：换机器要改文件，而且 DevEco IDE 里点 Build 不经过本脚本。
# 相对路径 + 本机联接两处都通用：脚本负责在缺联接时按 CANGJIE_STDX_OHOS 建出来。
stdx_link="$(pwd)/stdx"
if [ ! -e "$stdx_link" ]; then
    : "${CANGJIE_STDX_OHOS:?工程根上没有 stdx 联接，请先 export CANGJIE_STDX_OHOS=<鸿蒙版 stdx>/linux_ohos_aarch64_cjnative/dynamic/stdx}"
    stdx_src="$(cygpath -u "$CANGJIE_STDX_OHOS")"
    if [ ! -d "$stdx_src" ]; then
        echo "[ohos-probe] CANGJIE_STDX_OHOS 指向的目录不存在：$CANGJIE_STDX_OHOS" >&2
        exit 1
    fi
    if command -v cmd >/dev/null 2>&1; then
        # Windows：用 junction（不需要管理员权限，也不占空间）
        cmd //c mklink //J "$(cygpath -w "$stdx_link")" "$(cygpath -w "$stdx_src")" >/dev/null || {
            echo "[ohos-probe] 建 stdx 联接失败：" "$stdx_link -> $stdx_src" >&2
            exit 1
        }
    else
        ln -s "$stdx_src" "$stdx_link"
    fi
    echo "[ohos-probe] 已建 stdx 联接：$stdx_link -> $stdx_src"
fi

"$node_exe" "$hvigor_js" --mode module -p product=default -p module=entry@default assembleHap
