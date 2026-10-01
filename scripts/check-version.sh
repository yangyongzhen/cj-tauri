#!/usr/bin/env bash
# check-version.sh — 校验 cj-tauri 的版本号在各处是否一致（只读，不改文件）
#
# 权威目标版本：CHANGELOG.md 顶部第一个已发版段 `## [x.y.z] - YYYY-MM-DD`
# 必须与它一致的位置：
#   1. cjpm.toml              框架包 version
#   2. cli/cjpm.toml          CLI 包 version
#   3. cli/src/project.cj     cliVersion() 的返回值（--version / info 打印它）
#   4. src/version.cj         CJ_TAURI_VERSION（system:version 命令返回它）
#   5. npm/package.json       npm 包 version（npx cj-tauri --version 在无 SDK 时用它）
#
# 不参与校验：examples/hello/cjpm.toml 与模板生成工程的 version —— 那是各应用自己的版本。
#
# 用法：bash scripts/check-version.sh
# 退出码：0 = 一致；1 = 有位置未同步
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT" || exit 1

ver_of_toml() { grep -m1 -oE '^[[:space:]]*version[[:space:]]*=[[:space:]]*"[^"]+"' "$1" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+'; }
ver_of_changelog() { grep -m1 -oE '^## \[[0-9]+\.[0-9]+\.[0-9]+\]' "$1" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+'; }
ver_of_cli_cj() { sed -n '/func cliVersion/,/^}/p' "$1" | grep -m1 -oE '[0-9]+\.[0-9]+\.[0-9]+'; }
ver_of_version_cj() { grep -m1 -oE 'CJ_TAURI_VERSION[[:space:]]*=[[:space:]]*"[0-9]+\.[0-9]+\.[0-9]+"' "$1" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+'; }
ver_of_json() { grep -m1 -oE '"version"[[:space:]]*:[[:space:]]*"[0-9]+\.[0-9]+\.[0-9]+"' "$1" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+'; }

EXPECT="$(ver_of_changelog CHANGELOG.md)"
if [ -z "$EXPECT" ]; then
    echo "[FAIL] CHANGELOG.md 里找不到已发版段（形如 '## [0.3.0] - 2026-10-01'）"
    exit 1
fi

rc=0
check() {
    name="$1"
    got="$2"
    if [ "$got" = "$EXPECT" ]; then
        printf '  ok    %-22s %s\n' "$name" "$got"
    else
        printf '  DIFF  %-22s %s（应为 %s）\n' "$name" "${got:-<未找到>}" "$EXPECT"
        rc=1
    fi
}

echo "目标版本（CHANGELOG.md 顶部）：$EXPECT"
check "cjpm.toml"           "$(ver_of_toml cjpm.toml)"
check "cli/cjpm.toml"       "$(ver_of_toml cli/cjpm.toml)"
check "cli/src/project.cj"  "$(ver_of_cli_cj cli/src/project.cj)"
check "src/version.cj"      "$(ver_of_version_cj src/version.cj)"
check "npm/package.json"    "$(ver_of_json npm/package.json)"

if [ "$rc" -eq 0 ]; then
    echo "[OK] 版本号一致"
else
    echo "[FAIL] 版本号不一致，见上；同步后再提交"
fi
exit "$rc"
