#!/usr/bin/env bash
# {{PROJECT_NAME}} —— 鸿蒙 PC（2in1）HAP 构建入口
#
# 用法：
#   bash build-hap.sh              编 hap（产物 entry/build/default/outputs/default/*.hap）
#   bash build-hap.sh --install    编完后装到设备并拉起（需要设备已连上且应用已签名）
#   bash build-hap.sh --clean      先删 entry/build 再编（改了 CJ 代码却没生效时用）
#
# 前置（三道，缺哪道都只会得到一句误导性的报错，所以脚本里逐条前置检查）：
#   1. DevEco Studio 6.1+（自带 hvigor 与 node）。安装根默认探测几个常见位置，
#      不在那儿就 export DEVECO_WIN=<安装根，Windows 形式>。
#   2. 鸿蒙版 stdx：export CANGJIE_STDX_OHOS=<stdx>/linux_ohos_aarch64_cjnative/dynamic/stdx
#      —— 缺它 cjpm 会报成「框架缺依赖」，看着像 cjpm.toml 少写了一条。
#   3. 签名：模板不随包分发证书。**在 DevEco 里** File → Project Structure → Signing Configs
#      勾「Automatically generate signature」（要登录华为账号）。不签也能 assembleHap，
#      产物是 *-unsigned.hap，但装不进设备（hdc install 会报 9568289 之类的签名错误）。
set -e

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
do_install=0
do_clean=0
for arg in "$@"; do
    case "$arg" in
        --install) do_install=1 ;;
        --clean) do_clean=1 ;;
        -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
        *) echo "[ohos] 未知参数：$arg（支持 --install / --clean / --help）" >&2; exit 2 ;;
    esac
done

cd "$ROOT_DIR"

# 环境里可能预置着另一份 DevEco 的路径（有的机器留着 D:\Program Files\Huawei\DevEco Studio\sdk
# 这种不存在的旧值），hvigor 会直接判「Invalid value of 'DEVECO_SDK_HOME'」——
# 给了但目录不存在就回退到 DEVECO_WIN 下，并说明忽略了谁。
pick_deveco_path() {
    local cand="$1" fb="$2"
    if [ -n "$cand" ] && [ -d "$(cygpath -u "$cand")" ]; then
        printf '%s' "$cand"
        return 0
    fi
    [ -n "$cand" ] && echo "[ohos] 忽略无效路径：$cand，改用 $fb" >&2
    printf '%s' "$fb"
}

# DevEco 安装根探测：DEVECO_WIN 优先，否则试几个常见位置，都不行就报一句能照做的错。
find_deveco() {
    if [ -n "${DEVECO_WIN:-}" ]; then
        printf '%s' "$DEVECO_WIN"
        return 0
    fi
    local cand
    for cand in \
        "D:\\oh\\DevEcoStudio" \
        "C:\\Program Files\\Huawei\\DevEco Studio" \
        "D:\\Program Files\\Huawei\\DevEco Studio" \
        "C:\\Program Files (x86)\\Huawei\\DevEco Studio"; do
        if [ -d "$(cygpath -u "$cand")/tools/hvigor" ]; then
            printf '%s' "$cand"
            return 0
        fi
    done
    return 1
}

if ! DEVECO_WIN="$(find_deveco)"; then
    echo "[ohos] 找不到 DevEco Studio。请 export DEVECO_WIN=<安装根，Windows 形式>" >&2
    echo "       例：export DEVECO_WIN='D:\\Program Files\\Huawei\\DevEco Studio'" >&2
    exit 1
fi
export DEVECO_WIN
# 注意分隔符：hvigor 会校验这两个变量，混合斜杠会被判「Invalid value」。
export DEVECO_SDK_HOME="$(pick_deveco_path "${DEVECO_SDK_HOME:-}" "$DEVECO_WIN\\sdk")"
export NODE_HOME="$(pick_deveco_path "${NODE_HOME:-}" "$DEVECO_WIN\\tools\\node")"

: "${CANGJIE_STDX_OHOS:?请先 export CANGJIE_STDX_OHOS=<鸿蒙版 stdx>/linux_ohos_aarch64_cjnative/dynamic/stdx}"

# hvigor 拿的是 Windows 形式的环境变量，bash 这边起 node 用 POSIX 形式（MSYS 只认后者）
dev_posix="$(cygpath -u "$DEVECO_WIN")"
node_exe="$dev_posix/tools/node/node.exe"
hvigor_js="$dev_posix/tools/hvigor/bin/hvigorw.js"
if [ ! -f "$hvigor_js" ]; then
    echo "[ohos] $hvigor_js 不存在——DEVECO_WIN 指对了没？" >&2
    exit 1
fi

# 仓颉插件的位置由 hvigorw 自己按顺序找，找到后它自己把工程 node_modules/@ohos 下的 junction
# 建起来（不用手工 mklink）。headless 从命令行起必须自己给，否则报的是
# 「property name must be valid: cangjieOptions」——看着像工程配置写错，其实是插件没被加载。
if [ -z "${DEVECO_HVIGOR_CANGJIE_PLUGIN:-}" ]; then
    appdata_posix="$(cygpath -u "${APPDATA:-$USERPROFILE\\AppData\\Roaming}")"
    cjb="$(ls -d "$appdata_posix"/Huawei/DevEcoStudio*/plugins/devecostudio-cangjie-plugin-*/lib/hvigor/cangjie-build-support 2>/dev/null | head -1)"
    if [ -n "$cjb" ]; then
        export DEVECO_HVIGOR_CANGJIE_PLUGIN="$(cygpath -w "$cjb")"
    else
        echo "[ohos] 找不到仓颉构建插件（DevEco 用户目录 plugins/devecostudio-cangjie-plugin-*/lib/hvigor/cangjie-build-support）" >&2
        echo "       请 export DEVECO_HVIGOR_CANGJIE_PLUGIN=<该目录>" >&2
        exit 1
    fi
fi

# 插件「能 require 到」≠「被判定为已启用」：未启用时它会主动把 cangjie 的 schema 删掉且不报错
# （终端只剩 00303038 一行）。两个开关都给上。
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
    echo "[ohos] 找不到仓颉运行库目录（$cjsdk_rt），cjpm 会以 0xC0000139 退出" >&2
    echo "       请 export CANGJIE_SDK=<.cangjie-sdk/<版本>/cangjie>" >&2
fi

# cjc 与 opt 必须来自**同一套** SDK：cjc 按 CANGJIE_HOME 找 opt，PATH 上钉 cjc 而 CANGJIE_HOME
# 指向桌面 SDK 时会出现「1.1.3 的 cjc + 1.2.0 的 opt」→ EnumReflection format: operand numbers error!
if [ -d "$cjsdk_bin" ]; then
    export PATH="$cjsdk_bin:$cjsdk_tools_bin:$PATH"
    export CANGJIE_HOME="$(cygpath -w "$CANGJIE_SDK/build-tools")"
    echo "[ohos] cjc = $(command -v cjc 2>/dev/null) ($(cjc --version 2>/dev/null | head -1))"
    echo "[ohos] CANGJIE_HOME = $CANGJIE_HOME"
fi

# entry/cjpm.toml 里 stdx 那条写相对路径 "../stdx"，指向**工程根上的 stdx 联接**：
# hvigor 只替换它自己的模板变量（${AARCH64_LIBS} 那组），写别的 ${...} 会变空串，
# 而空串让整条 path-option 一起失效（报错却是「not added as a dependency」，像漏配）。
stdx_link="$ROOT_DIR/stdx"
if [ ! -e "$stdx_link" ]; then
    stdx_src="$(cygpath -u "$CANGJIE_STDX_OHOS")"
    if [ ! -d "$stdx_src" ]; then
        echo "[ohos] CANGJIE_STDX_OHOS 指向的目录不存在：$CANGJIE_STDX_OHOS" >&2
        exit 1
    fi
    if command -v cmd >/dev/null 2>&1; then
        cmd //c mklink //J "$(cygpath -w "$stdx_link")" "$(cygpath -w "$stdx_src")" >/dev/null || {
            echo "[ohos] 建 stdx 联接失败：$stdx_link -> $stdx_src" >&2
            exit 1
        }
    else
        ln -s "$stdx_src" "$stdx_link"
    fi
    echo "[ohos] 已建 stdx 联接：$stdx_link -> $stdx_src"
fi

# 改了鸿蒙侧 CJ 代码却没生效时先怀疑产物：hvigor 的 CompileCangjie 与框架侧 cjpm **各有一份**
# 增量缓存，只清一边会把旧 .so 喂回来，对照实验当场失真（判据看产物尺寸，不看 build success）。
if [ "$do_clean" = "1" ]; then
    echo "[ohos] 清理 entry/build 与框架 target/（--clean）"
    rm -rf "$ROOT_DIR/entry/build"
fi

# assets 同步：唯一真相在工程根 assets/（RFC-002 §7），构建前拷进骨架 rawfile——
# 页面与能力清单是 hap 的 rawfile 真文件，只改 assets 不 sync 直接构建会装出**旧页**：
# 页面自检照跑、改动静默丢失（2026-10-25 真机实测，探针行全无、又无失败行）。
# 有 sync 生成的工程根（cj-tauri.toml 在上三级）才做这一步；手工工程自行维护 rawfile。
APP_ROOT="$ROOT_DIR/../.."
if [ -f "$APP_ROOT/cj-tauri.toml" ] && [ -d "$APP_ROOT/assets" ]; then
    RAWFILE="$ROOT_DIR/entry/src/main/resources/rawfile"
    mkdir -p "$RAWFILE/ui" "$RAWFILE/capabilities"
    # 先清再拷：cp -r src dst 在 dst 已存在时会把 src 拷成 dst/ui/ui/（嵌套目录），页面静默变旧
    rm -rf "$RAWFILE/ui" "$RAWFILE/capabilities"
    cp -r "$APP_ROOT/assets/ui" "$RAWFILE/ui"
    cp -r "$APP_ROOT/assets/capabilities" "$RAWFILE/capabilities"
    echo "[ohos] assets 已从工程根同步到 rawfile（ui/ + capabilities/）"
fi

# **必须 `--no-daemon`**：hvigor 的常驻 daemon 里 CompileCangjie 用的是它启动时那份 env，
# 本脚本 export 的 PATH / CANGJIE_HOME 根本进不去（表现是「手跑 cjpm 成功、hvigor 一跑就 opt 崩」）。
mkdir -p .buildlog
"$node_exe" "$hvigor_js" --no-daemon --mode module -p product=default -p module=entry@default assembleHap 2>&1 | tee .buildlog/last-build.log

hap="$(ls -t "$ROOT_DIR"/entry/build/default/outputs/default/*.hap 2>/dev/null | head -1)"
if [ -z "$hap" ]; then
    echo "[ohos] 构建结束但没有 hap 产物，请查 .buildlog/last-build.log" >&2
    exit 1
fi
echo "[ohos] HAP = $hap ($(wc -c < "$hap") 字节)"
case "$hap" in
    *unsigned*)
        echo "[ohos] 注意：这是未签名包，不能装进设备。在 DevEco 里配好自动签名后重编。" >&2
        do_install=0
        ;;
esac

if [ "$do_install" = "1" ]; then
    hdc="$dev_posix/sdk/default/openharmony/toolchains/hdc.exe"
    if [ ! -f "$hdc" ]; then
        echo "[ohos] 找不到 hdc：$hdc（--install 需要它；也可 export PATH 自带 hdc）" >&2
        exit 1
    fi
    echo "[ohos] 已连设备："
    "$hdc" list targets
    echo "[ohos] 安装 $hap"
    # 路径交给 hdc 前一律 MSYS_NO_PATHCONV：Git Bash 会把 Windows 路径改写成 /d/… 形式，
    # hdc 拿到就找不到文件。
    MSYS_NO_PATHCONV=1 "$hdc" install -r "$(cygpath -w "$hap")"
    echo "[ohos] 启动 EntryAbility"
    # -a 要用 module.json5 里的 ability 名（EntryAbility），不是仓颉类名 MainAbility。
    "$hdc" shell aa start -a EntryAbility -b {{BUNDLE_NAME}}
fi
