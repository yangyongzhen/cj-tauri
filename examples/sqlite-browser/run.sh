#!/usr/bin/env bash
# ============================================================
# SQLite 浏览器（examples/sqlite-browser）—— Linux 一键跑通
#
# 这里**不另立一份验证标准**：夹具库的生成、应用起停、实机口径、断言与证据都在仓内 E2E 入口里维护
# （scripts/e2e/test-linux-sqlite-browser.sh）。本脚本只做「从示例目录也能一键跑」的转发，
# 少一份会各自漂移的拷贝（与 examples/markdown-notes / redis-client / http-client 同约定）。
#
# 前置：桥已构建（bash native/build_linux.sh）。
# 用法：bash run.sh [E2E 入口的额外参数]
# ============================================================
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
ENTRY="$ROOT/scripts/e2e/test-linux-sqlite-browser.sh"

if [ ! -f "$ENTRY" ]; then
  echo "找不到 E2E 入口 $ENTRY —— 请先同步仓库（该入口随仓分发）" >&2
  exit 1
fi

cd "$ROOT"
exec bash "$ENTRY" "$@"
