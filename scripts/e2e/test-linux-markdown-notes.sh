#!/usr/bin/env bash
# e2e/test-linux-markdown-notes.sh — Linux 实机 E2E：Markdown 笔记示例（examples/markdown-notes）
#
# 验的是完整一跳：**页面 → 桥 → IPC → 能力校验 → fs/store 插件 → 文件系统 → 回到页面渲染**。
# 与 linux-bridge 的区别在「有没有真数据落地」：这条链让页面自己写文件、读回来、列目录、按结构断言，
# 再故意去碰**允许范围之外**的路径，看共享层（src/scope.cj）有没有把它拦下来。
#
# 双侧对账（本示例自检的取信方式）：
#   页面侧 —— 每条断言经 `report` 命令回投，仓颉侧 eprintln 成 `[frontend] SELFCHECK …`；
#   桥侧   —— 越界被拒在 stderr 留 `[cj-tauri] scope denied (fs): …`（页面自己说「我被拒了」不算数，
#             必须能在宿主侧看到同一次拒绝）。
#
# 用法：bash scripts/e2e/test-linux-markdown-notes.sh
#   - 无 DISPLAY 时自动在 Xvfb 下重跑（lib.sh 的 e2e_ensure_display）
#   - 在非 Linux 上默认跳过；CI 里设 CJ_TAURI_E2E_REQUIRE=linux 可让「错机」变成失败
#
# 证据：dist/e2e-evidence/linux-markdown-notes.json（+ 同名 .log）
set -u

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

e2e_require_platform linux
e2e_ensure_display
e2e_begin "linux-markdown-notes"

EXAMPLE="$E2E_ROOT/examples/markdown-notes"
APP="$EXAMPLE/target/release/bin/main"
WS_DIR="$EXAMPLE/notes"
BUILD_LOG="$E2E_ROOT/dist/e2e-evidence/linux-markdown-notes.build.log"
E2E_NOTE="工作区 notes/ 由脚本播种；页面自检 21 条（含越界三连与聚合行顺序），桥侧留同一次 scope 拒绝"

# ------------------------------------------------------------------ 1) 环境与构建
# SDK 环境**无条件**准备：应用要加载 libcjtbridge.so 与仓颉运行时（含 stdx 动态库），
# 少一个的表象是「产物在、一跑就退」（`libcangjie-runtime.so: cannot open shared object file`），
# 很容易被误读成构建问题。
if ! e2e_ensure_sdk; then
  e2e_fail "找不到仓颉 SDK（设 CANGJIE_HOME）：应用需要运行时库才能启动"
  exit 1
fi

if [ ! -x "$APP" ]; then
  e2e_info "示例未构建，先 cjpm build（日志 $BUILD_LOG）"
  if ! ( cd "$EXAMPLE" && cjpm build ) >"$BUILD_LOG" 2>&1; then
    e2e_fail "示例构建失败，见 $BUILD_LOG"
    tail -20 "$BUILD_LOG" >&2
    exit 1
  fi
  e2e_info "示例构建完成"
fi

# ------------------------------------------------------------------ 2) 播种工作区
# 插件面里**故意没有 mkdir**（建目录属于装配期的事，不该由一个页面能调的命令持有），
# 所以工作区由脚本保证存在——这也是「应用自己建目录」与「宿主替它建」两条路的划线处。
mkdir -p "$WS_DIR"
# 上一轮自检的探针文件如果残留（比如进程被强杀在收尾前），先清掉：本轮的「列表里有什么」才有确定性。
rm -f "$WS_DIR/.selfcheck-probe.md" "$WS_DIR/.selfcheck-probe2.md"

if [ ! -f "$WS_DIR/欢迎.md" ]; then
  cat > "$WS_DIR/欢迎.md" <<'EOF'
# 欢迎使用 cj-tauri Markdown 笔记

这是**仓颉后端** + **系统 WebView** 的笔记示例：文件树、编辑、实时预览全部走 IPC。

## 能做什么

- 左侧列目录（`fs:list`），点开就读（`fs:readText`）
- 中间改，右边实时预览（**自写的 Markdown 子集**，不引第三方库）
- `Ctrl+S` 保存（`fs:writeText`）；重命名 = 写新 + 删旧；删除要按两次确认
- 关掉再开，上次开的笔记还在（`store` 插件记着）

> 路径只放行 notes/ 与它下面：去读 ../src/main.cj 会被共享层的 scope 判拒，
> 桥 stderr 里留一行 `[cj-tauri] scope denied (fs): …`。

```js
var hello = "cj-tauri";
```

1. 第一条
2. 第二条

---

结束。
EOF
  e2e_info "已播种 $WS_DIR/欢迎.md"
fi

# ------------------------------------------------------------------ 3) 自检模式跑一轮
export CJ_MARKDOWN_SELFCHECK=1
e2e_set_cwd "$EXAMPLE"
e2e_run_app "$APP"

rc=0
# 等的是**页面自己算出来的聚合行**（跑完所有断言才打），不是「窗口出现」：
# 窗口照起、命令全被拒的情况下也能看到窗口，那种绿毫无意义。
if ! e2e_wait_log "[frontend] SELFCHECK DONE" 90; then
  rc=1
fi
sleep 1                      # 让最后几条回投落盘，别在上面那行之后被收尾截断
e2e_stop_app

# ------------------------------------------------------------------ 4) 取证（needle 用整行前缀或不撞词的长子串）
# 两个**必须记住**的写法约束（都实测踩过）：
#   ① 断言名里**不能有 `:`**——证据层按第一个 `:` 拆 name:needle（lib.sh 的 e2e_finalize），
#      名字带冒号会被劈成「名字=前半段」，needle 变成长长一串 → 明细明明在日志里也判未命中；
#   ② 断言名里**不能有反引号**——它在双引号里是命令替换，`..` 会被当命令执行
#      （现象是 `line N: ..: command not found`，名字还被替换成空）。
e2e_assert "示例应用启动"          "[markdown-notes] main start (selfcheck=true)"
e2e_assert "能力清单已加载"        "[cj-tauri] 已自动加载 capabilities/：1 个清单"
e2e_assert "自检已开始"            "[frontend] SELFCHECK BEGIN"

e2e_assert "三栏布局成立"          "[frontend] SELFCHECK PASS layout-three-columns"
e2e_assert "Markdown 块级渲染"     "[frontend] SELFCHECK PASS md-blocks"
e2e_assert "Markdown 行内样式"     "[frontend] SELFCHECK PASS md-inline"
e2e_assert "围栏代码块"            "[frontend] SELFCHECK PASS md-fence"
e2e_assert "正文不构成注入点"      "[frontend] SELFCHECK PASS md-no-html-injection"
e2e_assert "整行图片显式降级"      "[frontend] SELFCHECK PASS md-image-degraded"

e2e_assert "写入后读回一致"        "[frontend] SELFCHECK PASS fs-readText-roundtrip"
e2e_assert "列表形状正确"          "[frontend] SELFCHECK PASS fs-list-shape"
e2e_assert "改名=写新+删旧"        "[frontend] SELFCHECK PASS fs-remove-rename-plan"
e2e_assert "删不存在必须报错"      "[frontend] SELFCHECK PASS fs-remove-missing-rejected"
e2e_assert "目录不可被 remove"     "[frontend] SELFCHECK PASS fs-remove-dir-refused"

e2e_assert "越界读被拒（页面侧）"  "[frontend] SELFCHECK PASS scope-deny-readText"
e2e_assert "越界列目录被拒"        "[frontend] SELFCHECK PASS scope-deny-list"
e2e_assert "「..」绕行仍被拒"      "[frontend] SELFCHECK PASS scope-deny-dotdot"
# 双侧对账：同一次拒绝在**桥侧**也要留痕（页面说「我被拒了」不能自证）
e2e_assert "越界读被拒（共享层）"  "[cj-tauri] scope denied (fs): src/main.cj"
e2e_assert "规范化后照样拒"        "[cj-tauri] scope denied (fs): notes/../src/main.cj"
e2e_assert "remove 挡在目录之前"   "fs:remove refused: is a directory"

e2e_assert "store 写读一致"        "[frontend] SELFCHECK PASS store-set-get"
e2e_assert "store 删除生效"        "[frontend] SELFCHECK PASS store-delete"
e2e_assert "文件树与列表一致"      "[frontend] SELFCHECK PASS ui-tree-rows-match-list"
e2e_assert "预览已渲染出节点"      "[frontend] SELFCHECK PASS ui-preview-nodes"
e2e_assert "自检聚合行"            "[frontend] SELFCHECK DONE passed="

# ------------------------------------------------------------------ 5) 反面与收尾自检（不在断言表里，直接判 rc）
# ① 不许有 FAIL 行：聚合行只说明「DONE 那一刻」的计数，明细里任何一条红都不放过。
if grep -aq "SELFCHECK FAIL" "$E2E_LOG" 2>/dev/null; then
  e2e_fail "页面自检出现 FAIL 行："
  grep -a "SELFCHECK FAIL" "$E2E_LOG" | tail -10 >&2
  rc=1
fi

# ② PASS 条数不得少于 21：改动不小心删掉几条断言时，聚合行照样是 passed=0 failed=0 的「绿」。
passes="$(grep -a -c "SELFCHECK PASS" "$E2E_LOG" 2>/dev/null || true)"
if [ "${passes:-0}" -lt 21 ]; then
  e2e_fail "自检 PASS 条数只有 ${passes:-0}，少于 21——是不是有断言没跑？"
  rc=1
fi

# ③ 聚合行必须与明细**对得上**：判据是计数一致，不是「DONE 落在最后一行」。
#    页面每条断言都经 `report` 回投，而 `report` 是**异步命令**——命令按 worker 并发分发
#    （AGENTS §2：同一命令并发调用不保证执行顺序），所以日志里的行序**本就不保证**。
#    第一版按「最后一条必须是 DONE」写，实测被行序骗红（DONE 之后还落了两条明细）；
#    反过来「只看有没有 FAIL 行」也会漏——那两条落晚了的明细如果红了，聚合行早就打完了。
#    真正的判据是：DONE 里的 passed 等于 PASS 明细条数、failed 等于 0，两者缺一不可。
done_line="$(grep -a "SELFCHECK DONE" "$E2E_LOG" 2>/dev/null | tail -1)"
done_passed="$(printf '%s' "$done_line" | sed -n 's/.*passed=\([0-9][0-9]*\).*/\1/p')"
done_failed="$(printf '%s' "$done_line" | sed -n 's/.*failed=\([0-9][0-9]*\).*/\1/p')"
if [ "${done_failed:-1}" != "0" ]; then
  e2e_fail "聚合行报告 failed=${done_failed:-?}（明细条数 passes=${passes:-0}）：$done_line"
  rc=1
fi
if [ "${done_passed:-0}" != "${passes:-0}" ]; then
  e2e_fail "聚合行 passed=${done_passed:-?} 与明细 PASS 条数 ${passes:-0} 不一致——有断言没落下或被行序吃掉"
  rc=1
fi

# ④ 工作区要恢复原样：自检自己建的探针文件必须已经删掉（收尾断了就是「会攒垃圾」的证据）
leftover="$(ls -1 "$WS_DIR"/.selfcheck-probe*.md 2>/dev/null | head -3 || true)"
if [ -n "$leftover" ]; then
  e2e_fail "自检没把探针文件收干净：$leftover"
  rc=1
fi

e2e_finalize || rc=1
exit $rc
