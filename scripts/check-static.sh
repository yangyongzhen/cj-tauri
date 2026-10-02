#!/usr/bin/env bash
# check-static.sh — 不依赖仓颉 SDK 的静态门禁（提交前本地跑，CI 也跑同一份）
#
# 检查项：
#   1. 版本号一致（复用 scripts/check-version.sh）
#   2. markdown 代码围栏成对（``` 计数为偶数；落单的围栏会把后半篇吞成代码块）
#   3. 脚手架模板里的 {{占位符}} 都在 scaffold.cj 的渲染表里（否则生成的工程会残留占位符）
#   4. .bat / .ps1 纯 ASCII（cmd 的 OEM 码页与 PowerShell 5.1 会吃坏中文注释）
#   5. 被跟踪的文件里没有构建产物（target/、*.dll、*.log、cjpm.lock）
#   6. C 桥公共核心自检（native/tests/test_bridge_core.c + 桩平台）：只需 C 编译器，
#      不需要 SDK / 图形栈；本机没有 C 编译器时该项自行跳过（退出码仍为 0）
#
# 用法：bash scripts/check-static.sh
# 退出码：0 = 全部通过；1 = 有失败项（每项失败都会打印 FAIL 行）
#
# 坑：文件清单一律用 `git ls-files -z` + `read -d ''`。
#     git 默认把非 ASCII 文件名转义成 \344\273\266 这种形式（core.quotepath），
#     直接 `for f in $(git ls-files)` 会把这些文件当成"不存在"而静默跳过 —— 假通过。
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT" || exit 1

fails=0
section() { printf '\n== %s ==\n' "$1"; }
ok() { printf '  ok    %s\n' "$1"; }
bad() { printf '  FAIL  %s\n' "$1"; fails=$((fails + 1)); }

# ---------------------------------------------------------------- 1. 版本号
section "版本号一致"
if bash scripts/check-version.sh; then
    ok "五个位置与 CHANGELOG 一致"
else
    bad "版本号不一致（明细见上）"
fi

# ------------------------------------------------------- 2. markdown 围栏
section "文档代码围栏成对"
before=$fails
md_count=0
while IFS= read -r -d '' f; do
    md_count=$((md_count + 1))
    n=$(grep -c '^```' "$f" || true)
    if [ $((n % 2)) -ne 0 ]; then
        bad "$f 有 $n 行围栏（应为偶数，检查是否有未闭合的代码块）"
    fi
done < <(git ls-files -z '*.md')
if [ "$fails" -eq "$before" ]; then
    ok "$md_count 个 markdown 文件围栏成对"
fi

# -------------------------------------------------------- 3. 模板占位符
section "脚手架模板占位符"
before=$fails
known=$(sed -n '/func renderTemplate/,/^}/p' cli/src/scaffold.cj | grep -oE '\{\{[A-Za-z0-9_]+\}\}' | sort -u)
if [ -z "$known" ]; then
    bad "在 cli/src/scaffold.cj 的 renderTemplate 里找不到任何替换表"
else
    tpl_count=0
    while IFS= read -r -d '' f; do
        tpl_count=$((tpl_count + 1))
        while IFS= read -r ph; do
            [ -z "$ph" ] && continue
            if ! printf '%s\n' "$known" | grep -qxF "$ph"; then
                bad "cli/templates 的 $f 用了 $ph，但 scaffold.cj 不会替换它"
            fi
        done < <(grep -ohE '\{\{[A-Za-z0-9_]+\}\}' "$f" | sort -u)
    done < <(git ls-files -z 'cli/templates')
    # 反向提示（不算失败）：渲染表里声明了、但模板里没人用的占位符
    unused=""
    while IFS= read -r ph; do
        [ -z "$ph" ] && continue
        if ! git grep -qF "$ph" -- cli/templates; then
            unused="$unused $ph"
        fi
    done <<< "$known"
    if [ "$fails" -eq "$before" ]; then
        ok "$tpl_count 个模板文件的占位符都在渲染表内"
        if [ -n "$unused" ]; then
            printf '  note  渲染表里未被模板使用的占位符:%s\n' "$unused"
        fi
    fi
fi

# ----------------------------------------------------- 4. Windows 脚本 ASCII
section "Windows 脚本纯 ASCII"
before=$fails
bat_count=0
while IFS= read -r -d '' f; do
    bat_count=$((bat_count + 1))
    hits=$(LC_ALL=C grep -n '[^[:print:][:space:]]' "$f" | head -3)
    if [ -n "$hits" ]; then
        bad "$f 含非 ASCII 字节（cmd 的 OEM 码页会吞掉后续行）"
        printf '%s\n' "$hits" | sed 's/^/        /'
    fi
done < <(git ls-files -z '*.bat' '*.ps1' '*.cmd')
if [ "$fails" -eq "$before" ]; then
    ok "$bat_count 个 Windows 脚本都是纯 ASCII"
fi

# ---------------------------------------------------------- 5. 构建产物
section "没有被跟踪的构建产物"
before=$fails
hits=$(git ls-files -z | tr '\0' '\n' | grep -E '(^|/)target/|\.dll$|\.log$|(^|/)cjpm\.lock$' || true)
if [ -n "$hits" ]; then
    bad "以下文件不该被跟踪："
    printf '%s\n' "$hits" | sed 's/^/        /'
else
    ok "无 target/、*.dll、*.log、cjpm.lock"
fi

# ------------------------------------------------- 6. C 桥公共核心自检
section "C 桥公共核心自检"
before=$fails
# 桩平台编译 native/tests/test_bridge_core.c + native/bridge_core.c 并跑断言；
# 不需要 SDK / 图形栈，只需 C 编译器（没有就自己跳过，退出码仍为 0）
if bash scripts/test-bridge-core.sh; then
    ok "bridge_core 纯逻辑自检通过（回投批处理 / 对话框状态机 / 生命周期标志）"
else
    bad "bridge_core 自检失败（明细见上）"
fi

# ------------------------------------------------------------------ 汇总
printf '\n'
if [ "$fails" -eq 0 ]; then
    echo "[OK] 静态检查全部通过"
    exit 0
fi
echo "[FAIL] 静态检查有 $fails 项未通过"
exit 1
