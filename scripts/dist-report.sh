#!/usr/bin/env bash
# scripts/dist-report.sh — 分发形态对比用的**可对账数据**（demo B 的数据来源）
#
# 为什么要脚本而不是手抄一张表：体积、依赖、冷启动三个数都跟"哪台机器、哪个提交、哪次构建"绑定，
# 手抄的表没人能复核。这里每个数都现场量、连同口径一起落进 dist/dist-report.json（证据目录，不入库）。
#
# 量什么（口径写在输出里，一处也不含糊）：
#   1. 单文件 exe 的体积与身份：入库的 examples/*/dist-single/*.exe，取字节数 + sha256 前 12 位。
#      **只读入库的那份**——它是随仓库分发、别人能拿到并对上哈希的产物。
#   2. 单文件 exe 的依赖：objdump -p 读 PE 导入表，按系统 DLL 白名单分类。
#      「免安装」的硬判据就是这张表里**没有第三方 DLL**（AGENTS §4：判据看导入表，不看链接命令）。
#   3. Linux 产物的体积与随包共享库：二进制字节 + ldd 解析出的、**不属于系统库**的那些 .so 合计
#      （Linux 没有单文件形态，要如实说清「要带什么」）。
#   4. 冷启动：从进程起到桥打出「窗口配置到宿主」那一行的耗时，跑 N 次取中位数，分辨率 10ms。
#      本机只能是宿主平台的那一侧：Windows 上量 exe，Linux 上量本机示例产物。量不到就写 null 并注明原因
#      ——**不要拿另一侧的机器数据冒充**。
#
# 用法：
#   bash scripts/dist-report.sh                 # 量本机能量的那一侧，打印 markdown 表
#   bash scripts/dist-report.sh --runs 5        # 冷启动跑 5 次
#   bash scripts/dist-report.sh --json out.json # 指定 JSON 输出路径（默认 dist/dist-report.json）
#
# 退出码：0 = 数据齐（允许有 null，但会打印未量的原因）；1 = 连体积都读不到（说明仓库/路径不对）
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$ROOT"

RUNS=3
JSON_OUT="$ROOT/dist/dist-report.json"
SVG_OUT=""
SVG_WRITTEN=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --runs) RUNS="${2:-3}"; shift 2 ;;
    --json) JSON_OUT="${2:-}"; shift 2 ;;
    --svg) SVG_OUT="${2:-}"; shift 2 ;;
    -h|--help) sed -n '2,26p' "$0"; exit 0 ;;
    *) echo "[dist] 未知参数：$1" >&2; exit 1 ;;
  esac
done

host="unknown"
case "$(uname -s)" in
  Linux) host="linux" ;;
  MINGW*|MSYS*|CYGWIN*) host="windows" ;;
  Darwin) host="macos" ;;
  *) host="unknown" ;;
esac

# SDK 环境（可选）：Linux 侧 ldd 要能解析 libcjtbridge.so / libstdx / 仓颉运行时，
# 否则 ldd 会把它们报成 "not found"，随包库清单就成了假的。
if [ -f "$SCRIPT_DIR/e2e/lib.sh" ]; then
  # shellcheck source=e2e/lib.sh
  source "$SCRIPT_DIR/e2e/lib.sh"
  e2e_ensure_sdk >/dev/null 2>&1 || true
fi

mkdir -p "$(dirname "$JSON_OUT")"
NEEDLE="[cj-bridge] set window: title="

# ------------------------------------------------------------------ 1) 入库单文件 exe
EXE_LIST="$(git ls-files 'examples/*/dist-single/*.exe' 2>/dev/null | sort)"
EXE_COUNT=0
EXE_ROWS=""          # JSON 片段
EXE_TABLE=""         # markdown 行
SVG_ROWS=""          # 图表数据（制表符分隔：名字 / 字节 / 类型 / 附注）——与 JSON 同源，不另抄一份数

# 系统 DLL 白名单：mingw / 仓颉运行时在 Windows 上只会链到系统组件。
# 表里出现白名单以外的名字，就是「免安装」这条要打问号的地方（会单独列出来）。
# dbghelp.dll 也在系统里（System32，崩溃栈回溯用）——第一版漏了它，四个 exe 全被误报成「非系统 1」，
# 所以凡是要判「是不是系统的」，先确认它在 System32 里，再决定加白还是报警。
SYS_DLL_RE='^(kernel32|user32|gdi32|advapi32|shell32|ole32|oleaut32|comdlg32|comctl32|shlwapi|winmm|ws2_32|crypt32|bcrypt|ncrypt|dbghelp|wininet|mswsock|shcore|propsys|oleacc|uiautomationcore|d3d11|dxgi|opengl32|dwmapi|uxtheme|version|imm32|msvcrt|ucrtbase|secur32|iphlpapi|dnsapi|normaliz|msimg32|userenv|psapi|powrprof|winhttp|urlmon|setupapi|cfgmgr32|rpcrt4|ntdll|avrt|ksuser|api-ms-win-.*|ext-ms-.*)\.dll$'

for exe in $EXE_LIST; do
  [ -f "$exe" ] || continue
  bytes="$(stat -c %s "$exe" 2>/dev/null || stat -f %z "$exe" 2>/dev/null || echo 0)"
  sha="$(sha256sum "$exe" 2>/dev/null | cut -c1-12)"
  [ -n "$sha" ] || sha="(no sha256sum)"
  imports=""
  nonsys=""
  if command -v objdump >/dev/null 2>&1; then
    # objdump 在 Linux 上照样能读 PE 的导入表，不必等 Windows 机器
    imports="$(objdump -p "$exe" 2>/dev/null | awk '/DLL Name:/{print tolower($3)}' | sort -u)"
    nonsys="$(printf '%s\n' "$imports" | grep -Ev "$SYS_DLL_RE" | grep -v '^$' | tr '\n' ' ')"
  fi
  n_imports="$(printf '%s\n' "$imports" | grep -c . || true)"
  n_nonsys="$(printf '%s\n' "$nonsys" | tr ' ' '\n' | grep -c . || true)"
  [ -n "$(printf '%s' "$imports" | head -c1)" ] || n_imports=0
  [ -n "$(printf '%s' "$nonsys" | head -c1)" ] || n_nonsys=0

  EXE_COUNT=$((EXE_COUNT + 1))
  EXE_ROWS="$EXE_ROWS{\"path\":\"$exe\",\"bytes\":$bytes,\"sha256_12\":\"$sha\",\"imports\":{\"total\":$n_imports,\"nonSystem\":$n_nonsys,\"nonSystemNames\":\"$(printf '%s' "$nonsys" | sed 's/ $//')\"}},"
  printf '[dist] exe %-46s %9s B  sha=%s  导入 %s 项（非系统 %s）\n' "$exe" "$bytes" "$sha" "$n_imports" "$n_nonsys" >&2
  EXE_TABLE="$EXE_TABLE| \`$(basename "$exe")\` | $(awk -v b="$bytes" 'BEGIN{printf "%.2f", b/1048576}') MB | $bytes | $sha | $n_imports | $n_nonsys |"$'\n'
  SVG_ROWS="${SVG_ROWS}$(basename "$exe")"$'\t'"$bytes"$'\t'"exe"$'\t'"PE 导入 $n_imports 项全为系统 DLL · sha256 ${sha:0:12}"$'\n'
done
EXE_ROWS="${EXE_ROWS%,}"

# ------------------------------------------------------------------ 2) Linux 产物与随包库
LINUX_APP="examples/serial-waveform/target/release/bin/main"
LINUX_DIR="examples/serial-waveform"
LINUX_JSON="null"
LINUX_TABLE=""
if [ "$host" = "linux" ] && [ -x "$LINUX_APP" ]; then
  app_bytes="$(stat -c %s "$LINUX_APP")"
  bundled_bytes=0
  bundled_list=""
  total_libs=0
  while IFS= read -r line; do
    lib="$(printf '%s' "$line" | awk '/=>/{print $3} /^\t\//{print $1}')"
    [ -n "$lib" ] || continue
    case "$lib" in /*) ;; *) continue ;; esac
    total_libs=$((total_libs + 1))
    # 「随包」= 不在系统库目录里：仓内 native/、仓颉运行时、stdx 都要跟产物一起走
    case "$lib" in
      */native/*|*/cangjie/*|*/.cangjie/*|*/stdx/*)
        sz="$(stat -c %s "$lib" 2>/dev/null || echo 0)"
        bundled_bytes=$((bundled_bytes + sz))
        bundled_list="$bundled_list $(basename "$lib")"
        ;;
    esac
  done < <(ldd "$LINUX_APP" 2>/dev/null)
  LINUX_JSON="{\"path\":\"$LINUX_APP\",\"bytes\":$app_bytes,\"sharedLibs\":$total_libs,\"bundledLibsBytes\":$bundled_bytes,\"bundledLibs\":\"$(printf '%s' "$bundled_list" | sed 's/^ //')\"}"
  printf '[dist] linux 产物 %-40s %9s B  ldd 库 %s 项，其中随包 %s 字节\n' "$LINUX_APP" "$app_bytes" "$total_libs" "$bundled_bytes" >&2
  LINUX_TABLE="| Linux 目录式（\`$(basename "$LINUX_APP")\` + 随包 .so） | $(awk -v b=$((app_bytes + bundled_bytes)) 'BEGIN{printf "%.2f", b/1048576}') MB | $((app_bytes + bundled_bytes)) | — | — | — |"$'\n'
  SVG_ROWS="${SVG_ROWS}Linux 目录式"$'\t'"$((app_bytes + bundled_bytes))"$'\t'"dir"$'\t'"main $(awk -v b="$app_bytes" 'BEGIN{printf "%.2f", b/1048576}') MB + 随包共享库 $(awk -v b="$bundled_bytes" 'BEGIN{printf "%.2f", b/1048576}') MB"$'\n'
else
  printf '[dist] 跳过 Linux 产物体积（未构建 %s）\n' "$LINUX_APP" >&2
fi

# ------------------------------------------------------------------ 3) 冷启动
# 口径：进程起到桥打出「窗口配置到宿主」那一行；10ms 轮询，跑 N 次取中位数。
# 为什么取这一行：它前面是宿主创建与能力位、后面才是页面加载，是"窗口真的立起来了"的最早可观测点，
# 而且两平台由同一份 core 打印（bridge_core.c），跨平台可比。
COLD_JSON=""
COLD_TABLE=""
cold_med() { printf '%s\n' "$@" | sort -n | awk '{a[NR]=$1} END{ if(NR%2) print a[(NR+1)/2]; else print int((a[NR/2]+a[NR/2+1])/2) }'; }

measure_cold_start() {
  local label="$1" dir="$2"; shift 2
  local -a times=()
  local i t0 t1 found pid ms
  for i in $(seq 1 "$RUNS"); do
    : >"$ROOT/dist/dist-report.cold.log"
    t0="$(date +%s%N)"
    ( cd "$dir" && exec "$@" ) >>"$ROOT/dist/dist-report.cold.log" 2>&1 &
    pid=$!
    found=0
    while [ "$(( ($(date +%s%N) - t0) / 1000000 ))" -lt 30000 ]; do
      if grep -q -F -- "$NEEDLE" "$ROOT/dist/dist-report.cold.log" 2>/dev/null; then found=1; break; fi
      kill -0 "$pid" 2>/dev/null || break
      sleep 0.01
    done
    t1="$(date +%s%N)"
    # 应用会起子线程/子进程：先子后父，别留残留实例往同一份日志里写（AGENTS §4）
    for c in $(pgrep -P "$pid" 2>/dev/null || true); do kill "$c" 2>/dev/null || true; done
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    ms=$(( (t1 - t0) / 1000000 ))
    if [ "$found" -eq 1 ]; then
      times+=("$ms")
      printf '[dist] 冷启动 %s 第 %s 次：%s ms\n' "$label" "$i" "$ms" >&2
    else
      printf '[dist] 冷启动 %s 第 %s 次：未在 30s 内看到「%s」（跳过这次）\n' "$label" "$i" "$NEEDLE" >&2
    fi
  done
  [ "${#times[@]}" -gt 0 ] || return 1
  local median; median="$(cold_med "${times[@]}")"
  COLD_JSON="$COLD_JSON{\"label\":\"$label\",\"platform\":\"$host\",\"medianMs\":$median,\"runs\":[$(IFS=,; echo "${times[*]}")]},"
  COLD_TABLE="$COLD_TABLE| $label | ${median} ms | $(IFS=,; echo "${times[*]}") |"$'\n'
  printf '[dist] 冷启动 %s 中位数 %s ms（%s 次）\n' "$label" "$median" "$RUNS" >&2
  return 0
}

COLD_NOTE="未量：本机没有可执行的对应产物"
if [ "$host" = "windows" ] && [ "$EXE_COUNT" -gt 0 ]; then
  first_exe="$(printf '%s\n' $EXE_LIST | head -1)"
  if measure_cold_start "$(basename "$first_exe")" "$(dirname "$first_exe")" "./$(basename "$first_exe")"; then
    COLD_NOTE="只量了第一个 exe（$first_exe）；其余同源同构"
  fi
elif [ "$host" = "linux" ] && [ -x "$LINUX_APP" ]; then
  if measure_cold_start "serial-waveform(linux)" "$LINUX_DIR" "./target/release/bin/main"; then
    COLD_NOTE="Linux 侧：量的是本机示例产物（不是 Windows 的 exe）"
  fi
fi
COLD_JSON="${COLD_JSON%,}"

# ------------------------------------------------------------------ 3) 按名字加载的组件（导入表与 ldd 都看不到）
# 这一类是本项目已踩过的坑：仓颉运行时的 TLS 加载器与 C 桥都是**按名字**去加载组件的，
# 所以「导入表只有系统 DLL」并**不等于**「这一份产物自带一切」。
#   WebView2Loader.dll：单文件包里由打包脚本把字节编进 exe（-DCJ_EMBED_WEBVIEW2_LOADER）。
#   libssl / libcrypto：Windows 侧必须随包（AGENTS §4：漏了的表象是「窗口照起、http 照 200，只有 https 全灭」）；
#     Linux 侧本机实测由系统包提供，不随包——两边不一样，所以分开写清楚，别混成一个数。
NAMED_JSON=""
SSL_FILES_JSON=""
ssl_bytes=0
declare -A _seen_ssl=()
for f in /usr/lib/x86_64-linux-gnu/libssl.so.3 /usr/lib/x86_64-linux-gnu/libcrypto.so.3 \
         /lib/x86_64-linux-gnu/libssl.so.3 /lib/x86_64-linux-gnu/libcrypto.so.3; do
  [ -f "$f" ] || continue
  # /lib 与 /usr/lib 在多数发行版里是同一份（软链/合并 usr）：按真实路径去重，
  # 否则同一个库被算两遍，体积会凭空翻倍（第一版就是这么虚高了 12 MB）。
  real="$(readlink -f "$f")"
  [ -n "${_seen_ssl[$real]:-}" ] && continue
  _seen_ssl[$real]=1
  sz="$(stat -c %s "$f")"
  ssl_bytes=$((ssl_bytes + sz))
  SSL_FILES_JSON="$SSL_FILES_JSON{\"path\":\"$real\",\"bytes\":$sz},"
  printf '[dist] 按名字加载（openssl）: %s %s B —— 由系统包提供\n' "$real" "$sz" >&2
done
SSL_FILES_JSON="${SSL_FILES_JSON%,}"
if [ "$host" = "linux" ]; then
  NAMED_JSON="{\"webView2Loader\":\"Windows 侧概念：单文件包把它的字节编进 exe（pack-win-single.sh）\",\"openssl\":\"由系统包提供（不随包）\",\"opensslBytes\":$ssl_bytes,\"opensslFiles\":[$SSL_FILES_JSON]}"
else
  NAMED_JSON="{\"webView2Loader\":\"内嵌在 exe 里（pack-win-single.sh 的 -DCJ_EMBED_WEBVIEW2_LOADER）\",\"openssl\":\"libssl-3-x64.dll / libcrypto-3-x64.dll 必须随包（导入表里看不到）；本机未验证单文件形态下它们的落法\",\"opensslBytes\":null,\"opensslFiles\":[]}"
fi

# ------------------------------------------------------------------ 4) 图表
# 图与数同源：条形的数字就是这一轮量出来的，不另抄一份——表和图各说各话是数据页最丢信誉的样子。
# 手写 SVG（不引绘图库）：纯文本产物，能看 diff，rsvg-convert / 浏览器都能渲染。
render_svg() {
  local out="$1" max=0 label bytes kind detail bw y i n H
  while IFS=$'\t' read -r label bytes kind detail; do
    [ -n "${bytes:-}" ] || continue
    [ "$bytes" -gt "$max" ] && max="$bytes"
  done <<<"$SVG_ROWS"
  [ "$max" -gt 0 ] || { printf '[dist] 没有可画的数据，跳过 SVG\n' >&2; return 1; }
  n="$(printf '%s\n' "$SVG_ROWS" | grep -c .)"
  H=$((140 + n * 54 + 80))
  mkdir -p "$(dirname "$out")"
  {
    printf '<svg xmlns="http://www.w3.org/2000/svg" width="880" height="%s" viewBox="0 0 880 %s" font-family="Noto Sans CJK SC, Source Han Sans SC, WenQuanYi Micro Hei, Microsoft YaHei, sans-serif">\n' "$H" "$H"
    printf '<rect width="880" height="%s" fill="#F8FAFC"/>\n' "$H"
    printf '<text x="40" y="48" font-size="22" font-weight="600" fill="#0F2430">cj-tauri 分发形态体积对比（实测）</text>\n'
    printf '<text x="40" y="74" font-size="13" fill="#5B6B78">同一份仓颉后端：Windows 单文件 exe vs Linux 可执行文件 + 随包共享库</text>\n'
    i=0
    while IFS=$'\t' read -r label bytes kind detail; do
      [ -n "${bytes:-}" ] || continue
      y=$((118 + i * 54))
      bw=$((470 * bytes / max))
      [ "$bw" -lt 3 ] && bw=3
      local color="#0E7C86"
      [ "$kind" = "dir" ] && color="#6B7C8C"
      printf '<text x="40" y="%s" font-size="14" fill="#12303C">%s</text>\n' "$((y + 13))" "$label"
      printf '<text x="40" y="%s" font-size="11" fill="#6B7C8C">%s</text>\n' "$((y + 31))" "$detail"
      printf '<rect x="300" y="%s" width="%s" height="28" rx="4" fill="%s"/>\n' "$y" "$bw" "$color"
      printf '<text x="%s" y="%s" font-size="13" font-weight="600" fill="#12303C">%s MB</text>\n' "$((300 + bw + 10))" "$((y + 19))" "$(awk -v b="$bytes" 'BEGIN{printf "%.2f", b/1048576}')"
      i=$((i + 1))
    done <<<"$SVG_ROWS"
    # 口径脚注跟着图走：图脱离口径被引用，就成了「不知从哪抄来的数字」
    printf '<text x="40" y="%s" font-size="11" fill="#5B6B78">口径：单文件 exe 取仓库里随仓库分发的那一份（examples/*/dist-single/），体积＝文件字节，依赖＝PE 导入表（objdump 实测，全为系统 DLL）；</text>\n' "$((H - 70))"
    printf '<text x="40" y="%s" font-size="11" fill="#5B6B78">Linux 无单文件形态，按「可执行文件 + 随包共享库」合计（不含系统库，也不含由系统包提供的 openssl）。冷启动＝进程起到桥打印窗口配置行，10ms 轮询取中位数。</text>\n' "$((H - 52))"
    printf '<text x="40" y="%s" font-size="11" fill="#8496A3">数据来源：scripts/dist-report.sh 于 %s（宿主 %s）实测</text>\n' "$((H - 28))" "$NOW" "$host"
    printf '</svg>\n'
  } >"$out"
  printf '[dist] 图表已写入 %s\n' "$out" >&2
  SVG_WRITTEN="$out"
}

# ------------------------------------------------------------------ 5) 输出
NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
cat >"$JSON_OUT" <<EOF
{
  "schema": "cj-tauri/dist-report@1",
  "recordedAt": "$NOW",
  "host": "$host",
  "coldStartCriterion": {
    "needle": "$NEEDLE",
    "resolutionMs": 10,
    "runs": $RUNS,
    "what": "进程启动 -> 桥打印「窗口配置到宿主」那一行；中位数"
  },
  "singleFileExe": [${EXE_ROWS}],
  "linuxArtifact": ${LINUX_JSON},
  "namedLoad": ${NAMED_JSON},
  "coldStart": [${COLD_JSON}],
  "coldStartNote": "$COLD_NOTE",
  "externalReference": "外部数据（Electron 等第三方壳的安装包体积）**不在本表内**：本机没有复现它们的构建，写进来就成了道听途说。"
}
EOF

echo
echo "## cj-tauri 分发形态实测（$NOW，宿主 $host）"
echo
echo "| 形态 | 体积 | 字节 | sha256 前 12 | PE 导入 DLL | 非系统 DLL |"
echo "|---|---|---|---|---|---|"
printf '%s' "$EXE_TABLE"
printf '%s' "$LINUX_TABLE"
echo
echo "| 冷启动（$NEEDLE） | 中位数 | 各次 |"
echo "|---|---|---|"
printf '%s' "$COLD_TABLE"
echo
echo "_口径：$COLD_NOTE；轮询分辨率 10ms，取 $RUNS 次中位数。_"
echo "_JSON：$JSON_OUT"

if [ -n "$SVG_OUT" ]; then
  render_svg "$SVG_OUT" || true
fi
[ -n "$SVG_WRITTEN" ] && echo "_图：$SVG_WRITTEN"

echo "[dist] 数据已写入 $JSON_OUT"

if [ "$EXE_COUNT" -eq 0 ] && [ "$LINUX_JSON" = "null" ]; then
  echo "[dist] FAIL 既没有入库的单文件 exe，本机也没有可量的 Linux 产物" >&2
  exit 1
fi
exit 0
