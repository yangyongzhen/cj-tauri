# 仓颉版力扣示例（examples/leetcode-gui）

一个用 **cj-tauri** 写的桌面版算法练习工具：左侧按分类分组的题库，中间是题目描述与
仓颉代码编辑器，下方是判题终端——点「运行」（或 Ctrl+R / 原生菜单），后端把你的代码
交给 **cjc 编译**再执行，逐个测试用例判定，结果带期望值与耗时回投到终端。
后端是**仓颉**（静态编译），前端是**系统 WebView**（HTML/CSS/JS），全程离线。

![仓颉力扣主界面](../../docs/images/example-leetcode-gui.png)

> 这篇 README 是**照着做**用的：先带你 5 分钟跑起来，再讲判题链路与几个实现细节，
> 最后是实机验收办法。题库目前 19 题、8 个分类，都是公开算法题的通用描述，
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
判题还要靠它调 `cjc`），Linux 需 WebKitGTK 开发包。框架构建见仓库根 README。

```bash
cd examples/leetcode-gui
cjpm build
# Linux：工作目录必须是本示例根（capabilities/、ui/ 按相对路径读取）
./target/release/bin/main
```

Windows 用 `cjpm build` 后运行 `target\release\bin\main.exe`（或双击，GUI 子系统不弹黑窗）。

窗口起来后：左侧点任意题目 → 中间编辑器补全算法 → 点「运行」→ 下方终端看逐用例判定。

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

题库 = **内置 19 题**（离线兜底）+ **远程题包**（「加载更多」拉取，见 §3.1）。
内置题内嵌在 `src/problems_data.cj`（启动时解析一次），按 8 个主流分类分组：

| 分类 | 题目 |
| --- | --- |
| 哈希与计数 | 两数之和、多数元素 |
| 数组与双指针 | 移动零、盛最多水的容器、合并两个有序数组 |
| 字符串 | 反转字符串、最长公共前缀、有效的回文 |
| 栈与队列 | 有效的括号、最小栈 |
| 二分与排序 | 二分查找、搜索插入位置 |
| 动态规划 | 爬楼梯、打家劫舍、最大子数组和 |
| 贪心 | 买卖股票的最佳时机、分发饼干 |
| 位运算与数学 | 只出现一次的数字、计数质数 |

### 3.1 加载更多：远程题包

题库不止内置的 19 题——侧栏底部的「⬇ 加载更多题包」会从**公共 git 仓的 raw 直链**拉取
题包 JSON，schema 校验通过后合并进题库（内置 19 题 + 题包题同池、按分类分组渲染）：

```
点「加载更多」→ leetcode:fetchMore → 下载 docs/leetcode-packs/<包名>.json
            → 校验（字段齐 / 远程 id>=100 / call+expect 是字符串）
            → 合并进题库 + 写本地缓存 problems-remote.local.json
下次启动    → 缓存自动并入（二次离线可用；缓存损坏按没有处理）
```

首发的进阶题包（递归/回溯/堆，8 题）在本仓
[`docs/leetcode-packs/advanced-1.json`](../../leetcode-packs/advanced-1.json)。

几条安全与失败口径：

| 口径 | 理由 |
| --- | --- |
| URL 白名单写死在仓颉侧（`src/remote_packs.cj` 的 `PACK_BASE_URL`），前端只传题包名，且题包名过字符白名单 | 页面可控的任意 URL 等于开放 SSRF；拼不出外链与路径穿越 |
| https 显式 `TlsClientConfig()`，走系统证书库校验 | 仓颉 HTTP 客户端不带默认 TLS；不关校验 |
| 响应体 256KB 上限，读满即停 | 不把内存交给对端 |
| 远程题 id 必须 ≥ 100 | 与内置 1..19 不冲突；重复 id 按覆盖更新（题包升版路径） |
| 下载失败**如实报错**，内置题库照常用 | 不把网络问题伪装成「没有更多题」 |

**怎么加一个新题包**：往 `docs/leetcode-packs/` 放一个同构 JSON（`packName` + `problems`
数组，格式与内置题库完全一致），再在 `src/remote_packs.cj` 的 `AVAILABLE_PACKS` 里加一行
包名——出题人提交一个 JSON 就是题库的一次更新。改完务必照 §6 的批量编译自检跑一遍新题。

每条题目数据带：`funcName`（要实现的函数名）、`template`（仓颉函数签名 + TODO 占位）、
`tests`（用例数组：`call` 是完整调用表达式、`expect` 是期望结果的仓颉字面量）。
想加题就照这个格式往数组里追加——加完务必跑一遍 §6 的批量编译自检，确认模板与用例能编译。

## 4. 判题链路：cjc 编译 + harness 比对

这是本示例的核心，也是它「仓颉版力扣」的由来——**你用仓颉写算法，判题也用仓颉工具链**：

1. **拼源码**：用户代码 + 生成的 harness（`main` 里逐条 `let rK = <call>`、与 `<expect>`
   字面量直接 `==` 比较、打印 `RESULT K PASS/FAIL` 行）；
2. **写盘**：`target/leetcode/<题号>-<时间戳>-<序号>/main.cj`，每次判题一个独立子目录；
3. **编译**：`cjc main.cj -o judge`（`cjc` 取 `CANGJIE_HOME/bin/cjc`，退回 PATH）；
4. **运行**：执行 `./judge`，解析 stdout 里的 `RESULT` 行；
5. **回投**：判定结果经 IPC 返回前端，终端逐用例着色展示。

几个设计取舍：

- **期望值用仓颉字面量直接 `==` 比较**，不比 `toString()` 的格式——字符串带不带引号、
  数组有没有空格都不会误判；
- **FAIL 行只打 `got=`**，期望值不嵌进字符串字面量（`expect` 本身可能是带引号的字符串，
  嵌进去会把 `println` 的字符串劈断——实机踩过）；
- **命令跑在 worker 线程**（框架的异步分发），编译再慢也不占宿主 UI 线程，窗口不冻。

## 5. 三个值得单独讲的实现细节

### 5.1 原生菜单走应用层 API

菜单（运行 / 重置代码 / 帮助）在 `run()` 之前用 `app.setMenu(buildMenu())` 装配，
点击经框架的 shell 事件分发**自动**投成前端 `menu:click` 事件，前端 `listen` 接住即可——
应用侧只挂了一个 `onShellEvent` 钩子往 stderr 留痕，没有自己摸宿主 API。

### 5.2 判题目录「逐级建 + 每次一个」

`Directory.create` 不递归（std.fs 语义），所以先建 `target/leetcode` 再建子目录、
已存在就吞掉异常；子目录名带毫秒时间戳 + 进程内自增号，连续两次判题互不覆盖。
产物在 `target/` 下，天然不入库。

### 5.3 前端是磁盘真文件

页面走 `ui/index.html`（`File.readFrom` 读盘交给 `app.run(html)`），不是内联在仓颉
三引号字符串里——JS 里的 `\n`、正则、字符串转义都**不受**三引号转义坑影响，可以正常写。
代价是分发时 `ui/` 要随行；要做单文件打包可参照 `examples/music` 的 packed assets 方案。

## 6. 实机验收

跑起来后按这几条对账（凭证都在桥的 stderr 日志里）：

| 断言 | 看什么 |
| --- | --- |
| 窗口与菜单 | `set window: title=仓颉力扣 · cj-tauri`、`menu applied: items=3` |
| 题库加载 | `leetcode:list -> 19 题`、左侧按分类分组 |
| 编辑器填充 | 选中题目后编辑器出现仓颉模板（`draft saved id=<N>` 随输入出现） |
| 判题闭环 | 点运行后 `judge id=<N> exit=0`；空模板时终端逐用例 FAIL 且给出期望值 |
| 三处联动 | 把 `capabilities/app.json` 里的 `leetcode:run` 删掉，运行应被拒（`command not allowed`） |

题库数据的批量自检（每题「模板 + harness」逐题 cjc 编译，19/19 应全过）：

```bash
# 提取内嵌 JSON，模拟三引号转义后逐题生成源码编译
python3 - <<'EOF'
import re, json, subprocess, os, shutil
src = open('src/problems_data.cj').read()
s = re.search(r'"""(.*?)"""', src, re.S).group(1)
out, i = [], 0
while i < len(s):
    c = s[i]
    if c == '\\' and i+1 < len(s):
        out.append({'\\':'\\','"':'"'}.get(s[i+1], '\\'+s[i+1])); i += 2
    else:
        out.append(c); i += 1
data = json.loads(''.join(out))
work = '/tmp/lc-validate'; shutil.rmtree(work, ignore_errors=True); os.makedirs(work)
ok, fail = [], []
for p in data['problems']:
    harness = '\nmain(): Int64 {\n'
    for k, t in enumerate(p['tests']):
        harness += f'    let r{k} = {t["call"]}\n'
        harness += f'    if (r{k} == {t["expect"]}) {{ println("RESULT {k} PASS") }}'
        harness += f' else {{ println("RESULT {k} FAIL: got=" + r{k}.toString()) }}\n'
    harness += '    return 0\n}\n'
    d = f'{work}/{p["id"]}'; os.makedirs(d)
    open(f'{d}/main.cj','w').write(p['template'] + '\n' + harness)
    r = subprocess.run(['cjc','main.cj','-o','judge'], cwd=d, capture_output=True, text=True)
    (ok if r.returncode == 0 else fail).append(p['id'] if r.returncode == 0 else (p['id'], r.stderr[:120]))
print(f'{len(ok)}/{len(data["problems"])} compiled'); [print(' ✗', f) for f in fail]
EOF
```

## 7. 文件

```
examples/leetcode-gui/
├── cjpm.toml              # 工程配置（link-option 引 native/ 桥库）
├── capabilities/app.json  # 能力清单：五道 leetcode: 命令 + menu:click 事件
├── src/
│   ├── main.cj            # 装配：窗口 / 菜单 / 命令注册 / shell 钩子
│   ├── commands.cj        # 五道命令 + 判题核心（cjc 编译运行 + RESULT 解析）
│   └── problems_data.cj   # 题库 19 题（内嵌 JSON，三引号转义见文件头注释）
└── ui/
    └── index.html         # 三栏布局 + 编辑器 + 判题终端（磁盘真文件，非内联）
```
