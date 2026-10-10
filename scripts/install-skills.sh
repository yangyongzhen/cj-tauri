#!/usr/bin/env bash
# 把本仓 skills/ 下的 skill 装到 AtomCode 的约定位置。
# 用法：bash scripts/install-skills.sh [--project]
#   （缺省装全局 ~/.atomcode/skills/；--project 装当前仓 .atomcode/skills/——按契约该目录不入库）
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MODE="${1:-}"

if [ "$MODE" = "--project" ]; then
    DEST="$HERE/.atomcode/skills"
else
    DEST="$HOME/.atomcode/skills"
fi

mkdir -p "$DEST"
installed=0
for dir in "$HERE"/skills/*/; do
    [ -f "$dir/SKILL.md" ] || continue
    name="$(basename "$dir")"
    rm -rf "$DEST/$name"
    cp -r "$dir" "$DEST/$name"
    echo "  ok    $name -> $DEST/$name"
    installed=$((installed + 1))
done
echo "[install-skills] 已装 $installed 个 skill 到 $DEST"
echo "[install-skills] AtomCode 里 / 菜单或 \$ 菜单即可看到；新装通常无需重启。"
