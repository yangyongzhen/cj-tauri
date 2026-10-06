#!/usr/bin/env bash
# Windows 便携包打包：把某个示例（缺省 examples/movie）打成「解压就能跑」的目录 + zip。
#
# 用法:
#   bash scripts/pack-win.sh                       # 打包 examples/movie
#   bash scripts/pack-win.sh examples/hello        # 打包别的示例
#   bash scripts/pack-win.sh examples/movie /tmp/out
#
# 产出的布局（目录名 = <示例名>-win-x64）：
#   <包>/movie.exe          应用本体（由 target/release/bin/main.exe 改名而来）
#   <包>/*.dll              运行期依赖：仓颉运行时 + stdx + C 桥 + WebView2 加载器
#   <包>/ui/index.html      页面（**按相对路径读**，必须与 exe 同层）
#   <包>/capabilities/*.json 能力清单（同上）
#   <包>/run.bat            双击启动（先把工作目录切到包根，再把 stderr 落盘）
#
# 为什么要收 DLL 而不是只丢个 exe：Windows 的 exe 链接的是**动态**仓颉运行时与 stdx，
# 用户机器上没有 SDK；而 libcjtbridge.dll 是 LoadLibraryW 按名字找 WebView2Loader.dll 的
# （见 native/bridge_win.c），所以这两层依赖都必须落在 exe 旁边。
# 依赖清单不靠手工维护——从 main.exe 出发递归解析 PE 导入表拿到闭包，避免漏 stdx 传递依赖。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

EXAMPLE="${1:-examples/movie}"
OUT_ROOT="${2:-$EXAMPLE/dist-win}"

# Windows 下把 D:\a\b、D:/a/b 统一成 /d/a/b（PATH 里混进盘符形式会让原生进程 exit 127）
to_posix() {
    local p="$1"
    if command -v cygpath >/dev/null 2>&1; then
        cygpath -u "$p"
    else
        printf '%s' "$p" | sed 's|\\|/|g; s|^\([A-Za-z]\):|/\L\1|'
    fi
}

if [ -z "${CANGJIE_HOME:-}" ]; then
    for c in "/d/Program Files (x86)/Cangjie" "/opt/cangjie/cangjie"; do
        [ -d "$c" ] && { CANGJIE_HOME="$c"; break; }
    done
fi
[ -n "${CANGJIE_HOME:-}" ] || { echo "[pack] 找不到仓颉 SDK，请设置 CANGJIE_HOME" >&2; exit 1; }
[ -z "${CANGJIE_STDX:-}" ] && CANGJIE_STDX="/d/cangjie-stdx/windows_x86_64_cjnative/dynamic/stdx"

case "$(uname -s)" in
    MINGW*|MSYS*|CYGWIN*)
        CANGJIE_HOME="$(to_posix "$CANGJIE_HOME")"
        CANGJIE_STDX="$(to_posix "$CANGJIE_STDX")"
        ;;
    *)
        echo "[pack] 本脚本只处理 Windows 包（当前 $(uname -s)）；Linux 用系统 WebKitGTK，不用这种方式打包" >&2
        exit 1
        ;;
esac

SDK_LIB="$CANGJIE_HOME/runtime/lib/windows_x86_64_cjnative"
NATIVE="$ROOT/native"
NAME="$(basename "$EXAMPLE")"
PKG="$OUT_ROOT/$NAME-win-x64"

# libwinpthread-1.dll 之类的 mingw 运行时不在 SDK 里，但 stdx 的 FFI 动态库会导入它
# （实测 libstdx.net.tlsFFI.dll）——所以把 mingw 的 bin 目录也纳入依赖搜索路径。
MINGW_BIN=""
if command -v objdump >/dev/null 2>&1; then
    MINGW_BIN="$(dirname "$(command -v objdump)")"
fi

[ -d "$EXAMPLE" ] || { echo "[pack] 示例目录不存在: $EXAMPLE" >&2; exit 1; }
[ -d "$SDK_LIB" ] || { echo "[pack] 缺 SDK 运行库目录: $SDK_LIB" >&2; exit 1; }
[ -f "$NATIVE/libcjtbridge.dll" ] || { echo "[pack] 缺 native/libcjtbridge.dll，先跑 native\\build_win.bat" >&2; exit 1; }
[ -f "$NATIVE/webview2/WebView2Loader.dll" ] || { echo "[pack] 缺 native/webview2/WebView2Loader.dll" >&2; exit 1; }

# 1) 构建应用（仓颉运行时 DLL 得在 PATH 里，否则 cjpm 起不来）
export PATH="$SDK_LIB:$CANGJIE_HOME/bin:$CANGJIE_HOME/tools/bin:$CANGJIE_HOME/tools/lib:$CANGJIE_STDX:$NATIVE:$NATIVE/webview2:$PATH"
echo "[pack] 构建: $EXAMPLE"
(cd "$EXAMPLE" && cjpm build)

APP="$EXAMPLE/target/release/bin/main.exe"
[ -f "$APP" ] || { echo "[pack] 没找到产物: $APP" >&2; exit 1; }

rm -rf "$PKG" "$OUT_ROOT/$NAME-win-x64.zip"
mkdir -p "$PKG"

# 2) exe + 资源（ui/ 与 capabilities/ 是相对 cwd 读的，必须同层保留）
cp "$APP" "$PKG/$NAME.exe"
for d in ui capabilities; do
    [ -d "$EXAMPLE/$d" ] && cp -r "$EXAMPLE/$d" "$PKG/$d"
done

# 3) 递归收 DLL 闭包。
#    系统 DLL（kernel32 / api-ms-win-crt-* 之类）由 Windows 提供，不收；
#    WebView2Loader.dll 是运行期 LoadLibrary 的，导入表里没有，单独补上。
is_system_dll() {
    case "$(printf '%s' "$1" | tr 'A-Z' 'a-z')" in
        api-ms-win-*|ext-ms-*) return 0 ;;
        kernel32.dll|user32.dll|ole32.dll|oleaut32.dll|comdlg32.dll|shell32.dll|shlwapi.dll) return 0 ;;
        msvcrt.dll|ucrtbase.dll|ntdll.dll|advapi32.dll|gdi32.dll|winmm.dll|version.dll) return 0 ;;
        ws2_32.dll|dbghelp.dll|crypt32.dll|bcrypt.dll|imm32.dll|uxtheme.dll|dwmapi.dll) return 0 ;;
        propsys.dll|d3d11.dll|dxgi.dll|setupapi.dll|userenv.dll|secur32.dll|normaliz.dll) return 0 ;;
        *) return 1 ;;
    esac
}

resolve_dll() {
    local n="$1" d
    for d in "$NATIVE" "$NATIVE/webview2" "$SDK_LIB" "$CANGJIE_STDX" "$(dirname "$APP")" $MINGW_BIN; do
        [ -n "$d" ] && [ -f "$d/$n" ] && { printf '%s' "$d/$n"; return 0; }
    done
    return 1
}

if ! command -v objdump >/dev/null 2>&1; then
    echo "[pack] 没有 objdump（mingw-w64），退化为「整目录拷贝」" >&2
    cp "$SDK_LIB"/*.dll "$CANGJIE_STDX"/*.dll "$PKG/" 2>/dev/null || true
    cp "$NATIVE/libcjtbridge.dll" "$NATIVE/webview2/WebView2Loader.dll" "$PKG/"
else
    worklist=("$APP")
    seen=""
    while [ ${#worklist[@]} -gt 0 ]; do
        cur="${worklist[0]}"
        worklist=("${worklist[@]:1}")
        while IFS= read -r name; do
            [ -n "$name" ] || continue
            is_system_dll "$name" && continue
            case " $seen " in *" $name "*) continue ;; esac
            seen="$seen $name"
            if ! path="$(resolve_dll "$name")"; then
                echo "[pack] 警告: 依赖 $name 在 SDK / native 里都没找到，跳过" >&2
                continue
            fi
            cp "$path" "$PKG/$name"
            worklist+=("$path")
        done < <(objdump -p "$cur" 2>/dev/null | awk '/DLL Name:/ {print $3}')
    done
    # 运行期按名字 LoadLibrary 的加载器（不在导入表里）
    cp "$NATIVE/libcjtbridge.dll" "$PKG/libcjtbridge.dll"
    cp "$NATIVE/webview2/WebView2Loader.dll" "$PKG/WebView2Loader.dll"
    echo "[pack] 收了 $(ls "$PKG"/*.dll | wc -l) 个 DLL"
fi

# 3.5) OpenSSL：仓颉的 TLS 也走 dynamicLoader，按名字 LoadLibraryW 找
#      libssl-3-x64.dll / libcrypto-3-x64.dll（strings 里能看到这两个名字），而 **SDK 与 stdx 都不带**。
#      开发机上 https 能通，多半是 PATH 上恰好有（本机来自 DevEco 的 Huawei\* 目录）；
#      便携包必须自带，否则症状很隐蔽：窗口照起、页面照加载、http 接口照 200，只有 https 全灭——
#      日志形如 `TlsException: Can not load openssl library or function CRYPTO_get_ex_new_index.`
OPENSSL_NAMES="libssl-3-x64.dll libcrypto-3-x64.dll"
openssl_dirs() {
    # ① 加载器自己的覆盖开关 ② PATH ③ 常见安装位置（含 DevEco / HarmonyOS 工具链带的那套）
    [ -n "${STDX_OPENSSL_SSL_FILE:-}" ] && dirname "$STDX_OPENSSL_SSL_FILE"
    [ -n "${STDX_OPENSSL_CRYPTO_FILE:-}" ] && dirname "$STDX_OPENSSL_CRYPTO_FILE"
    printf '%s\n' "$PATH" | tr ':' '\n' | grep -v '^$' || true
    printf '%s\n' \
        "/c/Program Files/Huawei/AppGallery" \
        "/c/Program Files/Huawei/BasicService" \
        "/c/Program Files/OpenSSL/bin" \
        "/c/OpenSSL/bin" \
        "$CANGJIE_HOME/bin" "$CANGJIE_HOME/tools/bin"
    if command -v cygpath >/dev/null 2>&1; then
        ls -d /c/Program\ Files/OpenSSL* 2>/dev/null || true
    fi
}

OPENSSL_MISSING=""
for n in $OPENSSL_NAMES; do
    [ -f "$PKG/$n" ] && continue
    found=""
    while IFS= read -r d; do
        [ -n "$d" ] && [ -f "$d/$n" ] && { found="$d/$n"; break; }
    done < <(openssl_dirs)
    if [ -z "$found" ]; then
        # 兜底：在工具链 / 程序目录里浅层找一遍（找不到只警告，别让打包失败）
        found="$(find "/c/Program Files" /c/tool -maxdepth 4 -iname "$n" 2>/dev/null | head -1 || true)"
    fi
    if [ -n "$found" ]; then
        cp "$found" "$PKG/$n"
        echo "[pack] OpenSSL: $n <- $found"
        # 单层补齐它自己的依赖（OpenSSL 3 的这两个 DLL 只依赖系统库）
        while IFS= read -r dep; do
            [ -n "$dep" ] || continue
            is_system_dll "$dep" && continue
            [ -f "$PKG/$dep" ] && continue
            if p="$(resolve_dll "$dep")"; then cp "$p" "$PKG/$dep"; fi
        done < <(objdump -p "$found" 2>/dev/null | awk '/DLL Name:/ {print $3}')
    else
        OPENSSL_MISSING="$OPENSSL_MISSING $n"
    fi
done
if [ -n "$OPENSSL_MISSING" ]; then
    echo "[pack] 警告: 没在构建机上找到$OPENSSL_MISSING" >&2
    echo "[pack]       => 这个包只能跑 http；https 会报 TlsException。" >&2
    echo "[pack]       装 OpenSSL 3 (x64) 或设 STDX_OPENSSL_SSL_FILE / STDX_OPENSSL_CRYPTO_FILE 后重打。" >&2
fi

# 4) 启动器：**必须先把工作目录切到包根**——ui/ 与 capabilities/ 都是相对路径。
#    纯 ASCII：cmd.exe 按 OEM 码页读 .bat，非 ASCII 会吞掉后续行。
#    exe 名随示例变，故这里用不带引号的 heredoc 让 $EXE_NAME 展开（正文里没有 `$`/反引号，安全）。
EXE_NAME="$NAME.exe"
cat > "$PKG/run.bat" <<BAT
@echo off
REM cj-tauri portable package launcher. Keep this file pure ASCII.
setlocal
set "HERE=%~dp0"
set "LOG=%TEMP%\cj-$NAME-run.log"
cd /d "%HERE%"
if not exist "$EXE_NAME" (
    echo [ERROR] $EXE_NAME not found next to this script.
    exit /b 1
)
echo [run] starting $EXE_NAME -- close the window to exit.
echo [run] log = %LOG%
"$EXE_NAME" 2>"%LOG%"
set "RC=%ERRORLEVEL%"
echo [run] exited with code %RC%
echo [run] --- backend calls ---
findstr /C:"[$NAME]" "%LOG%"
echo [run] full stderr log: %LOG%
exit /b %RC%
BAT

cat > "$PKG/README.txt" <<TXT
cj-tauri $NAME —— Windows 便携包
=================================

怎么跑
  1) 双击 run.bat（窗口出来后即为运行中，关掉窗口即退出）；
     或在本目录的命令行里执行  $EXE_NAME
     注意：工作目录必须是本目录（ui\\ 与 capabilities\\ 是按相对路径读的），
     run.bat 已经替你切好目录。
  2) 后端日志走 stderr，run.bat 会把它落到 %TEMP%\cj-$NAME-run.log 并打印关键行。

前置条件
  - Windows 10 1809+ / Windows 11（x64）；
  - 系统已安装 WebView2 Runtime（Win11 与多数打补丁的 Win10 自带；
    没有的话到微软官网装 Evergreen Runtime 即可）。
  除此之外**不需要**安装仓颉 SDK：仓颉运行时、stdx、C 桥、WebView2 加载器
  都在本目录的 DLL 里。

目录说明
  $EXE_NAME            应用本体（仓颉静态编译的宿主程序）
  *.dll                运行期依赖（仓颉运行时 / stdx / libcjtbridge / WebView2Loader / OpenSSL）
  ui\\index.html        页面（改它就能改界面）
  capabilities\\default.json  能力清单：命令与事件的白名单（默认最小权限）
  run.bat              启动器（切目录 + 收 stderr 日志）

第三方组件
  OpenSSL 3 (x64)：libssl-3-x64.dll / libcrypto-3-x64.dll，供仓颉运行时的 TLS 用
  （Apache License 2.0，取自构建机上的现成安装）。缺了它程序照跑，但所有 https 请求会失败。

首次运行会在本目录生成 $EXE_NAME.WebView2\\（WebView2 的用户数据目录），
删掉它会丢缓存与站点数据，不影响重新运行。
TXT

# 5) 打 zip。Git Bash 的 GNU tar **不支持** -a 生成 zip（只认 gzip/bzip2/xz），
#    所以优先用 Windows 自带的 bsdtar（C:\Windows\System32\tar.exe），退化用 PowerShell。
ZIP="$OUT_ROOT/$NAME-win-x64.zip"
BUNTAR="/c/Windows/System32/tar.exe"
if [ -x "$BUNTAR" ]; then
    # 注意：bsdtar 是 Windows 程序，-f 收的是**相对当前目录**的路径，所以先进子目录再给裸文件名
    ( cd "$OUT_ROOT" && "$BUNTAR" -a -c -f "$NAME-win-x64.zip" "$NAME-win-x64" )
elif command -v powershell >/dev/null 2>&1; then
    ZIP_WIN="$(cygpath -w "$ZIP")"
    PKG_WIN="$(cygpath -w "$PKG")"
    powershell -NoProfile -Command "Compress-Archive -LiteralPath '$PKG_WIN' -DestinationPath '$ZIP_WIN' -Force"
else
    echo "[pack] 警告: 没有可用的 zip 工具（bsdtar / powershell 都没有），只产出目录" >&2
fi

echo "[pack] 目录: $PKG"
[ -f "$ZIP" ] && echo "[pack] zip : $ZIP ($(du -sh "$ZIP" | cut -f1))"
