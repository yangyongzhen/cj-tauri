---
name: cj-tauri-verify
description: cj-tauri 应用的实机验证与取证：构建、运行、按桥 stderr 日志判成败、无显示环境用 Xvfb、没有真设备用 pty 虚拟对端、截图归档。当需要验证 cj-tauri 应用跑通、自动化验收、或「跑起来看看」时使用。
---

## 何时使用

- 「跑一下」「验证这个功能」「取证据」「自动化验收」「截图」
- 改动交付前的门禁（构建 + 实机 + 断言）

## 判据铁律（先记住再动手）

- **窗口起来 ≠ 成功**。证据是桥的 stderr 日志：窗口创建、`set window:` 行、
  `js -> native` 与实际调用次数吻合、`ExecuteScript -> hr=0x00000000`；
- **「日志里没有错误行」≠「命令成功了」**——页面没接 `catch` 时失败只在页面上可见；
  命令 handler 必须把 reject 也回投（`report`）；
- 「设了但没生效」的宿主调用：**检查 API 返回值 + 事后查询复核**打进同一行日志
  （只打「我调过了」等于没有凭证）；
- 诊断一律走 stderr：仓颉 `println` 的 stdout 有缓冲，进程被强杀时日志会丢；
- **退出码 0 什么都不证明**（Windows/MSYS 有「假成功」形状），判真假看副作用
  （日志 mtime / 行数 / 断言计数）。

## 步骤

### 1. 构建

```bash
cjpm build                    # 框架根；涉及 CLI 再 cd cli && cjpm build；涉及示例各跑各的
```

本机环境（Linux 参考形，换机器按实际 SDK 路径调）：

```bash
export PATH=/opt/cangjie/cangjie/bin:/opt/cangjie/cangjie/tools/bin:$PATH
export LD_LIBRARY_PATH=<框架>/native:<stdx>/dynamic/stdx:\
$CANGJIE_HOME/runtime/lib/linux_x86_64_cjnative:$CANGJIE_HOME/third_party/llvm/lib
```

只设 PATH 不设 `LD_LIBRARY_PATH` → 退出码 127 且无输出（运行时 .so 不查 PATH）。

### 2. 跑

工作目录 = 项目根（`capabilities/`、`ui/` 按相对路径读）。改过 C 桥导出先重建桥
（`bash native/build_linux.sh`）再构建/测试，否则链接期一串 `undefined reference to cj_bridge_*`。

### 3. 无显示环境

- 首选 `xvfb-run -a -s "-screen 0 1280x800x24" bash <脚本>`（手工 `Xvfb :99` 常起不来）；
- SSH 转发的 `DISPLAY` 可能失效：先 `xdotool getdisplaygeometry` 探测可用性，别只看设没设；
- 跑通类脚本（如 `examples/*/run.sh`）自带 Xvfb 回落与断言，优先用它们。

### 4. 自动化断言

- 断言**只看日志里的效果**（桥/应用自己打的 stderr 行），不靠「我点过了 / 我调过了」；
- `grep -aF` 按整行前缀取证据（如 `[cj-bridge]`），别用会在正文里撞词的中缀——
  过滤词本身也会骗人；
- 等窗口/等就绪用有界轮询（`xdotool search --name`），别用固定 `sleep`。

### 5. 没有真设备时造虚拟设备

- 串口：python3 `pty` 造一对（`examples/plugin-serial/serial-peer.py` 是现成样板，
  从端 `/dev/pts/N` 落在插件白名单的 `/dev/pts/` 前缀里；本机没有 socat 也不用装）；
- **写方向的证据要在应用进程之外**（对端日志 / 落盘文件），不是应用自报「我写了」。

### 6. 截图归档

- Linux/X11：`import -window root <路径>`；抓屏会冻住 X 客户端几秒，**别在命令进行中抓**；
- **改过布局必须抓图人眼验**——断言管不了配色与排版（自检全绿照样可能折叠/白底浅字）；
- 截图统一放固定目录并配 INDEX（记录「每张图证明哪条结论」），别散在 `/tmp` 根下。

## 规则

- 一次只验证一件事；每条结论要有日志行或截图对应；
- 失败先读桥 stderr，再读页面 `catch`；同一个失败不要盲试第二遍；
- 跑不起来就如实说明（含哪些平台未验证），禁止把未验证说成通过。
