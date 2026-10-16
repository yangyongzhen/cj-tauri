#!/usr/bin/env bash
# Linux 便携包打包：把某个示例（缺省 examples/ai-chat）打成「解压就能跑」的目录（+ 可选 tar.gz）。
#
# 用法:
#   bash scripts/pack-linux.sh                                # 打包 examples/ai-chat
#   bash scripts/pack-linux.sh examples/music                 # 打包别的示例
#   bash scripts/pack-linux.sh examples/ai-chat /tmp/out      # 指定输出根
#   CJH_BIN=/path/to/cjh bash scripts/pack-linux.sh examples/ai-chat   # 把 cjh 也打进包
#   bash scripts/pack-linux.sh examples/ai-chat --tar         # 顺带出 <包名>.tar.gz
#
# 产出的布局（目录名 = <示例名>-linux-x64）：
#   <包>/main                应用本体（由 target/release/bin/main 拷贝而来）
#   <包>/lib/*.so            随包共享库：仓颉运行时 + stdx + C 桥（ldd 解析出的、**不属于系统目录**的那些）
#   <包>/ui/index.html       页面（**按相对路径读**，必须与 main 同层）
#   <包>/capabilities/*.json 能力清单（同上；单文件包里它得编进二进制，目录包不用）
#   <包>/bin/cjh             可选：内含 cjh（`CJH_BIN=<路径>` 时才有），打包后可离线用
#   <包>/run.sh              启动：把工作目录切到包根、库路径指向包内 lib/、再拉起 main
#
# 与 pack-win.sh / pack-win-single.sh 的分工：Windows 可以做到「单文件 exe」（静态链 + 内嵌 loader），
# Linux **没有单文件形态**——产物动态依赖仓颉运行时 / stdx / libcjtbridge.so（本机 ldd 176 项、其中 40 多项
# 不在系统目录里），所以交付形态是**目录**：可执行文件 + 随包共享库。系统 WebKitGTK / GTK 不随包。
#
# 为什么依赖清单不靠手工维护：从 main 出发用 `ldd` 拿闭包（`*/native/*`、`*/cangjie/*`、`*/.cangjie/*`、
# `*/stdx/*` 四类之外的一律视为系统库）。手抄清单漏一个 stdx 传递依赖，表象是启动即退、stderr 一行
# `cannot open shared object file`（AGENTS §4 有这条的形状）。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

die() { echo "[pack-linux] $*" >&2; exit 1; }

case "$(uname -s)" in
    Linux) ;;
    *) die "本脚本只做 Linux 目录包（当前 $(uname -s)）；Windows 用 scripts/pack-win.sh / pack-win-single.sh" ;;
esac

# ---------- 参数 ----------
EXAMPLE=""; OUT_ROOT=""; WITH_TAR=0
for arg in "$@"; do
    case "$arg" in
        --tar) WITH_TAR=1 ;;
        --*) die "未知参数: $arg" ;;
        *) if [ -z "$EXAMPLE" ]; then EXAMPLE="$arg"; else OUT_ROOT="$arg"; fi ;;
    esac
done
EXAMPLE="${EXAMPLE:-examples/ai-chat}"
[ -d "$EXAMPLE" ] || die "示例不存在: $EXAMPLE"
# 取绝对路径：构建与 mtime 比较都在绝对路径上做（相对名比较会得到一个永不触发的检查，AGENTS §4）
EXAMPLE="$(cd "$EXAMPLE" && pwd)"
NAME="$(basename "$EXAMPLE")"
[ -n "$OUT_ROOT" ] || OUT_ROOT="$EXAMPLE/dist-linux"
PKG="$OUT_ROOT/$NAME-linux-x64"

# ---------- 环境 ----------
if [ -z "${CANGJIE_HOME:-}" ]; then
    for c in /opt/cangjie/cangjie "$HOME/cangjie"; do
        [ -d "$c" ] && { CANGJIE_HOME="$c"; break; }
    done
fi
[ -n "${CANGJIE_HOME:-}" ] || die "找不到仓颉 SDK，请设置 CANGJIE_HOME"
SDK_LIB="$CANGJIE_HOME/runtime/lib/linux_x86_64_cjnative"
[ -d "$SDK_LIB" ] || die "缺 SDK 运行时目录: $SDK_LIB"

# stdx：源码仓各 cjpm.toml 的 bin-dependencies 统一写 ${CANGJIE_STDX}（cjpm 按进程环境变量展开），
# 所以**先 export 再谈进 PATH**（AGENTS §4：探到了却不 export，报的却是「依赖没声明」）。
if [ -z "${CANGJIE_STDX:-}" ]; then
    for c in "$HOME"/.cangjie/stdx/*/dynamic/stdx /opt/cangjie/stdx/*/dynamic/stdx; do
        [ -d "$c" ] && { CANGJIE_STDX="$c"; break; }
    done
fi
[ -n "${CANGJIE_STDX:-}" ] || die "找不到 stdx 动态库目录（设 CANGJIE_STDX=<stdx>/<三元组>/dynamic/stdx）"
export CANGJIE_STDX

NATIVE="$ROOT/native"
[ -f "$NATIVE/libcjtbridge.so" ] || die "缺 C 桥产物 $NATIVE/libcjtbridge.so（先跑 bash native/build_linux.sh）"

# ---------- ① 构建（产物缺失或不新鲜时）----------
export PATH="$SDK_LIB:$CANGJIE_HOME/bin:$CANGJIE_HOME/tools/bin:$CANGJIE_HOME/tools/lib:$CANGJIE_STDX:$PATH"
export LD_LIBRARY_PATH="$NATIVE:$SDK_LIB:$CANGJIE_STDX${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
BIN="$EXAMPLE/target/release/bin/main"
if [ ! -f "$BIN" ]; then
    echo "[pack-linux] $NAME 还没有产物，先 cjpm build"
    ( cd "$EXAMPLE" && cjpm build )
fi
[ -f "$BIN" ] || die "构建后仍找不到产物: $BIN"

# 产物新鲜度：示例源码 / 框架源码 / 两份 cjpm.toml 里最新的那一个比产物新，就重编
# （只盯示例源码会漏掉框架改动，AGENTS §4 的那条假红就是这么来的）
newest=0
for f in "$EXAMPLE"/src/*.cj "$ROOT"/src/*.cj "$EXAMPLE/cjpm.toml" "$ROOT/cjpm.toml" "$NATIVE/libcjtbridge.so"; do
    [ -f "$f" ] || continue
    m="$(stat -c %Y "$f")"
    if [ "$m" -gt "$newest" ]; then newest="$m"; fi
done
if [ "$(stat -c %Y "$BIN")" -lt "$newest" ]; then
    echo "[pack-linux] 产物比源码旧，重新构建 $NAME"
    ( cd "$EXAMPLE" && cjpm build )
fi

# ---------- ② 依赖闭包：ldd 里不在系统目录的 .so ----------
LIBS="$(mktemp)"
trap 'rm -f "$LIBS"' EXIT
while IFS= read -r line; do
    p="$(printf '%s' "$line" | awk '/=>/{print $3} /^\t\//{print $1}')"
    [ -n "$p" ] || continue
    case "$p" in /*) ;; *) continue ;; esac          # 只认绝对路径（"not found" 之类跳过）
    case "$p" in
        */native/*|*/cangjie/*|*/.cangjie/*|*/stdx/*) printf '%s\n' "$p" ;;
    esac
done < <(ldd "$BIN" 2>/dev/null | sed 's/^[[:space:]]*//') > "$LIBS"

# 按真实路径去重：本机 /lib 与 /usr/lib 常是同一份（软链 / 合并 usr），同一个 .so 会被算两遍
LIBS_UNIQ="$(while IFS= read -r p; do readlink -f "$p"; done < "$LIBS" | sort -u)"
[ -n "$LIBS_UNIQ" ] || die "ldd 没解析出任何随包库——检查 LD_LIBRARY_PATH 与 C 桥产物"

# ---------- ③ 组装 ----------
rm -rf "$PKG"
mkdir -p "$PKG/lib" "$PKG/bin" "$OUT_ROOT"
cp "$BIN" "$PKG/main"
chmod +x "$PKG/main"
[ -d "$EXAMPLE/ui" ] || die "示例缺 ui/: $EXAMPLE/ui"
[ -d "$EXAMPLE/capabilities" ] || die "示例缺 capabilities/: $EXAMPLE/capabilities"
cp -r "$EXAMPLE/ui" "$PKG/ui"
cp -r "$EXAMPLE/capabilities" "$PKG/capabilities"

n_lib=0
while IFS= read -r p; do
    [ -n "$p" ] || continue
    cp -L "$p" "$PKG/lib/"
    n_lib=$((n_lib + 1))
done <<< "$LIBS_UNIQ"

# 存档（store.json）**默认不打**：里面是服务商 API Key，随包分发等于泄密。
# 只有在明确要造「本机自测副本」时才用 CJH_WITH_STORE=1 带上一份，脚本会打一行提醒。
if [ "${CJH_WITH_STORE:-0}" = "1" ] && [ -f "$EXAMPLE/store.json" ]; then
    cp "$EXAMPLE/store.json" "$PKG/store.json"
    echo "[pack-linux] 警告: 包内带了 store.json（含服务商 Key）——只可用于本机自测，不要对外分发" >&2
fi

# cjh（ai-chat 这类应用没有 cjh 就是个空壳）：三档定位
#   ① CJH_BIN 显式指定（开发用，指本机构建产物）
#   ② 示例自带的 vendor/cjh 里的 Linux 包（随仓分发；先按 SHA256SUMS 校验再解出，取版本最高的那份）
#   ③ 同机并列的 cjh 仓构建产物（本机出包顺手的回落）
# 解包发生在**打包期**而不是运行期：ai-chat 的能力清单里没有 fs:write / shell，应用自身没有
# 「把 tar.gz 落成可执行文件」的手段（要让它自己解包就得先扩能力位，代价比这大）。
CJH_IN=""
CJH_FROM=""
TMP_CJH=""
VENDOR="$EXAMPLE/vendor/cjh"
if [ -n "${CJH_BIN:-}" ]; then
    CJH_IN="$CJH_BIN"
    CJH_FROM="CJH_BIN 显式指定"
elif [ -d "$VENDOR" ]; then
    ARCHIVE="$(ls "$VENDOR"/cjh-v*-linux-x64.tar.gz 2>/dev/null | sort -V | tail -1 || true)"
    if [ -n "$ARCHIVE" ]; then
        if [ -f "$VENDOR/SHA256SUMS" ]; then
            ( cd "$VENDOR" && sha256sum -c --ignore-missing SHA256SUMS >/dev/null ) \
                || die "vendor/cjh 里的包与 SHA256SUMS 对不上：$(basename "$ARCHIVE")"
        else
            echo "[pack-linux] 提示: vendor/cjh 缺 SHA256SUMS，跳过校验" >&2
        fi
        TMP_CJH="$(mktemp -d)"
        tar xzf "$ARCHIVE" -C "$TMP_CJH"
        CJH_IN="$(ls "$TMP_CJH"/cjh* 2>/dev/null | head -1 || true)"
        [ -n "$CJH_IN" ] || die "从 $(basename "$ARCHIVE") 里没解出 cjh"
        CJH_FROM="vendor/cjh/$(basename "$ARCHIVE")"
    fi
fi
if [ -z "$CJH_IN" ] && [ -x "$ROOT/../cjh/target/release/bin/cjh" ]; then
    CJH_IN="$ROOT/../cjh/target/release/bin/cjh"
    CJH_FROM="同机 cjh 仓构建产物"
fi
HAS_CJH=0
if [ -n "$CJH_IN" ]; then
    [ -x "$CJH_IN" ] || die "cjh 不是可执行文件: $CJH_IN"
    cp "$CJH_IN" "$PKG/bin/cjh"
    chmod +x "$PKG/bin/cjh"
    [ -n "$TMP_CJH" ] && rm -rf "$TMP_CJH"
    # 留一行来源与哈希：包里的 cjh 是哪份、能不能对上 SHA256SUMS，事后可对账
    printf 'source=%s\nsha256=%s\n' "$CJH_FROM" "$(sha256sum "$PKG/bin/cjh" | cut -d' ' -f1)" > "$PKG/bin/cjh.src.txt"
    HAS_CJH=1
else
    case "$NAME" in
        ai-chat) echo "[pack-linux] 提示: 本示例没有 cjh 就是个空壳——往 vendor/cjh 放一份 Linux 包，或用 CJH_BIN=<cjh 路径>" >&2 ;;
    esac
fi

# 启动脚本：工作目录 = 包根（capabilities/、ui/、store.json 都是相对路径约定），
# 库路径指向包内 lib/，内置 cjh 时导出 ai-chat 认的那个变量。
{
    printf '#!/usr/bin/env bash\n'
    printf '# 由 scripts/pack-linux.sh 生成：切到包根 → 库路径指向包内 lib/ → 拉起 main。\n'
    printf '# 参数原样透传给 main；stderr 直接进终端（要用日志文件就设 CJ_TAURI_LOG=1）。\n'
    printf 'set -euo pipefail\n'
    printf 'HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"\n'
    printf 'cd "$HERE"\n'
    printf 'export LD_LIBRARY_PATH="$HERE/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"\n'
    if [ "$HAS_CJH" = "1" ]; then
        printf '# 内置 cjh：应用（ai-chat）会按这个变量 spawn 它；cjh 自己的配置与会话仍写在 ~/.cjh\n'
        printf 'export CJ_AICHAT_CJH="$HERE/bin/cjh"\n'
    fi
    printf 'exec "$HERE/main" "$@"\n'
} > "$PKG/run.sh"
chmod +x "$PKG/run.sh"

# ---------- ④ 自检：包外的依赖必须为 0、该有的文件都在、没有混进存档 ----------
MISSING="$(LD_LIBRARY_PATH="$PKG/lib" ldd "$PKG/main" 2>/dev/null | grep -c 'not found' || true)"
[ "$MISSING" = "0" ] || die "包内仍缺 $MISSING 个共享库——依赖闭包没收全（LD_LIBRARY_PATH=$PKG/lib ldd main 复核）"
[ -f "$PKG/ui/index.html" ] || die "包内缺 ui/index.html"
ls "$PKG"/capabilities/*.json >/dev/null 2>&1 || die "包内缺 capabilities/*.json"
[ -x "$PKG/run.sh" ] || die "包内缺可执行的 run.sh"
if [ -f "$PKG/store.json" ]; then
    echo "[pack-linux] 注意: 包内含 store.json（自测副本）" >&2
fi
if [ "$HAS_CJH" = "1" ]; then
    LD_LIBRARY_PATH="$PKG/lib" ldd "$PKG/bin/cjh" 2>/dev/null | grep -q 'not found' \
        && die "包内 cjh 缺共享库（cjh 本该自足，检查它的构建）"
fi

SIZE="$(du -sh "$PKG" | cut -f1)"
MAIN_B="$(stat -c %s "$PKG/main")"
LIB_B="$(du -sb "$PKG/lib" | cut -f1)"
echo "[pack-linux] 包: $PKG（$SIZE）"
echo "[pack-linux] main $(numfmt --to=iec "$MAIN_B") / lib $n_lib 个 $(numfmt --to=iec "$LIB_B")$([ "$HAS_CJH" = 1 ] && echo " / 含 cjh $(numfmt --to=iec "$(stat -c %s "$PKG/bin/cjh")")")"
echo "[pack-linux] main sha256: $(sha256sum "$PKG/main" | cut -c1-12)"
echo "[pack-linux] 启动: bash $PKG/run.sh"

if [ "$WITH_TAR" = "1" ]; then
    TAR="$OUT_ROOT/$NAME-linux-x64.tar.gz"
    rm -f "$TAR"
    ( cd "$OUT_ROOT" && tar czf "$TAR" "$NAME-linux-x64" )
    echo "[pack-linux] 归档: $TAR（$(du -h "$TAR" | cut -f1)）"
fi
