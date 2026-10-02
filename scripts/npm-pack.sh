#!/usr/bin/env bash
# npm-pack.sh — 把 cj-tauri 打成一个可发布的 npm 包（默认只打包、不发布）
#
# 为什么不直接在仓库根 `npm publish`：
#   1. 发布物必须是一棵「框架根同构」的树（cjpm.toml + src/ + native/ + cli/templates），
#      CLI 靠 CJ_TAURI_ROOT 指到这棵树来定位模板与框架源码；
#   2. 仓库里还有 docs/ examples/ scripts/ 这些不该进包的内容，以及 target/ 这类产物；
#   3. 包内预编译 CLI 走「打包时若本机有产物就带上」——二进制不入库，只进 tarball。
#
# 用法:
#   bash scripts/npm-pack.sh                        # 只打包，产出 dist-npm/cj-tauri-<版本>.tgz
#   bash scripts/npm-pack.sh --publish              # 打包后发布
#   bash scripts/npm-pack.sh --publish --otp 123456 # 带 2FA 动态码发布（见下）
#   bash scripts/npm-pack.sh --keep                 # 保留 dist-npm/ 里展开的目录树（排查用）
#
# 为什么发布常要 --otp：账号开了「写操作需 2FA」时，`npm login` 的浏览器登录态只证明「你是谁」，
# 发布仍要一次性动态码，否则 registry 直接回
#   E403 ... Two-factor authentication or granular access token with bypass 2fa enabled is required
# （`npm whoami` 正常并不代表能发布）。换不了动态码时，可临时用勾了 Bypass 2FA 的 granular token
# 写进用户级 ~/.npmrc（别进仓库），发完即删。动态码也可用环境变量 NPM_OTP 传，避免进 shell 历史。
#
# 前置：Node >= 18（打包与安装都用它），本机装了仓颉 SDK（首次构建 CLI 用）。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

DO_PUBLISH=0
KEEP=0
OTP="${NPM_OTP:-}"
while [ $# -gt 0 ]; do
  case "$1" in
    --publish) DO_PUBLISH=1 ;;
    --keep)    KEEP=1 ;;
    --otp)     OTP="${2:-}"; [ -n "$OTP" ] || { echo "[npm-pack] --otp 后面要跟 6 位动态码" >&2; exit 2; }; shift ;;
    --otp=*)   OTP="${1#--otp=}" ;;
    *) echo "[npm-pack] 未知参数: $1（支持 --publish / --keep / --otp <6 位码>）" >&2; exit 2 ;;
  esac
  shift
done
if [ -n "$OTP" ]; then
    case "$OTP" in
      [0-9][0-9][0-9][0-9][0-9][0-9]) ;;
      *) echo "[npm-pack] --otp / NPM_OTP 应是 6 位数字" >&2; exit 2 ;;
    esac
fi

# 发布固定走官方 registry：本机 npm 常配成镜像（如 registry.npmmirror.com），而镜像不接收 publish，
# 直接 `npm publish` 会报错或发到别处；要用私服/其他 registry 时用环境变量覆盖。
NPM_PUBLISH_REGISTRY="${NPM_PUBLISH_REGISTRY:-https://registry.npmjs.org/}"

toml_version() { grep -m1 -oE '^[[:space:]]*version[[:space:]]*=[[:space:]]*"[^"]+"' "$1" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+'; }
json_version() { grep -m1 -oE '"version"[[:space:]]*:[[:space:]]*"[0-9]+\.[0-9]+\.[0-9]+"' "$1" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+'; }

VERSION="$(toml_version cjpm.toml)"
PKG_VERSION="$(json_version npm/package.json)"
if [ -z "$VERSION" ] || [ "$VERSION" != "$PKG_VERSION" ]; then
    echo "[npm-pack] 版本不一致: cjpm.toml=${VERSION:-<未找到>} npm/package.json=${PKG_VERSION:-<未找到>}" >&2
    echo "           跑 bash scripts/check-version.sh 看全部位置" >&2
    exit 1
fi

DIST="$ROOT/dist-npm"
STAGE="$DIST/cj-tauri-$VERSION"
rm -rf "$DIST"
mkdir -p "$STAGE"

# 拷贝目录，排除依赖与构建产物：模板的 ui/node_modules 动辄几十 MB，绝不能进包
copy_tree() {
    local src="$1" dst="$2"
    mkdir -p "$dst"
    ( cd "$src" && tar -cf - \
        --exclude='./node_modules' --exclude='./target' \
        --exclude='./dist' --exclude='./webview2' \
        --exclude='*.so' --exclude='*.dll' --exclude='*.o' --exclude='*.a' . ) \
      | ( cd "$dst" && tar -xf - )
}

echo "[npm-pack] 组装包内容（版本 $VERSION）..."
# 1) 包元数据与启动器
cp npm/package.json "$STAGE/package.json"
copy_tree npm/bin "$STAGE/bin"
cp npm/README.md "$STAGE/README.md"
cp LICENSE "$STAGE/LICENSE"

# 2) 框架本体（与仓库根同构：包根即框架根）
cp cjpm.toml "$STAGE/cjpm.toml"
copy_tree src "$STAGE/src"
copy_tree native "$STAGE/native"

# 3) CLI 源码与模板（首次在本机构建 CLI 用；模板供 create 使用）
mkdir -p "$STAGE/cli"
cp cli/cjpm.toml "$STAGE/cli/cjpm.toml"
copy_tree cli/src "$STAGE/cli/src"
copy_tree cli/templates "$STAGE/cli/templates"

# 4) 预编译 CLI：本机有产物就带上（「优先预编译、缺失回落源码构建」的前半段）
PLATFORM="$(node -p 'process.platform + "-" + process.arch')"
case "$(uname -s 2>/dev/null || echo unknown)" in
    MINGW*|MSYS*|CYGWIN*) CLI_SRC="cli/target/release/bin/main.exe"; CLI_DST="cj-tauri.exe" ;;
    *)                    CLI_SRC="cli/target/release/bin/main";     CLI_DST="cj-tauri" ;;
esac
if [ -f "$CLI_SRC" ]; then
    mkdir -p "$STAGE/prebuilt/$PLATFORM"
    cp "$CLI_SRC" "$STAGE/prebuilt/$PLATFORM/$CLI_DST"
    chmod +x "$STAGE/prebuilt/$PLATFORM/$CLI_DST"
    echo "[npm-pack] 已带上预编译 CLI: prebuilt/$PLATFORM/$CLI_DST（$(du -h "$CLI_SRC" | cut -f1)）"
else
    echo "[npm-pack] 本机没有 CLI 产物，包内不带预编译二进制（用户首次运行会源码构建）"
fi

# 5) 打包
echo "[npm-pack] npm pack ..."
OUT="$(npm pack --pack-destination "$DIST" "$STAGE" | tail -1)"
if [ ! -f "$DIST/$OUT" ]; then
    echo "[npm-pack] 打包失败：没找到 $DIST/$OUT" >&2
    exit 1
fi
echo "[npm-pack] tarball: dist-npm/$OUT（$(du -h "$DIST/$OUT" | cut -f1)）"
echo "[npm-pack] 包内条目（前 25 条）："
tar -tzf "$DIST/$OUT" | sed 's|^package/|  |' | head -25

if [ "$KEEP" -eq 0 ]; then
    rm -rf "$STAGE"
fi

if [ "$DO_PUBLISH" -eq 1 ]; then
    # 登录预检：没登录就给出确切的登录命令，别让 npm 在 OTP 阶段报个不明所以的 ENEEDAUTH
    if ! npm whoami --registry="$NPM_PUBLISH_REGISTRY" >/dev/null 2>&1; then
        echo "[npm-pack] 还没登录 $NPM_PUBLISH_REGISTRY，先执行：" >&2
        echo "           npm login --registry=$NPM_PUBLISH_REGISTRY" >&2
        exit 1
    fi
    PUBLISH_ARGS=(publish "$DIST/$OUT" --access public --registry="$NPM_PUBLISH_REGISTRY")
    if [ -n "$OTP" ]; then
        PUBLISH_ARGS+=(--otp "$OTP")
        echo "[npm-pack] 发布到 $NPM_PUBLISH_REGISTRY（用传入的动态码过 2FA）..."
    else
        echo "[npm-pack] 发布到 $NPM_PUBLISH_REGISTRY（登录态不能写时会被 2FA 拦成 403，那就加 --otp <6 位码>）..."
    fi
    npm "${PUBLISH_ARGS[@]}"
    echo "[npm-pack] 已发布。核对: npm view cj-tauri version --registry=$NPM_PUBLISH_REGISTRY"
else
    echo "[npm-pack] 未发布。要发布请执行："
    echo "           npm publish dist-npm/$OUT --access public --registry=$NPM_PUBLISH_REGISTRY --otp=<6 位动态码>"
    echo "           （或：bash scripts/npm-pack.sh --publish --otp <6 位动态码>）"
    echo "           本地试装：npm i -g ./dist-npm/$OUT   （或 npm i ./dist-npm/$OUT 装进当前工程）"
fi
