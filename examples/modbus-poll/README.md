# Modbus Poll (cj-tauri 示例) · Modbus TCP 调试工具

用 cj-tauri 实现的 [Modbus Poll](https://modbustools.com/modbus_poll.html) 风格调试工具：
**仓颉后端（Modbus TCP 主站 + 可选内置从站模拟器）+ 系统 WebView 前端（多面板监控界面）**。

对标原版的核心功能，并补足它的痛点——原版一屏只能开一组寄存器，看另一组要再开一个实例；
这里把「窗口」铺成面板网格，**一屏同时监控任意多组**：

## 效果图

![Modbus Poll (cj-tauri) 主界面](images/modbus-poll-main.png)

*双面板并行轮询真实从站（Modbus Slave 模拟器 @ 127.0.0.1:502），底部报文监视窗逐帧滚动
Tx/Rx 十六进制（带相对时间戳），状态行实时显示 ok/err 计数与单轮耗时。*

| 常用操作 | 怎么做 |
| --- | --- |
| 监控一组寄存器 | 「+ 新增监控面板」→ 选从站 ID / 功能码 / 地址 / 数量 / 周期 → 点「启动」（首启自动开跑） |
| 同时监控多组 | 再加面板即可，网格自适应铺满；每组独立扫描周期 |
| 改单个寄存器 | 双击该行「值」→ 模态框回显旧值 → 输入新值确认（FC06，写完立即回读） |
| 改线圈 | 功能码 01 面板双击 ON/OFF 行 → 确认取反（FC05） |
| 按浮点读写 | 面板「格式」切 `Float32` → 出现「字节序」下拉（ABCD/CDAB/BADC/DCBA）→ 双击偶数行按浮点对写 |
| 整段批量写 | FC03 面板点「批量写」→ 逐行填新值（留空=不变）→ 连续段自动合并成最少帧数的 FC16 |
| 看通信报文 | 顶栏「报文监视」→ Tx/Rx 十六进制逐帧滚动，过滤框实时筛选，「导出」落盘 `logs/` |
| 记录数据曲线 | 面板点「记录」开始采样 →「导出CSV」生成带 ISO 时间戳的 Excel 可开文件 |
| 换机器复用配置 | 顶栏「导出点位表 / 导入点位表」：面板定义 + 别名 + 连接参数整份 JSON |
| 接真实设备 | 顶栏改主机/端口即 TCP 直连；「模式」切 RTU 后填串口路径/波特率/校验位 |

| 能力 | 本工具 | Modbus Poll 原版 |
| --- | --- | --- |
| 多组并行监控 | 任意多面板同屏铺满（网格自适应） | MDI 多窗口，单实例可开但屏面拥挤 |
| 读功能码 | 01 读线圈 / 02 读离散量 / 03 读保持寄存器 / 04 读输入寄存器 | 同 |
| 写功能码 | 05 写单线圈 / 06 写单寄存器 / 15 写多线圈 / 16 写多寄存器 | 同（另有串口类 08/11/17/22/23） |
| 写手势 | 双击单元格：线圈取反（FC05）、寄存器改值（FC06）、Float32/Int16 按显示类型对写（FC16）；「批量写」按钮整段 FC16（留空保持不变、连续段自动合并） | 同（双击改值） |
| 写前确认 | 模态框回显旧值与地址，确认后才发 | 直接改 |
| 扫描周期 | 每面板独立 50ms..，失败自动退避 1s | 每窗口独立 0..3600000ms |
| 显示格式 | DEC / HEX / BIN / Int16 / Float32（跨寄存器）/ ASCII（跨寄存器） | 更多种（含 64 位） |
| 连接 | **Modbus TCP**（每 host:port 复用一条 TCP）+ **Modbus RTU 串口**（复用框架 serial 桥，CRC16 帧层，路径白名单在 C 侧兜底） | RTU/ASCII/TCP/UDP |
| 报文监视 | 底部停靠面板：Tx/Rx 十六进制实时滚动（相对时间戳 + 过滤框 + 导出文本，`mb:trace` 取走即清） | Communication 窗口 |
| 数据记录 | 每面板「记录」开关（内存采样 10000 条上限）→ 一键导出 CSV（ISO 时间戳 + 逐地址列，落盘 `logs/`） | Data Logging |
| 字节序 | Float32 显示/写入四种字节序可选（ABCD/CDAB/BADC/DCBA，读写同一张表） | 更多种 |
| 点位表 | 「导出/导入点位表」：面板定义 + 别名 + 连接参数整份 JSON（`logs/`），跨机器复用 | 工作区文件 |
| 异常码 | 从站异常直接翻成人话（01..11）显示在面板状态行 | 同 |
| 布局记忆 | localStorage：面板定义 + 连接参数（含模式/串口）+ 别名 | 工作区文件 |

RTU 串口说明：顶栏「模式」切到 `Modbus RTU (串口)` 后填串口路径（Windows `COM*`、Linux `/dev/tty*`）、
波特率/校验/数据位/停止位，面板照常轮询。串口链路需真实设备验证（本机无 RS485 硬件，帧层
CRC16 已用标准向量 `123456789 → 0x4B37` 在自检中断言）。

## 目录结构

```
examples/modbus-poll/
├── src/
│   ├── main.cj        # 装配：注册命令、读 ui/index.html、（可选）启动内置从站
│   ├── modbus.cj      # MBAP 编解码 + TCP 连接池（复用、互斥、超时、自动重连）
│   ├── commands.cj    # 命令层：mb:read / mb:write / mb:config / report / mb:quit
│   └── slave.cj       # 内置 Modbus TCP 从站模拟器（CJ_MB_SLAVE=1 时启动）
├── ui/index.html      # 前端（零依赖，无构建）
├── capabilities/default.json
├── cjpm.toml
└── run.bat            # Windows 启动 / selfcheck
```

## 运行（Windows）

```bat
cd examples\modbus-poll
run.bat              REM 正常使用：开窗、加面板、轮询
run.bat selfcheck    REM 无人值守：内置从站 + 页面读写闭环自检，打 PASS/FAIL 后自动退出
```

前置与所有示例一致：`native\build_win.bat` 已跑过（有 `native\webview2\WebView2Loader.dll`），
`CANGJIE_HOME` / `CANGJIE_STDX` 指向本机安装（脚本里有缺省值）。
Linux 侧同样 `cjpm build` 后从本目录启动（读相对路径 `ui/` 与 `capabilities/`）。

## 内置从站（调试对照组）

`run.bat selfcheck` 会设 `CJ_MB_SLAVE=1` 启动从站；手工玩也可以：

```bat
set CJ_MB_SLAVE=1
set CJ_MB_SLAVE_PORT=15020
main.exe
```

- 保持寄存器初值 = `(addr × 3) % 65536`（确定性，方便断言）；写入后保持写入值。
- 支持 FC 01/05/15（线圈）、03/06/16（保持寄存器）；02/04 回异常码 01。
- 界面上方提示从站端口，把面板指到 `127.0.0.1:<端口>` 即可试读写闭环。

## 命令（三处联动）

| 命令 | 参数 | 说明 |
| --- | --- | --- |
| `mb:read` | host, port, unit, fc(1..4), addr, qty, timeoutMs | 读一轮；返回 values[] + elapsedMs + exception |
| `mb:write` | host, port, unit, fc(5/6/15/16), addr, values[]/value | 写；返回回显 |
| `mb:config` | — | 自检环境（内置从站端口、selfCheck 开关） |
| `mb:trace` | — | 拉走报文监视缓冲（取走即清，不产生流量） |
| `mb:export` | name, content | 落盘 CSV / 点位表 / 报文文本到 `logs/`（文件名白名单，8MB 上限） |
| `mb:import` | name | 读回 `logs/` 里之前导出的文件（点位表导入 / 记录回看） |
| `report` | line | 页面自检取证行（stderr） |
| `mb:quit` | — | 页面请求退出 |

注册在 `src/main.cj`，放行在 `capabilities/default.json`，前端经 `window.__CJ_TAURI__.invoke` 调用。

## 设计取舍（为什么这样写）

- **协议自实现**：仓颉生态没有现成 modbus 包，MBAP+PDU 很小（`src/modbus.cj` 一个文件），只用标准库 `std.net`。
- **连接池复用**：多个面板轮询同一设备时共享一条 TCP（按 host:port 分桶），桶内互斥串行防止报文交错；
  任何 IO 错误立即弃连，下一轮自动重连。
- **轮询在前端**：每面板一条 `setTimeout` 链，扫描周期语义与原版一致（低于事务耗时不加速）；
  后端命令保持无状态，异步分发线程模型（AGENTS §2）天然容纳。
- **页面独立成 `ui/index.html`**：不内联三引号字符串——反斜杠转义与 `${}` 插值两条坑（AGENTS §4）。
- **数值格式化在前端**：后端只回 0..65535 原始值，DEC/HEX/Float32 等都是页面读法，换格式不重连不重读。

## 取证（selfcheck 期望输出）

`run.bat selfcheck` 的日志里应看到（`findstr` 关键行）：

```
[mbpoll] 内置从站已监听 127.0.0.1:15020
[mbpoll] read 127.0.0.1:15020 unit=1 fc=3 addr=0 qty=10 -> 10 值 0ms
[frontend] PASS read-holding ...
[frontend] PASS write-single-roundtrip actual=4321 expect=4321
[frontend] selfcheck done pass=17 fail=0
```

有任何 `FAIL ` 行 `run.bat` 退出码为 2。

## FAQ

- **面板报「通信失败」/ 超时**：先确认从站在监听（端口/防火墙）；从站 ID 与设备拨码一致；TCP 模式看顶栏主机/端口，RTU 模式查波特率与接线。错误详情看面板状态行与桥日志（`%TEMP%\cj-mbpoll-app.log`）。
- **读线圈回异常码 01**：从站的窗口定义里没开线圈区（如 Modbus Slave 需把 Function 改成 `01 Coils`）。
- **Float32 值乱**：设备的双寄存器字节序与面板设置不一致，换 ABCD/CDAB/BADC/DCBA 试。
- **想同时对比多台设备**：加多个面板，各填不同从站 ID / 主机即可——它们共用一条连接（同目标）或各自独立连接（不同目标）。
- **双击没反应**：该面板功能码是只读区（02/04）；写操作要 FC03（寄存器）或 FC01（线圈）面板。
