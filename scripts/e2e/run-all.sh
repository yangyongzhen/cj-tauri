#!/usr/bin/env bash
# e2e/run-all.sh — 跑齐 scripts/e2e/test-*.sh，并把「真跑过 / 跳过 / 失败」分开数清楚
#
# 为什么要有它：单个入口脚本自己知道该不该跑，但没人汇总时「本机今天到底验了什么」只能靠人读日志——
# 而「全跳过」和「全通过」在退出码上都是 0，这正是假绿最爱的形状。这里把三类结论分开计数并打印，
# 最后一行永远是「真跑了几个平台」。
#
# 用法：
#   bash scripts/e2e/run-all.sh                    # 本机适用的入口真跑；其余显式跳过
#   bash scripts/e2e/run-all.sh --list             # 只列入口
#   CJ_TAURI_E2E_REQUIRE=linux bash scripts/e2e/run-all.sh
#                                                  # CI：声明本机**必须**跑的平台，错机=失败（不是跳过）
#
# 退出码：0 = 没有失败项；1 = 有失败项（跳过不算失败，但会如实计数）
set -u

E2E_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
E2E_ROOT="$(cd "$E2E_LIB_DIR/../.." && pwd)"

# shellcheck source=lib.sh
source "$E2E_LIB_DIR/lib.sh"

entries=()
while IFS= read -r f; do entries+=("$f"); done < <(ls -1 "$E2E_LIB_DIR"/test-*.sh 2>/dev/null | sort)

if [ "${1:-}" = "--list" ]; then
  printf '%s\n' "${entries[@]}"
  exit 0
fi

if [ "${#entries[@]}" -eq 0 ]; then
  printf '[e2e] 没有找到任何 scripts/e2e/test-*.sh 入口\n' >&2
  exit 1
fi

host="$(e2e_host_platform)"
printf '[e2e] 宿主平台=%s 入口数=%s%s\n' "$host" "${#entries[@]}" \
  "${CJ_TAURI_E2E_REQUIRE:+ 必须运行=${CJ_TAURI_E2E_REQUIRE}}" >&2

passed=0; skipped=0; failed=0
ran_any=0
declare -a failed_names=()

for t in "${entries[@]}"; do
  name="$(basename "$t" .sh)"
  out="$(bash "$t" 2>&1)"
  code=$?
  # 分类看两样东西：退出码 + 是否打了 SKIP 行。跳过是退出码 0，所以只看退出码会把
  # 「跳过」记成「通过」——那正是这套基建要防的事。
  if [ "$code" -ne 0 ]; then
    failed=$((failed + 1)); failed_names+=("$name"); ran_any=1
    printf '[e2e] FAIL  %s（exit=%s）\n' "$name" "$code" >&2
    printf '%s\n' "$out" | sed 's/^/       | /' >&2
  elif printf '%s' "$out" | grep -q '^\[e2e\] SKIP'; then
    skipped=$((skipped + 1))
    printf '[e2e] SKIP  %s（%s）\n' "$name" "$(printf '%s' "$out" | grep -m1 '^\[e2e\] SKIP' | sed 's/^\[e2e\] SKIP *//')" >&2
  else
    passed=$((passed + 1)); ran_any=1
    printf '[e2e] PASS  %s\n' "$name" >&2
    printf '%s\n' "$out" | grep -E '断言|e2e-evidence:' | sed 's/^/       | /' >&2
  fi
done

printf '[e2e] 汇总：通过 %s / 跳过 %s / 失败 %s\n' "$passed" "$skipped" "$failed" >&2
if [ "$ran_any" -eq 0 ]; then
  printf '[e2e] 注意：本轮**没有任何平台真的跑了**（全部跳过）——这不是通过，是没验\n' >&2
fi
printf '[e2e] 证据目录：%s/dist/e2e-evidence/\n' "$E2E_ROOT" >&2

if [ "$failed" -gt 0 ]; then
  printf '[e2e] 失败入口：%s\n' "${failed_names[*]}" >&2
  exit 1
fi
exit 0
