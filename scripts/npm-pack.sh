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
# （`npm whoami` 正常并不代表能发布）。2FA 绑的是验证器 App 就用 App 里的 6 位码（30 秒一换）；
# 一个未用过的**恢复码**也能当 OTP 提交——registry 的 npm-otp 字段两者都收。拿不到码时（例如只绑了
# 安全密钥/passkey），可临时用勾了 Bypass 2FA 的 granular token 写进用户级 ~/.npmrc（别进仓库），
# 发完即删。码也可用环境变量 NPM_OTP 传，避免进 shell 历史。
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
    --otp)     OTP="${2:-}"; [ -n "$OTP" ] || { echo "[npm-pack] --otp 后面要跟动态码" >&2; exit 2; }; shift ;;
    --otp=*)   OTP="${1#--otp=}"; [ -n "$OTP" ] || { echo "[npm-pack] --otp= 后面要跟动态码" >&2; exit 2; } ;;
    *) echo "[npm-pack] 未知参数: $1（支持 --publish / --keep / --otp <6 位码>）" >&2; exit 2 ;;
  esac
  shift
done
if [ -n "$OTP" ]; then
    case "$OTP" in
      [0-9][0-9][0-9][0-9][0-9][0-9]) ;;                    # 验证器 App 的 TOTP
      *[!A-Za-z0-9_-]*|?|??|???|????|?????)                 # 含非法字符，或长度不足 6
          echo "[npm-pack] --otp / NPM_OTP 应是 6 位动态码，或一个未用过的恢复码" >&2
          exit 2 ;;
      *) ;;                                                 # 6 位以上字母数字：按恢复码放行
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

# 3b) Windows TLS 依赖（issue #16-③）：仓颉 stdx 的 TLS 按名字加载 libcrypto/libssl-3-x64.dll，
#     SDK 与 stdx 都不带（AGENTS §4）。包内带上（绕过 copy_tree 的 *.dll 排除），
#     npm 安装器把它们落到 CLI 可执行文件旁边——没有它们，`sign --login` 全断。
if [ -f vendor/openssl/libcrypto-3-x64.dll ] && [ -f vendor/openssl/libssl-3-x64.dll ]; then
    mkdir -p "$STAGE/vendor/openssl"
    cp vendor/openssl/libcrypto-3-x64.dll vendor/openssl/libssl-3-x64.dll "$STAGE/vendor/openssl/"
    echo "[npm-pack] 已带上 Windows TLS 依赖: vendor/openssl/{libcrypto,libssl}-3-x64.dll"
else
    echo "[npm-pack] 警告: vendor/openssl/ 缺 OpenSSL DLL，包内不带 Windows TLS 依赖（sign --login 会挂）" >&2
fi

# 4) 预编译 CLI：本机有产物就带上（「优先预编译、缺失回落源码构建」的前半段）。
#    双平台（2026-11-16）：本机原生产物 + Windows 交叉产物（cjpm build --target
#    x86_64-w64-mingw32 的标准落点）。预编译是**静态**产物（cli/cjpm.toml 的
#    compile-option --static --static-std），没装 SDK 的用户机拿到就能跑——
#    这正是「Windows 下首次使用都要本地编译、缺环境总失败」的解法。
strip_prebuilt() {
    # strip 失败不致命（产物大一点），但**不能静默**：2.4.4 实测 exe 分支两个工具都没
    # 命中时产物 34MB 原样进包，日志里零线索。按产物形态探测：exe 用 mingw strip /
    # SDK 自带的 llvm-objcopy（对 PE 等效，实测 34MB→10MB），ELF 用 strip。
    local f="$1"
    local llvm_objcopy="${CANGJIE_HOME:-/opt/cangjie/cangjie}/third_party/llvm/bin/llvm-objcopy"
    if [[ "$f" == *.exe ]]; then
        if command -v x86_64-w64-mingw32-strip >/dev/null 2>&1; then
            x86_64-w64-mingw32-strip "$f" 2>/dev/null || echo "[npm-pack] 警告: mingw-strip 失败（产物未裁剪）: $f" >&2
        elif [ -x "$llvm_objcopy" ]; then
            "$llvm_objcopy" --strip-all "$f" || echo "[npm-pack] 警告: llvm-objcopy 失败（产物未裁剪）: $f" >&2
        else
            echo "[npm-pack] 警告: 找不到 mingw-strip 与 llvm-objcopy（\$CANGJIE_HOME=$CANGJIE_HOME），exe 不裁剪: $f" >&2
        fi
    else
        strip "$f" 2>/dev/null || echo "[npm-pack] 警告: strip 失败（产物未裁剪）: $f" >&2
    fi
}

pack_prebuilt() {   # $1=产物路径 $2=平台键(linux-x64/win32-x64) $3=落名
    local src="$1" plat="$2" dst="$3"
    mkdir -p "$STAGE/prebuilt/$plat"
    cp "$src" "$STAGE/prebuilt/$plat/$dst"
    chmod +x "$STAGE/prebuilt/$plat/$dst"
    strip_prebuilt "$STAGE/prebuilt/$plat/$dst"
    echo "[npm-pack] 已带上预编译 CLI: prebuilt/$plat/$dst（strip 后 $(du -h "$STAGE/prebuilt/$plat/$dst" | cut -f1)）"
}

PLATFORM="$(node -p 'process.platform + "-" + process.arch')"
case "$(uname -s 2>/dev/null || echo unknown)" in
    MINGW*|MSYS*|CYGWIN*) CLI_SRC="cli/target/release/bin/main.exe"; CLI_DST="cj-tauri.exe" ;;
    *)                    CLI_SRC="cli/target/release/bin/main";     CLI_DST="cj-tauri" ;;
esac
PACKED_ANY=0
if [ -f "$CLI_SRC" ]; then
    PACKED_ANY=1
    # 版本一致性守卫：预编译 CLI 是「上一次构建的产物」，包版本升了却没重编 cli/ 时，
    # 它会在用户机器上自报旧版本号（实测 2026-10-23：1.1.1 的 tarball 里躺着 1.1.0 的 exe，
    # 用户装完 `npx cj-tauri --version` 回 1.1.0，看着像装错了包）。这里先按产物自报的版本核对。
    CLI_REPORTED="$("$CLI_SRC" --version 2>/dev/null | tail -1 | awk '{print $NF}')" || CLI_REPORTED=""
    if [ -z "$CLI_REPORTED" ]; then
        echo "[npm-pack] 警告：跑不动 $CLI_SRC，无法核对它自报的版本" >&2
        echo "            （多半是缺仓颉运行时库，先按 envsetup 把 SDK 的 bin/runtime 配进 PATH）" >&2
    elif [ "$CLI_REPORTED" != "$VERSION" ]; then
        echo "[npm-pack] 预编译 CLI 版本不符：产物自报 ${CLI_REPORTED}，包版本 ${VERSION}" >&2
        echo "           先在 cli/ 里 cjpm build 重编（版本号写在源码里，重编才会带上新的），再重新打包" >&2
        exit 1
    else
        echo "[npm-pack] 预编译 CLI 版本核对通过：${CLI_REPORTED}"
    fi
    pack_prebuilt "$CLI_SRC" "$PLATFORM" "$CLI_DST"
fi
# Windows 交叉产物（在非 Windows 主机上交叉构建；Windows 主机的本机产物已走上面的原生分支）。
# exe 在 Linux 上跑不了、做不了自报版本核对——与原生产物同一构建会话产出，信任流程顺序
# （CI 里两步连续执行；本机打包请先跑 cli/ 的两个构建再打包）。
CROSS_WIN_EXE="cli/target/x86_64-w64-mingw32/release/bin/main.exe"
if [ "${PACKED_ANY}" -eq 1 ] && [ "$(node -p 'process.platform')" != "win32" ] && [ -f "$CROSS_WIN_EXE" ]; then
    pack_prebuilt "$CROSS_WIN_EXE" "win32-x64" "cj-tauri.exe"
fi
if [ "${PACKED_ANY}" -eq 0 ]; then
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
# 不用 `sed | head`：head 关闭管道后 sed 的 flush 得 EPIPE（退出码 4 / SIGPIPE 141），
# 把已成功的打包步骤判死（GitHub Actions v2.1.1 首跑实测，tgz 明明已经生成）。
# awk 把清单读完再打印，没有截断。
tar -tzf "$DIST/$OUT" | awk 'NR <= 25 { sub(/^package\//, "  "); print }'

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
