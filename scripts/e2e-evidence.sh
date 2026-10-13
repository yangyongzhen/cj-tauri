#!/usr/bin/env bash
# e2e-evidence.sh — 把一次实机验证的结论落成**可对账的 JSON**（而不是只留一堆人读的日志）
#
# 为什么需要它：`supported` 状态的门槛是「可复核证据」。日志 + 截图能证明「跑过」，但
# 无法被机器对账——需求追踪矩阵里的「证据在哪」只能靠人记。这个脚本把一次实机的
#   平台 / 运行时版本 / 每条断言的命中次数 / 时间
# 写成一份 JSON，矩阵与 CI 都能读，证伪也变成一条 grep 的事。
#
# 用法：
#   bash scripts/e2e-evidence.sh --name <例名> --log <日志文件> [选项]
#
# 选项：
#   --name <s>       本次验证的名字（进 JSON 的 name，也决定默认输出文件名），必填
#   --log <file>     桥 stderr 日志；断言按行 grep 它，必填
#   --assert <name>:<needle>
#                    一条断言：needle 是**整行前缀**（如 `[cj-bridge]`）或任意子串，
#                    命中次数 > 0 记 passed。可重复。needle 里可以有空格与冒号
#                    （只按**第一个**冒号切分）。
#   --require <name>:<needle>
#                    与 --assert 同义，语义上强调「必须命中」，便于阅读调用点。
#   --cmd <shell>    先跑这条命令产生日志（失败不致命：日志才是证据，退出码记录下来）
#   --cwd <dir>      跑 --cmd 前切到此目录（应用按相对路径读 capabilities/ ui/）
#   --out <file>     输出路径（默认 dist/e2e-evidence/<platform>[-<name>].json）
#   --note <s>       附注（如「Xvfb :99 / 1280x800x24」）
#   --allow-missing  无断言命中时也返回 0（默认：任一条断言失败即返回 1）
#
# 退出码：0 = 所有断言命中；1 = 有断言未命中（或用法错误）
#
# 判据纪律（与 AGENTS §4 一致）：断言 needle 用**整行前缀**，别用会在正文里撞词的中缀；
# 计数一律取 grep -c 的结果，不看退出码——「日志里没有失败行」不等于「成功」。
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT" || exit 1

NAME=""
LOG=""
OUT=""
CMD=""
WORKDIR=""
NOTE=""
ALLOW_MISSING=0
ASSERTS=()   # 形如 "名字<TAB>needle"

usage() {
  sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'
  exit 1
}

die() { printf 'e2e-evidence: %s\n' "$1" >&2; exit 1; }

while [ $# -gt 0 ]; do
  case "$1" in
    --name)          NAME="${2:-}"; shift 2 ;;
    --log)           LOG="${2:-}"; shift 2 ;;
    --out)           OUT="${2:-}"; shift 2 ;;
    --cmd)           CMD="${2:-}"; shift 2 ;;
    --cwd)           WORKDIR="${2:-}"; shift 2 ;;
    --note)          NOTE="${2:-}"; shift 2 ;;
    --assert|--require)
                     a="${2:-}"; shift 2
                     case "$a" in
                       *:*) ASSERTS+=("${a%%:*}"$'\t'"${a#*:}") ;;
                       *)   die "--assert 需要 <名字>:<needle> 形式，收到: $a" ;;
                     esac ;;
    --allow-missing) ALLOW_MISSING=1; shift ;;
    -h|--help)       usage ;;
    *) die "未知参数: $1（--help 看用法）" ;;
  esac
done

[ -n "$NAME" ] || die "缺少 --name"
[ -n "$LOG" ]   || die "缺少 --log"

# ------------------------------------------------------------------ 平台
case "$(uname -s)" in
  Linux)               PLATFORM=linux ;;
  MINGW*|MSYS*|CYGWIN*) PLATFORM=windows ;;
  *)                   PLATFORM=unknown ;;
esac

# --------------------------------------------------- 运行时版本（WebView/GTK）
# Linux 走 pkg-config（版本号是编译期装的那套，与运行期一致）；
# Windows 的 WebView2 版本只能从桥 stderr 里读（SDK 版本 ≠ Runtime 版本，别混用）。
RUNTIME_JSON="{}"
if [ "$PLATFORM" = "linux" ] && command -v pkg-config >/dev/null 2>&1; then
  WEBKIT="$(pkg-config --modversion webkit2gtk-4.1 2>/dev/null || echo '')"
  GTK="$(pkg-config --modversion gtk+-3.0 2>/dev/null || echo '')"
  RUNTIME_JSON="{\"webkit2gtk\":\"$WEBKIT\",\"gtk3\":\"$GTK\"}"
else
  # 从日志里找一条形如 `WebView2 runtime: 122.0.2365.106` 的行（有就记，没有留空）
  W2="$(grep -m1 -o 'WebView2[^0-9]*[0-9][0-9.]*' "$LOG" 2>/dev/null | grep -o '[0-9][0-9.]*' || echo '')"
  RUNTIME_JSON="{\"webview2\":\"$W2\"}"
fi

# ------------------------------------------------------------- 可选：先跑命令
CMD_EXIT="null"
if [ -n "$CMD" ]; then
  printf 'e2e-evidence: 运行 %s\n' "$CMD" >&2
  if [ -n "$WORKDIR" ]; then
    ( cd "$WORKDIR" && bash -c "$CMD" ) >/dev/null 2>&1
  else
    bash -c "$CMD" >/dev/null 2>&1
  fi
  CMD_EXIT="$?"
fi

[ -f "$LOG" ] || die "日志不存在: $LOG"

# ------------------------------------------------------------------ 断言
# 每条断言一个 JSON 对象：命中次数用 `grep -c` 取（-F 字面量，避免 needle 里的
# 正则元字符被当模式）；grep 无命中时退出码 1 且输出 0，所以不需要 || echo 0。
LOG_LINES="$(wc -l < "$LOG" | tr -d ' ')"
ASSERT_JSON="["
FAILED=0
FIRST=1
for a in "${ASSERTS[@]}"; do
  aname="${a%%$'\t'*}"
  aneedle="${a#*$'\t'}"
  acount="$(grep -c -F -- "$aneedle" "$LOG" 2>/dev/null || true)"
  [ -n "$acount" ] || acount=0
  apass=false
  if [ "$acount" -gt 0 ]; then apass=true; else FAILED=$((FAILED + 1)); fi
  [ $FIRST -eq 1 ] || ASSERT_JSON="$ASSERT_JSON,"
  FIRST=0
  # needle 可能含 `"` / `\`，交给 python3 做 JSON 转义（本机与 CI 都有）
  esc_name="$(printf '%s' "$aname"   | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read(),ensure_ascii=False)[1:-1])')"
  esc_needle="$(printf '%s' "$aneedle" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read(),ensure_ascii=False)[1:-1])')"
  ASSERT_JSON="$ASSERT_JSON{\"name\":\"$esc_name\",\"needle\":\"$esc_needle\",\"count\":$acount,\"passed\":$apass}"
done
ASSERT_JSON="$ASSERT_JSON]"

if [ -n "$NOTE" ]; then
  esc_note="$(printf '%s' "$NOTE" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read(),ensure_ascii=False)[1:-1])')"
  NOTE_JSON="\"$esc_note\""
else
  NOTE_JSON="null"
fi

TOTAL="${#ASSERTS[@]}"
PASSED=$((TOTAL - FAILED))
if [ "$TOTAL" -gt 0 ] && [ "$FAILED" -eq 0 ]; then
  OVERALL=true
else
  OVERALL=false
fi
[ "$TOTAL" -eq 0 ] && OVERALL=false

# ------------------------------------------------------------------ 输出
if [ -z "$OUT" ]; then
  mkdir -p dist/e2e-evidence || die "无法创建 dist/e2e-evidence"
  OUT="dist/e2e-evidence/${PLATFORM}-${NAME}.json"
fi
mkdir -p "$(dirname "$OUT")" || die "无法创建输出目录"

{
  printf '{\n'
  printf '  "schema": "cj-tauri/e2e-evidence@1",\n'
  printf '  "name": "%s",\n' "$NAME"
  printf '  "platform": "%s",\n' "$PLATFORM"
  printf '  "recordedAt": "%s",\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf '  "runtime": %s,\n' "$RUNTIME_JSON"
  printf '  "log": "%s",\n' "$LOG"
  printf '  "logLines": %s,\n' "$LOG_LINES"
  printf '  "cmdExit": %s,\n' "$CMD_EXIT"
  printf '  "note": %s,\n' "$NOTE_JSON"
  printf '  "assertions": %s,\n' "$ASSERT_JSON"
  printf '  "summary": {"total": %s, "passed": %s, "failed": %s, "ok": %s}\n' \
    "$TOTAL" "$PASSED" "$FAILED" "$OVERALL"
  printf '}\n'
} > "$OUT"

# 自检：刚写的东西必须能被解析（否则这份「证据」本身就是坏的）
if command -v python3 >/dev/null 2>&1; then
  python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$OUT" \
    || die "生成的 JSON 无法解析: $OUT"
fi

printf 'e2e-evidence: 断言 %s/%s 通过%s → %s\n' \
  "$PASSED" "$TOTAL" \
  "$([ "$FAILED" -gt 0 ] && printf '（失败 %s 条）' "$FAILED" || printf '')" "$OUT" >&2

if [ "$FAILED" -gt 0 ] && [ "$ALLOW_MISSING" -eq 0 ]; then
  for a in "${ASSERTS[@]}"; do
    aname="${a%%$'\t'*}"; aneedle="${a#*$'\t'}"
    grep -q -F -- "$aneedle" "$LOG" || printf '  FAIL  %s（needle 未命中: %s）\n' "$aname" "$aneedle" >&2
  done
  exit 1
fi
exit 0
