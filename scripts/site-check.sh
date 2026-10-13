#!/usr/bin/env bash
# ============================================================================
# site-check.sh —— 官网（website/）自检：不需要仓颉 SDK，断网也能跑大部分项
#
# 用法：
#   bash scripts/site-check.sh              # 快速档：静态断言（含中英文案覆盖检查）
#   bash scripts/site-check.sh --shots      # 再抓两张无头截图（需要 firefox）
#   bash scripts/site-check.sh --links      # 再联网核对页面里的外部链接
#
# 为什么要这么一份脚本：官网是「给人看」的产物，最容易出的错是——某个 data-en
# 漏了导致英文态露出中文、链接写死了一个 404、截图路径改名忘了同步、手误把
# markdown 的 ** 直接写进正文。这些都不需要浏览器就能查出来，所以放进常规门禁
# （check-static.sh 会调本脚本的快速档）。
#
# 环境变量：
#   SITE_CHECK_QUICK=1   跳过抓图与外链（CI 用的档位）
#   SITE_SHOT_DIR=<dir>  截图落盘目录，默认 /tmp/cj-tauri-shots
# ============================================================================
set -uo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SITE="$ROOT/website"
INDEX="$SITE/index.html"
CSS="$SITE/assets/style.css"
SHOT_DIR="${SITE_SHOT_DIR:-/tmp/cj-tauri-shots}"

DO_SHOTS=0
DO_LINKS=0
for arg in "$@"; do
  case "$arg" in
    --shots) DO_SHOTS=1 ;;
    --links) DO_LINKS=1 ;;
    -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
    *) echo "[site-check] unknown option: $arg" >&2; exit 2 ;;
  esac
done

OKS=0; FAILS=0; SKIPS=0; WARNS=0
ok()   { OKS=$((OKS+1));   echo "[site-check] ok    $1"; }
fail() { FAILS=$((FAILS+1)); echo "[site-check] FAIL  $1"; }
skip() { SKIPS=$((SKIPS+1)); echo "[site-check] skip  $1"; }
warn() { WARNS=$((WARNS+1)); echo "[site-check] warn  $1"; }

# ---------- 0. 站点必须存在 ------------------------------------------------
if [ ! -f "$INDEX" ]; then
  echo "[site-check] FAIL  website/index.html 不存在" >&2
  exit 1
fi

# ---------- 1. 本地资源引用都要落地 ----------------------------------------
# 从 src/href 抽出所有本地相对路径（跳过 http(s)/mailto/#/data:），逐个查存在性。
refs=$(grep -oE '(src|href)="[^"]*"' "$INDEX" | sed -E 's/^[a-z]+="([^"]*)"$/\1/' | sort -u)
missing=0
while IFS= read -r ref; do
  [ -z "$ref" ] && continue
  case "$ref" in http*|mailto:*|"#"*|data:*) continue ;; esac
  # 去掉可能的 ?query/#frag
  clean="${ref%%\?*}"; clean="${clean%%#*}"
  if [ ! -e "$SITE/$clean" ]; then
    fail "index.html 引用的本地资源不存在：$ref"
    missing=$((missing+1))
  fi
done <<< "$refs"
[ "$missing" -eq 0 ] && ok "index.html 的本地引用全部存在（$(printf '%s\n' "$refs" | grep -cE '^(assets|\./)' || true) 条）"

# CSS 里若有 url(...) 指向本地文件，同样要存在
css_refs=$(grep -oE 'url\((["'"'"']?)[^)"'"'"']+\1\)' "$CSS" 2>/dev/null | sed -E 's/^url\(["'"'"']?([^)"'"'"']*)["'"'"']?\)$/\1/' | sort -u || true)
if [ -n "$css_refs" ]; then
  while IFS= read -r r; do
    [ -z "$r" ] && continue
    case "$r" in data:*|http*) continue ;; esac
    [ -e "$SITE/$r" ] || fail "style.css 引用的资源不存在：$r"
  done <<< "$css_refs"
  ok "style.css 的本地 url() 引用全部存在"
else
  ok "style.css 不引用任何本地资源（页面的零外部依赖承诺由此成立）"
fi

# ---------- 2. 零外部依赖 --------------------------------------------------
# 会发起网络请求的标签（script/link/img）不许指向任何外部地址：
# 这是站点自己的承诺（不引 CDN、不引 Web Font、无统计脚本）。
# rel="canonical" 是给搜索引擎看的元信息、不产生请求，因此排除。
ext=$(grep -oE '<(script|link|img)[^>]*(src|href)="(https?:)?//[^"]*"' "$INDEX" | grep -v 'rel="canonical"' || true)
if [ -n "$ext" ]; then
  fail "页面里有外部 <script>/<link>/<img> 引用（承诺零外部依赖）："
  printf '        %s\n' "$ext"
else
  ok "零外部依赖：没有 <script>/<link>/<img> 指向站外（canonical 除外）"
fi
grep -qE '<link[^>]*rel="canonical"' "$INDEX" && ok "有 canonical 链接（GitHub Pages 主域名，供搜索引擎去重）"
if grep -qiE '@import[^;]*(https?:)?//' "$CSS" 2>/dev/null; then
  fail "style.css 里有外部 @import"
else
  ok "style.css 无外部 @import"
fi
# 纯 http:// 混入（跨域混合内容隐患）
if grep -qE '(src|href)="http://' "$INDEX"; then
  fail "页面里有 http:// 明文引用（应统一 https）"
else
  ok "没有 http:// 明文引用"
fi

# ---------- 3. 正文里不许残留 markdown 记号 ---------------------------------
# 这条是被自己坑出来的：仓颉源码里写 **强调** 是注释，写进 HTML 就是字面星号。
md=$(grep -oE '\*\*[^*<>]+\*\*' "$INDEX" || true)
if [ -n "$md" ]; then
  fail "正文里残留 markdown 记号（应为 <strong>）：$md"
else
  ok "正文无 markdown 残留（** 只出现在路径通配里）"
fi
for needle in TODO 占位 XXX FIXME; do
  if grep -q "$needle" "$INDEX"; then
    fail "页面里还有未处理标记：$needle"
  fi
done
ok "没有 TODO/占位/XXX/FIXME 残留"

# ---------- 4. 中英文案覆盖 -------------------------------------------------
# 规则：任何「含汉字的文本」所在的最内层元素必须带 data-en（或 alt/title 走
# data-en-alt / data-en-title）。漏一个，英文态就会冒出中文。
if command -v python3 >/dev/null 2>&1; then
  cov=$(python3 - "$INDEX" <<'PY'
import sys
from html.parser import HTMLParser

EN_ATTRS = ("data-en", "data-en-alt", "data-en-html", "data-en-title", "data-en-aria")
VOID = {"img", "br", "meta", "link", "input", "hr", "source", "area", "base", "col", "embed", "track", "wbr"}
# 这些子树有意不翻译：代码示例/终端记录里的中文注释、<script> 里的 JSON-LD 数据
# （数据不是文案，翻译它是错的）。
SKIP_TAGS = {"script", "style", "pre", "code", "svg", "path"}

def has_cjk(s):
    return any('\u3400' <= ch <= '\u9fff' for ch in s)

class Probe(HTMLParser):
    def __init__(self):
        super().__init__(convert_charrefs=True)
        # 栈项：(标签, 带任一 data-en*, 该子树不翻译, 会替换整个子树)
        # 「替换子树」只看 data-en / data-en-html：它们把 innerHTML 换成纯文本/新 HTML；
        # 而 data-en-aria / data-en-title 只改属性，子节点照旧——两者必须分开判，
        # 否则 <nav data-en-aria=…> 里的一串导航链接会被误报成「嵌套冲突」。
        self.stack = []
        self.bad = []        # 漏翻：含中文但整条祖先链都没有会替换子树或自带 data-en 的元素
        self.nested = []     # 嵌套冲突：会被替换的子树里还有 data-en*（那层的英文永远用不上）
    def handle_starttag(self, tag, attrs):
        names = dict(attrs)
        has_en = any(a in names for a in EN_ATTRS)
        replaces = ("data-en" in names) or ("data-en-html" in names)
        inherited_skip = any(c[2] for c in self.stack)
        no_i18n = inherited_skip or (tag in SKIP_TAGS) or ("data-no-i18n" in names)
        if has_en and any(c[3] for c in self.stack):
            self.nested.append((self.getpos()[0], "<%s>" % tag))
        for attr, en_attr in (("alt", "data-en-alt"), ("title", "data-en-title"), ("aria-label", "data-en-aria")):
            v = names.get(attr, "")
            if v and has_cjk(v) and en_attr not in names and not no_i18n:
                self.bad.append((self.getpos()[0], '<%s %s="%s"> 缺 %s' % (tag, attr, v[:30], en_attr)))
        if tag not in VOID:
            self.stack.append((tag, has_en, no_i18n, replaces))
    def handle_startendtag(self, tag, attrs):
        self.handle_starttag(tag, attrs)
        if tag not in VOID and self.stack:
            self.stack.pop()
    def handle_endtag(self, tag):
        for i in range(len(self.stack) - 1, -1, -1):
            if self.stack[i][0] == tag:
                del self.stack[i:]
                return
    def handle_data(self, data):
        if not has_cjk(data) or not data.strip():
            return
        # 判据：自己带 data-en（自身会被替换），或某个会替换子树的祖先（整段跟着换）
        covered = self.stack[-1][1] if self.stack else False
        if not covered:
            covered = any(c[3] for c in self.stack)
        skipped = any(c[2] for c in self.stack)
        if not covered and not skipped:
            self.bad.append((self.getpos()[0], data.strip()[:40]))

p = Probe()
with open(sys.argv[1], encoding="utf-8") as fh:
    p.feed(fh.read())
for line, what in p.bad:
    print("index.html:%d  %s" % (line, what))
for line, what in p.nested:
    print("index.html:%d  %s 嵌在另一个 data-en 里（外层切换会把它整段换成纯文本）" % (line, what))
sys.exit(1 if (p.bad or p.nested) else 0)
PY
) && cov_rc=0 || cov_rc=$?
  if [ "$cov_rc" -eq 0 ]; then
    ok "中英文案覆盖：所有含中文的文本/alt/title 都配了英文"
  else
    fail "以下节点缺英文（英文态会露出中文）："
    printf '        %s\n' "$cov"
  fi
else
  skip "python3 不可用，中英文案覆盖检查未跑"
fi

# ---------- 5. 结构与可访问性 ------------------------------------------------
# 每个 <img> 都要有 alt（装饰性图明确写 alt=""）
n_altmiss=$(grep -oE '<img[^>]*>' "$INDEX" | grep -vc 'alt=' || true)
if [ "${n_altmiss:-0}" -gt 0 ]; then
  fail "$n_altmiss 个 <img> 没有 alt"
else
  ok "所有 <img> 都带 alt（装饰性图用空 alt）"
fi

# 标签页：每个 data-tab 目标都要有对应面板，且面板数与按钮数一致
tab_targets=$(grep -oE 'data-tab="[^"]*"' "$INDEX" | sed -E 's/data-tab="([^"]*)"/\1/' | sort -u)
missing_panel=0
while IFS= read -r p; do
  [ -z "$p" ] && continue
  grep -q "id=\"$p\"" "$INDEX" || { fail "标签页指向的面板不存在：$p"; missing_panel=$((missing_panel+1)); }
done <<< "$tab_targets"
[ "$missing_panel" -eq 0 ] && ok "代码区 $(printf '%s\n' "$tab_targets" | grep -c . ) 个标签页都有对应面板"

# 锚点：#xxx 链接都要有对应 id（死锚点是官网最常见的低级错）
anchors=$(grep -oE 'href="#[^"]*"' "$INDEX" | sed -E 's/href="#([^"]*)"/\1/' | sort -u)
dead=0
while IFS= read -r a; do
  [ -z "$a" ] && continue
  grep -q "id=\"$a\"" "$INDEX" || { fail "死锚点：#$a 没有对应 id"; dead=$((dead+1)); }
done <<< "$anchors"
[ "$dead" -eq 0 ] && ok "页面内锚点全部有落点（$(printf '%s\n' "$anchors" | grep -c . ) 个）"

# 语言切换按钮必须成对存在
for want in 'data-lang="zh"' 'data-lang="en"'; do
  grep -q "$want" "$INDEX" || fail "缺少语言切换按钮：$want"
done
grep -q 'data-lang="zh"' "$INDEX" && grep -q 'data-lang="en"' "$INDEX" && ok "中/英切换按钮都在"

# 关键结构：OG 元信息、唯一的 h1、跳转到主内容
for needle in 'property="og:image"' 'name="description"' '<h1' 'href="#main"'; do
  grep -q "$needle" "$INDEX" || warn "页面缺少结构项：$needle"
done

# ---------- 6. CSS 类名对得上（HTML 用到但 CSS 没定义的，多半是改错名） -------
if command -v python3 >/dev/null 2>&1; then
  orphan=$(python3 - "$INDEX" "$CSS" <<'PY'
import re, sys, html
from html.parser import HTMLParser

class Cls(HTMLParser):
    def __init__(self):
        super().__init__()
        self.seen = set()
    def handle_starttag(self, tag, attrs):
        for k, v in attrs:
            if k == "class" and v:
                self.seen.update(v.split())

p = Cls()
p.feed(open(sys.argv[1], encoding="utf-8").read())
css = open(sys.argv[2], encoding="utf-8").read()
defined = set(re.findall(r'\.([A-Za-z][A-Za-z0-9_-]*)', css))
missing = sorted(c for c in p.seen if c not in defined)
print("\n".join(missing))
PY
)
  if [ -z "$orphan" ]; then
    ok "HTML 用到的 class 在 style.css 里都有定义"
  else
    warn "以下 class 在 style.css 里找不到（拼错？还是只在 JS 里加？）：$(echo $orphan | tr '\n' ' ')"
  fi
fi

# ---------- 7. 产物体积 -----------------------------------------------------
bytes=$(du -sb "$SITE" 2>/dev/null | cut -f1)
[ -z "$bytes" ] && bytes=$(du -sk "$SITE" | cut -f1)
ok "website/ 合计 $(du -sh "$SITE" | cut -f1)（页面 + 资源 + 截图，全部随仓库分发）"
if [ -f "$SITE/assets/og.png" ]; then
  dim=$(file -b "$SITE/assets/og.png" | grep -oE '[0-9]+ x [0-9]+' | head -1)
  case "$dim" in
    "1200 x 630") ok "og.png 尺寸合规（$dim）" ;;
    *) fail "og.png 尺寸应为 1200x630，实际 ${dim:-未知}" ;;
  esac
else
  fail "assets/og.png 不存在（og:image 会 404）"
fi

# ---------- 8. 可选：外部链接核对 -------------------------------------------
if [ "$DO_LINKS" -eq 1 ] && [ "${SITE_CHECK_QUICK:-0}" != "1" ]; then
  if command -v curl >/dev/null 2>&1; then
    urls=$(grep -oE 'href="https?://[^"]*"' "$INDEX" | sed -E 's/href="([^"]*)"/\1/' | sort -u)
    bad_links=0
    while IFS= read -r u; do
      [ -z "$u" ] && continue
      code=$(curl -s -o /dev/null -m 25 -L -w '%{http_code}' "$u" || echo 000)
      case "$code" in
        2*|3*) : ;;
        *) warn "外链返回 $code：$u"; bad_links=$((bad_links+1)) ;;
      esac
    done <<< "$urls"
    [ "$bad_links" -eq 0 ] && ok "页面里的 $(printf '%s\n' "$urls" | grep -c .) 个外链都能解析"
  else
    skip "curl 不可用，外链核对未跑"
  fi
fi

# ---------- 9. 可选：无头截图（给人眼看的证据） ------------------------------
if { [ "$DO_SHOTS" -eq 1 ] || [ "${SITE_CHECK_QUICK:-0}" != "1" ]; } && [ "${SITE_CHECK_QUICK:-0}" != "1" ]; then
  if command -v firefox >/dev/null 2>&1; then
    mkdir -p "$SHOT_DIR"
    for lang in zh en; do
      url="file://$INDEX"
      [ "$lang" = "en" ] && url="$url?lang=en"
      out="$SHOT_DIR/website-$lang.png"
      if timeout 120 firefox --headless --window-size=1280,900 --screenshot="$out" "$url" >/dev/null 2>&1 && [ -s "$out" ]; then
        ok "截图 $out（$(stat -c%s "$out" 2>/dev/null || echo '?') bytes, lang=$lang）"
      else
        skip "firefox 抓图失败：lang=$lang"
      fi
    done
  else
    skip "本机没有 firefox，跳过抓图（--shots 需要它）"
  fi
fi

# ---------- 结论 ------------------------------------------------------------
echo "[site-check] summary: PASS $OKS / FAIL $FAILS / WARN $WARNS / SKIP $SKIPS"
if [ "$FAILS" -gt 0 ]; then
  echo "[site-check] 官网自检未通过" >&2
  exit 1
fi
echo "[site-check] 官网自检通过"
