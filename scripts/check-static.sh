#!/usr/bin/env bash
# check-static.sh — 不依赖仓颉 SDK 的静态门禁（提交前本地跑，CI 也跑同一份）
#
# 检查项：
#   1. 版本号一致（复用 scripts/check-version.sh）
#   2. markdown 代码围栏成对（``` 计数为偶数；落单的围栏会把后半篇吞成代码块）
#   3. 脚手架模板里的 {{占位符}} 都在 scaffold.cj 的渲染表里（否则生成的工程会残留占位符）
#   4. .bat / .ps1 纯 ASCII（cmd 的 OEM 码页与 PowerShell 5.1 会吃坏中文注释）
#   5. 被跟踪的文件里没有构建产物（target/、*.dll、*.log、cjpm.lock）
#   6. 插件/命令不引用核心内部件 + 插件实现文件的包边界（src/plugins/）
#   7. dist/e2e-evidence/*.json 可对账（结构 + summary 全绿；没有就跳过）
#   8. C 桥公共核心自检（native/tests/test_bridge_core.c + 桩平台）：只需 C 编译器，
#      不需要 SDK / 图形栈；本机没有 C 编译器时该项自行跳过（退出码仍为 0）
#   9. E2E 入口卫生（scripts/e2e/test-*.sh）：必须 source 公共层并声明平台守卫——
#      没有守卫的入口会把「跑在错的机器上」变成静默通过
#  10. 官网静态自检（website/）：引用存在性、零外部依赖、中英文案覆盖、锚点与结构、OG 尺寸
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
# 例外：随包分发的 cjh 依赖 DLL。cjh 是仓颉程序，Windows 侧那几个 DLL 由它**按名字 LoadLibrary**
# （不在 PE 导入表里，漏了就是起不来 / https 全灭），所以必须随包分发——.gitignore 为此开了
# `!vendor/cjh/bin/**` 的口子（AGENTS §5）。白名单只认「vendor/cjh/bin/ 这棵树里的 .dll」，
# 不放宽 `*.dll` 的全局口径，且放行了哪几个会打进日志，便于复核。
section "没有被跟踪的构建产物"
before=$fails
tracked_bad=$(git ls-files -z | tr '\0' '\n' | grep -E '(^|/)target/|\.dll$|\.log$|(^|/)cjpm\.lock$' || true)
dll_allow='^examples/[^/]+/vendor/cjh/bin/.*\.dll$'
allowed_dll=$(printf '%s\n' "$tracked_bad" | grep -E "$dll_allow" || true)
hits=$(printf '%s\n' "$tracked_bad" | grep -vE "$dll_allow" || true)
if [ -n "$hits" ]; then
    bad "以下文件不该被跟踪："
    printf '%s\n' "$hits" | sed 's/^/        /'
else
    ok "无 target/、*.dll、*.log、cjpm.lock"
fi
if [ -n "$allowed_dll" ]; then
    printf '  note  白名单放行随包 cjh 的依赖 DLL %s 个（依名字加载，必须随包）\n' "$(printf '%s\n' "$allowed_dll" | wc -l)"
fi

# ------------------------------------------- 6. 插件/命令不得引用核心内部件
# 架构契约（AGENTS §2）：依赖方向单向 app → host / ipc_hub → capability，
# 插件与命令通过回调注入协作，不得偷用核心内部符号（HostGlobals 等）。
# 插件物理边界在 src/plugins/ 子包，**一个插件一个子包**（package cjTauri.plugins.<名字>），
# 门禁按包边界查——子包内任何文件引用核心内部符号都算违规，不依赖 plugin_ 前缀命名约定。
# git pathspec 的 * 会跨目录匹配，src/plugins/*.cj 覆盖各插件子包。
section "插件与命令不引用核心内部件"
before=$fails
hits=$(git grep -nE 'HostGlobals|IpcHub\(' -- 'src/plugins/*.cj' 'src/api_*.cj' || true)
if [ -n "$hits" ]; then
    bad "以下插件/命令文件引用了核心内部符号："
    printf '%s\n' "$hits" | sed 's/^/        /'
else
    ok "$(git ls-files 'src/plugins/*.cj' 'src/api_*.cj' | wc -l) 个插件/命令文件无核心内部件引用"
fi

# 6b. 包边界：src/ 顶层不得再出现插件实现文件（防止回流平铺），插件实现只准在 src/plugins/
section "插件实现文件物理边界"
before=$fails
# git 的通配会跨目录（src/*.cj 连 src/plugins/ 一起列），按显式列表过滤顶层
stray=$(git ls-files 'src' | grep '^src/[^/]*\.cj$' | grep -E '(^src/plugin_|_bridge\.cj$)' | grep -v '^src/clipboard_bridge.cj' | grep -v '^src/log_bridge.cj' || true)
if [ -n "$stray" ]; then
    bad "src/ 顶层发现插件实现/FFI 桥文件（应移入 src/plugins/；例外：clipboard_bridge.cj / log_bridge.cj 属核心宿主 FFI）："
    printf '%s\n' "$stray" | sed 's/^/        /'
fi
# 6b-2. 插件文件必须落在插件自己的子包目录（一个插件一个子包），不准直接平铺在 src/plugins/ 根
flat=$(git ls-files 'src/plugins' | grep '^src/plugins/[^/]*\.cj$' | grep -v '^src/plugins/plugins.cj' || true)
if [ -n "$flat" ]; then
    bad "src/plugins/ 根发现插件实现文件（一个插件一个子包：src/plugins/<名字>/，package cjTauri.plugins.<名字>）："
    printf '%s\n' "$flat" | sed 's/^/        /'
fi
if [ -z "$stray" ] && [ -z "$flat" ]; then
    ok "插件实现全部在 src/plugins/<名字>/ 子包，src/ 顶层只留框架核心"
fi

# ------------------------------------------------- 7. E2E 证据可对账
# dist/e2e-evidence/*.json 由 scripts/e2e-evidence.sh 产出（平台 / 运行时版本 / 每条
# 断言的命中次数）。矩阵里的 supported 要能指到一份可复核的证据，所以这份证据本身也要
# 过一道：结构合法、schema 对得上、summary 是绿的。没有文件（没跑过实机）就跳过。
section "E2E 证据可对账"
before=$fails
ev_files=$(ls dist/e2e-evidence/*.json 2>/dev/null || true)
if [ -z "$ev_files" ]; then
    ok "无 dist/e2e-evidence/*.json（未跑实机取证），跳过"
elif ! command -v python3 >/dev/null 2>&1; then
    ok "本机无 python3，跳过证据校验（$(( $(printf '%s\n' "$ev_files" | wc -l) )) 份未校验）"
else
    ev_bad=0
    for f in $ev_files; do
        if ! err=$(python3 - "$f" <<'PY' 2>&1
import json, sys
d = json.load(open(sys.argv[1], encoding="utf-8"))
assert d["schema"] == "cj-tauri/e2e-evidence@1", "schema 不是 cj-tauri/e2e-evidence@1"
assert d["platform"] in ("linux", "windows", "unknown"), "platform 取值非法"
s = d["summary"]
assert isinstance(d["assertions"], list), "assertions 不是数组"
assert s["total"] == len(d["assertions"]), "summary.total 与断言条数不符"
assert s["passed"] + s["failed"] == s["total"], "passed + failed != total"
if not s["ok"]:
    raise SystemExit("summary.ok 为 false（这份证据记录的是一次未全绿的实机）")
PY
); then
            bad "证据文件不合法：$f"
            printf '        %s\n' "$err"
            ev_bad=$((ev_bad + 1))
        fi
    done
    if [ "$ev_bad" -eq 0 ]; then
        ok "$(( $(printf '%s\n' "$ev_files" | wc -l) )) 份 E2E 证据结构合法且全绿"
    fi
fi

# ------------------------------------------------- 8. C 桥公共核心自检
section "C 桥公共核心自检"
before=$fails
# 桩平台编译 native/tests/test_bridge_core.c + native/core/bridge_core.c 并跑断言；
# 不需要 SDK / 图形栈，只需 C 编译器（没有就自己跳过，退出码仍为 0）
if bash scripts/test-bridge-core.sh; then
    ok "bridge_core 纯逻辑自检通过（回投批处理 / 对话框状态机 / 生命周期标志）"
else
    bad "bridge_core 自检失败（明细见上）"
fi

# ------------------------------------------- 8b. 宿主能力位两侧逐位对齐
# AGENTS §2 的契约：`CJ_CAP_*` 在 C 桥（native/core/bridge_core.h）与仓颉侧（src/host.cj）里
# 必须**逐位一致**，「两侧不许各写各的」。这句话此前只是两边注释里的约定，没有任何机制拦着，
# 于是真的漂过一位：C 侧的 `CJ_CAP_NOTIFICATION = 8` 置了（Linux / Windows 都置），仓颉侧既没有
# 常量也没有可读字段，`system:host` 的返回里根本没有 notification 键（页面读到 undefined、不是
# false）——而两侧注释还各自写着「逐位对齐」。所以按名字比对两张表：任一侧多一位、少一位、
# 或同一位值不同，都在这里红。
section "宿主能力位两侧逐位对齐"
before=$fails
cap_h=$(grep -oE '^#define[[:space:]]+CJ_CAP_[A-Z_]+[[:space:]]+[0-9]+' native/core/bridge_core.h \
    | awk '{print $2, $3}' | sort || true)
cap_cj=$(grep -oE 'public const CJ_CAP_[A-Z_]+: Int32 = [0-9]+' src/host.cj \
    | sed -E 's/^public const (CJ_CAP_[A-Z_]+): Int32 = ([0-9]+)$/\1 \2/' | sort || true)
if [ -z "$cap_h" ] || [ -z "$cap_cj" ]; then
    bad "能力位表解析为空（header 侧 $(printf '%s' "$cap_h" | wc -l) 条 / 仓颉侧 $(printf '%s' "$cap_cj" | wc -l) 条）——写法变了就同步改本项的正则，别让它空过"
else
    drift=$(diff <(printf '%s\n' "$cap_h") <(printf '%s\n' "$cap_cj") || true)
    if [ -n "$drift" ]; then
        bad "两侧能力位不一致（< 只在 bridge_core.h，> 只在 src/host.cj，数值不同也会列出）："
        printf '%s\n' "$drift" | sed 's/^/        /'
    else
        ok "$(printf '%s\n' "$cap_h" | wc -l) 个能力位在 C 桥与仓颉侧逐位一致"
    fi
fi

# ------------------------------------------------- 9. E2E 入口卫生
# 两个要求，缺一个都会让「实机验证」退化成自说自话：
#   - source scripts/e2e/lib.sh：平台判定、断言收集、证据收口、应用收尾都在公共层，
#     各入口自己再写一份，语义迟早分叉；
#   - 调用 e2e_require_platform：没有守卫的入口在别的平台上照样返回 0，
#     「没跑」就被记成「通过」（本仓历史上最容易出的假绿）。
# 这里用 shell 通配而不是 git ls-files：入口可能是本轮新增、尚未入跟踪的文件。
section "E2E 入口守卫"
before=$fails
e2e_entries=0
for f in scripts/e2e/test-*.sh; do
    [ -e "$f" ] || continue
    e2e_entries=$((e2e_entries + 1))
    grep -q 'source .*lib\.sh' "$f" || bad "$f 没有 source scripts/e2e/lib.sh（公共层未复用）"
    grep -q 'e2e_require_platform' "$f" || bad "$f 没有调用 e2e_require_platform（平台守卫缺失）"
done
if [ "$e2e_entries" -eq 0 ]; then
    bad "scripts/e2e/ 下没有任何 test-*.sh 入口（实机验证无从执行）"
elif [ "$fails" -eq "$before" ]; then
    ok "$e2e_entries 个 E2E 入口都复用了公共层并声明了平台守卫"
fi

# ------------------------------------------------- 10. 官网静态自检
# website/ 是「给人看」的产物，最容易出的错都不需要浏览器就能查出来：漏一份英文（英文态
# 露出中文）、死锚点、引用了一张已改名的截图、手误把 markdown 的 ** 当强调写进正文、
# 顺手引了 CDN——于是把 scripts/site-check.sh 的快速档并进常规门禁（无浏览器、断网可跑）。
section "官网静态自检"
before=$fails
if SITE_CHECK_QUICK=1 bash scripts/site-check.sh; then
    ok "官网静态自检通过（引用存在性 / 零外部依赖 / 中英文案覆盖 / 锚点与结构 / OG 尺寸）"
else
    bad "官网静态自检失败（明细见上）"
fi

# ------------------------------------------------------------------ 汇总
printf '\n'
if [ "$fails" -eq 0 ]; then
    echo "[OK] 静态检查全部通过"
    exit 0
fi
echo "[FAIL] 静态检查有 $fails 项未通过"
exit 1
