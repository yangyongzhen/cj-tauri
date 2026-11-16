#!/usr/bin/env bash
# ci-build-cli.sh — CI 上构建双平台静态 CLI（npm 预编译分发的产物生产步骤）
#
# 背景：用户机「首次运行都要本地编译 CLI，缺环境总失败」——解法是把 prebuilt/ 随 npm
# 包分发（cli/cjpm.toml 已静态化，产物不链仓颉运行时）。CI（ubuntu runner）用 SDK 自带的
# third_party/mingw 交叉出 Windows 产物，一个 runner 同时产出两份：
#   prebuilt/linux-x64/cj-tauri   （原生）
#   prebuilt/win32-x64/cj-tauri.exe（交叉）
#
# 前置环境：CANGJIE_SDK_URL / CANGJIE_STDX_URL（官方直链，匿名可下；由 GitHub secret 提供，
# 与 ci.yml 的 sdk 作业同源）。strip 由 npm-pack.sh 打包时做，这里只构建。
#
# 用法: bash scripts/ci-build-cli.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

fail() { echo "[ci-cli] 错误: $1" >&2; exit 1; }

: "${CANGJIE_SDK_URL:?需要 CANGJIE_SDK_URL（SDK 压缩包官方直链）}"
: "${CANGJIE_STDX_URL:?需要 CANGJIE_STDX_URL（stdx 压缩包官方直链）}"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# ---- 下载并展开 SDK / stdx（官方直链匿名可下，AGENTS §7）----
echo "[ci-cli] 下载 SDK ..."
curl -fsSL -o "$WORK/sdk.tar.gz" "$CANGJIE_SDK_URL"
mkdir -p "$WORK/sdk" "$HOME/.cangjie"
tar -xzf "$WORK/sdk.tar.gz" -C "$WORK/sdk"
# 压缩包内层目录名随版本而变，用 cjc 反查 SDK 根（与 ci.yml 的 sdk 作业同款写法）：
# cjc 在 <sdk>/bin/cjc，dirname/.. 即 SDK 根（含 bin/ 与 tools/）。
CJC="$(find "$WORK/sdk" -type f -name cjc | head -1)"
[ -n "$CJC" ] || fail "SDK 压缩包里找不到 cjc，包结构异常"
SDK_DIR="$(cd "$(dirname "$CJC")/.." && pwd)"
export CANGJIE_HOME="$SDK_DIR"
export PATH="$CANGJIE_HOME/bin:$CANGJIE_HOME/tools/bin:$PATH"
# cjpm / cjc 自身也是动态链接的，runtime 库目录必须进 LD_LIBRARY_PATH——
# 实测（CI 首跑 v2.4.4，2026-11-16）：只配 PATH 时 cjpm 起不来，报
# `cjpm: error while loading shared libraries: libcangjie-runtime.so`
RT_DIR="$(find "$CANGJIE_HOME/runtime/lib" -maxdepth 1 -type d -name 'linux_*' | head -1)"
[ -n "$RT_DIR" ] || fail "SDK 里找不到 runtime/lib/linux_* 目录"
export LD_LIBRARY_PATH="$RT_DIR:$CANGJIE_HOME/third_party/llvm/lib:${LD_LIBRARY_PATH:-}"
echo "[ci-cli] SDK: $CANGJIE_HOME（cjc $(cjc -v 2>/dev/null | head -1)）"

echo "[ci-cli] 下载 stdx ..."
curl -fsSL -o "$WORK/stdx.zip" "$CANGJIE_STDX_URL"
STDX_ZIP_NAME="$(basename "$CANGJIE_STDX_URL")"
mkdir -p "$HOME/.cangjie/stdx"
# stdx 分发可能是 zip（windows/linux 官方包）或 tar.gz
case "$STDX_ZIP_NAME" in
  *.zip) unzip -q -o "$WORK/stdx.zip" -d "$HOME/.cangjie/stdx" ;;
  *.tar.gz|*.tgz) tar -xzf "$WORK/stdx.zip" -C "$HOME/.cangjie/stdx" ;;
  *) fail "stdx 直链不是 zip/tar.gz: $STDX_ZIP_NAME" ;;
esac
# 探测解压后的 static 层：静态构建吃 .a（npm 启动器同口径）。**两个构建各用各的层**——
# linux 原生构建吃 linux static，交叉构建（--target x86_64-w64-mingw32）吃 windows static；
# 实测（2026-11-16）：用同一个全局 CANGJIE_STDX 跑两个构建时，交叉链接拿 linux 的 ELF 库
# 链 mingw 目标，报一片 `ld.lld: error: unknown file type: encoding.json.o`。
STDX_LINUX="$(find "$HOME/.cangjie/stdx" -type d -path '*static/stdx' | grep -i linux | head -1)"
STDX_WIN="$(find "$HOME/.cangjie/stdx" -type d -path '*static/stdx' | grep -i windows | head -1)"
[ -n "$STDX_LINUX" ] || fail "解压后没找到 linux 的 static/stdx 层"
[ -n "$STDX_WIN" ] || fail "解压后没找到 windows 的 static/stdx 层（交叉构建用）"
export CANGJIE_STDX="$STDX_LINUX"
echo "[ci-cli] CANGJIE_STDX(linux)=$STDX_LINUX"
echo "[ci-cli] CANGJIE_STDX(win) =$STDX_WIN"

# stdx 的版本必须与 cjc 同代（AGENTS §4：混配能编、能链，产物跑不动）——按主次版本比对。
# 只对路径里带 cangjie-stdx-<版本> 包名的层比对（官方 zip 解压的形状）；本机手工解压出
# 的裸 <triple>/static/stdx 目录没有版本信息，跳过（爬目录层取「包名」对两种布局层数不同，
# 实测 2026-11-16 会取到 triple 名误报不配套）。
CJC_VER="$(cjc -v 2>/dev/null | grep -oE '[0-9]+\.[0-9]+' | head -1)"
for _layer in "$STDX_LINUX" "$STDX_WIN"; do
  if echo "$_layer" | grep -q 'cangjie-stdx-' && [ -n "$CJC_VER" ] \
     && ! echo "$_layer" | grep -q "${CJC_VER%.*}"; then
    fail "cjc $CJC_VER 与 stdx 包（$_layer）主次版本不配套——静态产物能编能链但跑不动，先换配套 stdx 直链"
  fi
done

# ---- 双平台静态构建 ----
echo "[ci-cli] 构建 linux-x64（静态）..."
( cd cli && cjpm build )
[ -f cli/target/release/bin/main ] || fail "linux 产物缺失（看产物，别只看 build success）"
./cli/target/release/bin/main --version

echo "[ci-cli] 构建 win32-x64（交叉，静态）..."
( cd cli && CANGJIE_STDX="$STDX_WIN" cjpm build --target x86_64-w64-mingw32 )
[ -f cli/target/x86_64-w64-mingw32/release/bin/main.exe ] || fail "windows 交叉产物缺失"
file cli/target/x86_64-w64-mingw32/release/bin/main.exe

# 静态判据：导入表只剩系统库（AGENTS §4「应用调 cjc 编出来的东西要交付别的机器必须静态链接」）
echo "[ci-cli] 导入表复核（不得出现 libcangjie-*）："
objdump -p cli/target/release/bin/main | grep 'NEEDED' || true
NEEDED_CJ="$(objdump -p cli/target/release/bin/main | grep -c 'libcangjie' || true)"
[ "$NEEDED_CJ" = "0" ] || fail "linux 产物动态链接了仓颉运行时（静态三件套没生效）"

echo "[ci-cli] 双平台构建完成"
