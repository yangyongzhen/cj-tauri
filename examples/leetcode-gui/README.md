# 仓颉版力扣示例（examples/leetcode-gui）

一个用 **cj-tauri** 写的桌面版算法练习工具：左侧按分类分组的题库，中间是题目描述与
仓颉代码编辑器，下方是判题终端——点「运行」（或 Ctrl+R / 原生菜单），后端把你的代码
交给 **cjc 编译**再执行，逐个测试用例判定，结果带期望值与耗时回投到终端。
后端是**仓颉**（静态编译），前端是**系统 WebView**（HTML/CSS/JS），全程离线。

![仓颉力扣主界面](../../docs/images/example-leetcode-gui.png)

> 这篇 README 是**照着做**用的：先带你 5 分钟跑起来，再讲判题链路与几个实现细节，
> 最后是实机验收办法。题库目前 100 题、11 个分类，都是公开算法题的通用描述，
> 不含任何受版权保护的题解。

## 目录

- [1. 5 分钟跑起来](#1-5-分钟跑起来)
- [2. 玩法：选题 → 写码 → 判题](#2-玩法选题--写码--判题)
- [3. 题库与分类](#3-题库与分类)
- [4. 判题链路：cjc 编译 + harness 比对](#4-判题链路cjc-编译--harness-比对)
- [5. 三个值得单独讲的实现细节](#5-三个值得单独讲的实现细节)
- [6. 实机验收](#6-实机验收)
- [7. 文件](#7-文件)

## 1. 5 分钟跑起来

前置：本机装有仓颉 SDK 1.2.0 + stdx（环境变量 `CANGJIE_HOME` / `CANGJIE_STDX` 就绪，
判题还要靠它调 `cjc`），Linux 需 WebKitGTK 开发包。SDK 从仓颉官网下载：
<https://cangjie-lang.cn/download>（本机没装也不怕——启动时应用会自检并打印同样的
下载引导，判题入口找不到 `cjc` 时也会给出安装步骤而不是一行含糊的报错）。
框架构建见仓库根 README。

```bash
cd examples/leetcode-gui
cjpm build
# Linux：工作目录必须是本示例根（capabilities/、ui/ 按相对路径读取）
./target/release/bin/main
```

Windows 用 `cjpm build` 后运行 `target\release\bin\main.exe`（或双击，GUI 子系统不弹黑窗）。

窗口起来后：左侧点任意题目（顶部筛选条可按难度「简单/中等/困难」与状态「未做/已过」过滤）
→ 中间编辑器补全算法（语法高亮 + 行号）→ 点「运行」→ 下方终端看逐用例判定。

## 2. 玩法：选题 → 写码 → 判题

| 步骤 | 操作 | 背后发生什么 |
| --- | --- | --- |
| 选题 | 左侧点题目（按分类分组） | `leetcode:get` 取详情，`leetcode:loadDraft` 恢复你上次的草稿（没有则落模板） |
| 写码 | 编辑器里实现模板函数 | 停止输入 800ms 自动存草稿（`leetcode:saveDraft`），重启不丢 |
| 运行 | 「运行」按钮 / Ctrl+R / 原生菜单「运行」 | `leetcode:run`：cjc 编译 + 运行 + 逐用例判定 |
| 看结果 | 下方判题终端 | 编译错误原样展示（剥掉 ANSI 色码）；通过则逐用例 ✓，失败给出期望值与实际值 |

判定通过的标准：**全部测试用例 PASS**。空模板（只有 `return []` 之类的占位）会判 FAIL——
这不是 bug，恰好证明判题链路在工作；把算法补上，FAIL 就会逐条变 PASS。

## 3. 题库与分类

题库 = **内置 100 题**（离线兜底，id 1..100）+ **远程题包**（「加载更多」拉取，见 §3.1）。
内置题内嵌在 `src/problems_data.cj`（启动时解析一次），按 11 个分类分组，难度分布为
简单 45 / 中等 53 / 困难 2：

| 分类 | 题数 | 题目（举例） |
| --- | --- | --- |
| 数组与双指针 | 17 | 移动零、盛最多水的容器、合并两个有序数组、颜色分类… |
| 字符串 | 14 | 反转字符串、最长公共前缀、有效的回文、字符串解码… |
| 二叉树 | 13 | 二叉树的最大深度、中序遍历、路径总和、右视图… |
| 动态规划 | 11 | 零钱兑换、最长递增子序列、乘积最大子数组、完全平方数… |
| 哈希与计数 | 10 | 两数之和、多数元素、和为 K 的子数组… |
| 栈与队列 | 9 | 有效的括号、最小栈、每日温度、用栈实现队列… |
| 贪心 | 8 | 跳跃游戏、加油站、种花问题、拼接最大数… |
| 链表 | 6 | 反转链表、环形链表、合并两个有序链表、链表相交… |
| 递归与回溯 | 6 | 分割回文串的个数、N 皇后、单词搜索、腐烂的橘子… |
| 二分与排序 | 4 | 二分查找、搜索插入位置、寻找旋转排序数组中的最小值、搜索旋转排序数组 |
| 位运算与数学 | 2 | 只出现一次的数字、计数质数 |

### 3.1 加载更多：远程题包

题库不止内置的 100 题——侧栏底部的「⬇ 加载更多题包」会从**公共 git 仓的 raw 直链**拉取
题包 JSON，schema 校验通过后合并进题库（内置 100 题 + 题包题同池、按分类分组渲染）：

```
点「加载更多」→ leetcode:fetchMore → 下载 docs/leetcode-packs/<包名>.json
            → 校验（字段齐 / 远程 id>=200 / call+expect 是字符串）
            → 合并进题库 + 写本地缓存 problems-remote.local.json
下次启动    → 缓存自动并入（二次离线可用；缓存损坏按没有处理）
```

首发的进阶题包（递归与记忆化 / 堆与优先队列，8 题）在本仓
[`docs/leetcode-packs/advanced-1.json`](../../leetcode-packs/advanced-1.json)。

几条安全与失败口径：

| 口径 | 理由 |
| --- | --- |
| URL 白名单写死在仓颉侧（`src/remote_packs.cj` 的 `PACK_BASE_URL`），前端只传题包名，且题包名过字符白名单 | 页面可控的任意 URL 等于开放 SSRF；拼不出外链与路径穿越 |
| https 显式 `TlsClientConfig()`，走系统证书库校验 | 仓颉 HTTP 客户端不带默认 TLS；不关校验 |
| 响应体 256KB 上限，读满即停 | 不把内存交给对端 |
| 远程题 id 必须 ≥ 200 | 与内置 1..100 不冲突；重复 id 按覆盖更新（题包升版路径） |
| 下载失败**如实报错**，内置题库照常用 | 不把网络问题伪装成「没有更多题」 |

**怎么加一个新题包**：往 `docs/leetcode-packs/` 放一个同构 JSON（`packName` + `problems`
数组，格式与内置题库完全一致），再在 `src/remote_packs.cj` 的 `AVAILABLE_PACKS` 里加一行
包名——出题人提交一个 JSON 就是题库的一次更新。改完务必照 §6 的批量编译自检跑一遍新题。

### 3.2 参考答案与做题进度

- **参考答案**（头部「参考答案」按钮）：108 题（内置 100 + 题包 8）每题都有一份可直接编译
  通过的仓颉实现，**随题内嵌在题库 JSON 的 `solution` 字段**（题库文件里是 `"""…"""` 内的
  字符串，转义口径见文件头注释）——远程题包也能自带解答。
  点击载入当前题的答案（编辑器覆盖 + 立即存草稿），载入前想一想——答案适合「做不出来再看」。
- **做题进度**（头部「统计」按钮 + 徽标 + 列表对勾）：每次判题（编译失败不计）后端记一条
  `lc-stats.local.json`（`attempts` 提交次数 / `solved` 是否全过，`*.local.json` 不入库）；
  `solved` 只涨不降。顶栏徽标实时显示「已解决 N/M」，全部通过的题在左栏标题后带绿色 ✓；
  「统计」按钮在终端按分类画进度条（`█░`）。
  全部用例通过时终端即时反馈「📊 进度：已解决 N/M（P%），继续加油」。

每条题目数据带：`funcName`（要实现的函数名）、`template`（仓颉函数签名 + TODO 占位）、
`tests`（用例数组：`call` 是完整调用表达式、`expect` 是期望结果的仓颉字面量）。
想加题就照这个格式往数组里追加——加完务必跑一遍 §6 的批量编译自检，确认模板与用例能编译。

## 4. 判题链路：cjc 编译 + harness 比对

这是本示例的核心，也是它「仓颉版力扣」的由来——**你用仓颉写算法，判题也用仓颉工具链**：

1. **拼源码**：用户代码 + 生成的 harness（`main` 里逐条 `let rK = <call>`、与 `<expect>`
   字面量直接 `==` 比较、打印 `RESULT K PASS/FAIL` 行）；
2. **写盘**：`target/leetcode/<题号>-<时间戳>-<序号>/main.cj`，每次判题一个独立子目录；
3. **编译**：`cjc main.cj -o judge --static --static-std --strip-all`（`cjc` 取 `CANGJIE_HOME/bin/cjc`，
   退回 PATH）——**必须静态链接**：动态产物在运行期按 PATH 找仓颉运行时 DLL，一旦命中别代的运行时
   就是「无法定位程序输入点」载入失败（实机踩过，详见 §5.1）；`--strip-all` 把 25MB 压回 2.7MB；
4. **运行**：执行 `./judge`，解析 stdout 里的 `RESULT` 行；
5. **回投**：判定结果经 IPC 返回前端，终端逐用例着色展示。

几个设计取舍：

- **期望值用仓颉字面量直接 `==` 比较**，不比 `toString()` 的格式——字符串带不带引号、
  数组有没有空格都不会误判；
- **FAIL 行只打 `got=`**，期望值不嵌进字符串字面量（`expect` 本身可能是带引号的字符串，
  嵌进去会把 `println` 的字符串劈断——实机踩过）；
- **命令跑在 worker 线程**（框架的异步分发），编译再慢也不占宿主 UI 线程，窗口不冻。

## 5. 四个值得单独讲的实现细节

### 5.1 判题超时保护与编译缓存

判题运行不走 `executeWithOutput`（它同步阻塞到进程退出，没有超时参数）——用户代码里
一个 `while(true)` 会把 worker 线程永久钉死。做法是 `launch` + shell 重定向输出到文件 +
轮询 `isAlive()`，超过 10 秒（`JUDGE_TIMEOUT_MS`）就 `terminate()`，如实回报
「运行超过 10 秒被强制终止」（前端单独呈现为 ⏱ 超时，不冒充编译失败）。
`SubProcess` 不暴露 stdout/stderr 流（实测编译报 `'stdout' is not a member`），
所以输出经 shell 重定向进工作目录的文件再读回——这是平台差异唯一进 `@When` 的地方
（Linux `sh` / Windows `cmd.exe`）。

编译结果按「源码 + 编译开关」哈希缓存（`target/leetcode/cache/<哈希>/judge`）：反复提交同一份代码直接跳过编译
（实机取证 `compile cache hit`），判题降到 100ms 量级；冷编译实测约 0.4~1 秒——产物走静态链接 +
去符号后 2.7MB（动态版 2.1MB），每份**唯一**源码占一个缓存条目，体积代价与从前相当。
开关（`JUDGE_COMPILE_FLAGS`）必须进键：只按源码键控时，一旦改了编译参数，旧缓存照样命中，
用户端会原样回放「用旧参数编出来的产物」——表象就是升级了版本、报错还是那一个。
静态链接是**运行期**的硬要求：动态产物要按 PATH 找仓颉运行时 DLL，命中别代运行时的报错是
「无法定位程序输入点 `CJMCC_ExclusiveScope`」（本 SDK 导出的是带下划线的 `CJ_MCC_*`）——
同一份判题源码本机 3/3 通过、换了台机器就一编译完即载入失败；链进去之后与 PATH 再无关系。
哈希用「左移 7 + 右移 57 + 异或字节」的滚动哈希——**不能用乘法基哈希（FNV 之类）**：
仓颉整数乘法溢出抛 `OverflowException`（实测），不是 C 那样静默回绕。

### 5.2 编辑器：CodeMirror 本地化 + 仓颉高亮

编辑器是 CodeMirror 5（`ui/vendor/`，MIT，登记见 AGENTS §5），经占位符
`/*__VENDOR_CSS__*/` / `/*__VENDOR_CORE__*/` 内联进页面——页面是 `run(html)` 的内联来源，
`<script src>` 相对路径不成立（markdown-notes 同款做法）。仓颉高亮是**应用自写的轻量
mode**（关键字/类型/字符串/注释，未用官方 clike——对仓颉关键字覆盖不全）；vendor 缺失时
自动降级纯 textarea，编辑功能不丢。

### 5.3 原生菜单走应用层 API

菜单（运行 / 重置代码 / 帮助）在 `run()` 之前用 `app.setMenu(buildMenu())` 装配，
点击经框架的 shell 事件分发**自动**投成前端 `menu:click` 事件，前端 `listen` 接住即可——
应用侧只挂了一个 `onShellEvent` 钩子往 stderr 留痕，没有自己摸宿主 API。

### 5.2 判题目录「逐级建 + 每次一个」

`Directory.create` 不递归（std.fs 语义），所以先建 `target/leetcode` 再建子目录、
已存在就吞掉异常；子目录名带毫秒时间戳 + 进程内自增号，连续两次判题互不覆盖。
产物在 `target/` 下，天然不入库。

### 5.4 前端是磁盘真文件

页面走 `ui/index.html`（`File.readFrom` 读盘交给 `app.run(html)`），不是内联在仓颉
三引号字符串里——JS 里的 `\n`、正则、字符串转义都**不受**三引号转义坑影响，可以正常写。
代价是分发时 `ui/` 要随行；要做单文件打包可参照 `examples/music` 的 packed assets 方案。

## 6. 实机验收

跑起来后按这几条对账（凭证都在桥的 stderr 日志里）：

| 断言 | 看什么 |
| --- | --- |
| 窗口与菜单 | `set window: title=仓颉力扣 · cj-tauri`、`menu applied: items=3` |
| 题库加载 | `leetcode:list -> 100 题`、左侧按分类分组 |
| 编辑器填充 | 选中题目后编辑器出现仓颉模板（`draft saved id=<N>` 随输入出现） |
| 判题闭环 | 点运行后 `judge id=<N> exit=0`；空模板时终端逐用例 FAIL 且给出期望值 |
| 进度统计 | 全过后 `stats recorded id=<N> attempts=<k> solved=true`、统计文件落盘、徽标与列表 ✓ 刷新 |
| 参考答案 | 「参考答案」按钮载入当前题答案（108 题逐题过「答案 + harness」编译与运行验证） |
| 三处联动 | 把 `capabilities/app.json` 里的 `leetcode:run` 删掉，运行应被拒（`command not allowed`） |

题库数据的批量自检（每题两件事都要过：「模板 + harness」编译通过、「答案 + harness」编译并
逐用例打印 PASS；内置 100 题应全过——把脚本里的 JSON 换成题包文件即可同法查题包 8 题）：

```bash
# 提取内嵌 JSON（题库是文件里唯一的 """ 块），逐题生成源码编译 + 跑答案
python3 - <<'EOF'
import json, os, re, shutil, subprocess
from concurrent.futures import ThreadPoolExecutor
src = open('src/problems_data.cj', encoding='utf-8').read()
s = re.search(r'"""(.*)"""', src, re.S).group(1)   # 注意用贪婪匹配：只要那个 JSON 块
out, i = [], 0
while i < len(s):                                  # 反解义仓颉源码里 \\ 与 \" 两层转义
    c = s[i]
    if c == '\\' and i + 1 < len(s):
        out.append({'\\': '\\', '"': '"'}.get(s[i+1], '\\' + s[i+1])); i += 2
    else:
        out.append(c); i += 1
data = json.loads(''.join(out), strict=False)      # 描述里的换行是裸换行，strict 会拒
work = '/tmp/lc-validate'; shutil.rmtree(work, ignore_errors=True); os.makedirs(work)

def harness(p):
    h = '\nmain(): Int64 {\n'
    for k, t in enumerate(p['tests']):
        h += '    let r%d = %s\n' % (k, t['call'])
        h += '    if (r%d == %s) { println("RESULT %d PASS") } else { println("RESULT %d FAIL: got=" + r%d.toString()) }\n' % (k, t['expect'], k, k, k)
    return h + '    return 0\n}\n'

def build(p, kind, code, hs):
    d = '%s/%s-%s' % (work, p['id'], kind); os.makedirs(d, exist_ok=True)
    # 镜像判题侧：代码自带 import 就不补前缀
    body = '' if 'import ' in code else 'import std.collection.*\n'
    open('%s/main.cj' % d, 'w', encoding='utf-8').write(body + code + hs)
    exe = 'judge.exe' if os.name == 'nt' else 'judge'   # Windows 上不带 .exe 的产物跑不起来
    # 与判题侧同参数：静态链接，运行期不去找仓颉运行时 DLL
    r = subprocess.run(['cjc', 'main.cj', '-o', exe, '--static', '--static-std', '--strip-all'], cwd=d, capture_output=True, text=True)
    if r.returncode != 0:
        return '编译失败: ' + (r.stderr or '')[:200]
    if kind == 'tmpl':
        return ''
    p2 = subprocess.run([os.path.join(d, exe)], cwd=d, capture_output=True, text=True, timeout=30)
    lines = [x for x in (p2.stdout or '').splitlines() if x.startswith('RESULT')]
    if len(lines) != len(p['tests']):
        return '用例行数 %d != %d' % (len(lines), len(p['tests']))
    return '; '.join(x for x in lines if 'FAIL' in x)

def check(p):
    hs = harness(p)
    errs = [e for e in (build(p, 'tmpl', p['template'], hs), build(p, 'sol', p['solution'], hs)) if e]
    return p['id'], errs

bad = 0
with ThreadPoolExecutor(max_workers=4) as ex:
    for pid, errs in ex.map(check, data['problems']):
        if errs:
            bad += 1; print(' ✗', pid, ' | '.join(errs))
print('%d/%d 全过' % (len(data['problems']) - bad, len(data['problems'])))
EOF
```

## 7. 文件

```
examples/leetcode-gui/
├── cjpm.toml              # 工程配置（link-option 引 native/ 桥库）
├── capabilities/app.json  # 能力清单：五道 leetcode: 命令 + menu:click 事件
├── src/
│   ├── main.cj            # 装配：窗口 / 菜单 / 命令注册 / shell 钩子
│   ├── commands.cj        # 五道题库命令 + 判题核心（cjc 编译运行 + RESULT 解析）
│   ├── problems_data.cj   # 内置题库 100 题（内嵌 JSON，含每题参考答案 solution，转义见文件头）
│   ├── remote_packs.cj    # 远程题包：拉取 / 校验 / 合并 / 缓存（加载更多）
│   └── progress.cj        # 做题进度统计（attempts/solved）+ stats/solution 命令
└── ui/
    └── index.html         # 三栏布局 + 编辑器 + 判题终端（磁盘真文件，非内联）
```
