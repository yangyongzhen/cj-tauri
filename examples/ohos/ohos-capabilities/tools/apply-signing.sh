#!/usr/bin/env bash
# 把本机调试证书塞进 `cj-tauri sync ohos` 派生的 build-profile.json5
#
# 为什么需要这一步：`targets/` 是生成物、不入库（README 的 .gitignore 口径），而调试证书
# 与本机 DevEco 账号绑定，也不能入库。于是签名只能在「sync 之后、build 之前」补一刀。
# **每次重跑 `cj-tauri sync ohos` 都要再执行它一次**（sync 会把 build-profile.json5 重置）。
#
# 默认从同目录的兄弟工程借一份已签名的 build-profile.json5（本机 ohos-music / ohos-movie /
# ohos-probe 三份都是同一套 com.yang.testcj 调试证书）；换机器或换证书用环境变量指过去：
#   CJ_OHOS_SIGNING_SOURCE=/path/to/signed/build-profile.json5 bash tools/apply-signing.sh
set -euo pipefail

here=$(cd "$(dirname "$0")/.." && pwd)
target="$here/targets/ohos/build-profile.json5"
source_profile="${CJ_OHOS_SIGNING_SOURCE:-$here/../ohos-music/build-profile.json5}"

if [ ! -f "$target" ]; then
    echo "[signing] 缺少 $target —— 先跑 cj-tauri sync ohos" >&2
    exit 1
fi
if [ ! -f "$source_profile" ]; then
    echo "[signing] 找不到签名来源：$source_profile" >&2
    echo "[signing] 用 CJ_OHOS_SIGNING_SOURCE 指一份已签名的 build-profile.json5（DevEco 里 Automatically generate signature 之后那份）" >&2
    exit 1
fi

# 已经签过了就不要再动（sync 之后重复执行是幂等的）
if ! grep -q '"signingConfigs": \[\]' "$target"; then
    echo "[signing] $target 已带签名配置，跳过"
    exit 0
fi

# 抽出来源文件里 signingConfigs 数组的原文（保留注释与缩进，不做 JSON 解析：
# build-profile.json5 是 json5，正经解析器会把注释吃掉，反而不好读）。
# 先落到临时文件再让 awk 用 getline 读回来——**不能走 `awk -v`**：变量赋值会处理转义序列，
# 证书路径里的 `\\` 会被解成 `\`，写回去就是非法 json5（`\U` 不是合法转义）。
block_file=$(mktemp)
trap 'rm -f "$block_file"' EXIT
awk '
    /"signingConfigs": \[/ { inside = 1 }
    inside { print }
    inside && /^[[:space:]]*\],?[[:space:]]*$/ { exit }
' "$source_profile" > "$block_file"

if [ ! -s "$block_file" ]; then
    echo "[signing] $source_profile 里没有 signingConfigs 内容" >&2
    exit 1
fi

# 用临时文件替换：awk 逐行扫，命中那唯一一行空数组就换成整段块；
# 顺手给 products[0] 补上 "signingConfig": "default"（模板里没有这一行）
tmp="$target.tmp"
awk -v blockfile="$block_file" '
    BEGIN { n = 0; while ((getline line < blockfile) > 0) { blk[n++] = line } }
    /"signingConfigs": \[\]/ { for (i = 0; i < n; i++) print blk[i]; next }
    /"name": "default",/ && !done { print; print "        \"signingConfig\": \"default\","; done = 1; next }
    { print }
' "$target" > "$tmp"
mv "$tmp" "$target"

echo "[signing] 已注入签名配置：来源 $(basename "$(dirname "$source_profile")")/build-profile.json5"
grep -c 'certpath' "$target" | sed 's/^/[signing] certpath 条数：/'
