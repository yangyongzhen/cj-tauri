# serial-waveform —— 串口实时波形示波器

`serial` 插件接通口，页面用 canvas 把样本流**实时画成波形**。**没有真设备也能跑**：
`run.sh` 用 python3 的 pty 造一对内核虚拟串口（本机没装 socat 也照样造）。

## 为什么单独做一个（相对 `serial-assistant` / `modbus-poll`）

那两个示例都是**文本工具**——收发日志、轮询取值，两页都只列文字、没有画过图。
「采集到的东西实时变成波形」这一档是空白，而它恰好是串口类桌面应用最直观的门面形态：
一眼看懂，且浏览器打不开串口，这是纯 Web 技术碰不到的活。

## 跑起来

```bash
cd examples/serial-waveform
bash run.sh                      # Linux 一键：pty 对端 + 应用 + 探针自检，跑完打印结论
```

`run.sh` 只是转发到仓内 E2E 入口（`scripts/e2e/test-linux-serial-waveform.sh`），
口径、断言与证据都在那边维护——从示例目录也能一键跑，但**不另立一份标准**。

手动两种跑法：

```bash
# 1) 手动看波形：自己起对端，再开窗口填设备路径
python3 serial-wave-peer.py --write-rx /tmp/wave-rx.bin        # 打印它用的 /dev/pts/N
./target/release/bin/main                                       # 窗口里填 /dev/pts/N → 连接

# 2) 探针自检：给了设备路径就自动连接 → SCAN → 收 N 毫秒 → 打统计并自退
CJ_SERIAL_PROBE_PATH=/dev/pts/N CJ_SERIAL_PROBE_MS=2500 ./target/release/bin/main
```

探针配置经 **document-start 预执行脚本**注入页面（早于页面脚本），
环境变量：`CJ_SERIAL_PROBE_PATH` / `_BAUD`（默认 115200）/ `_MS`（默认 2500）/ `_QUIT`（默认 1）。

## 数据协议（ASCII 行协议，真实仪器里最常见的那种）

| 方向 | 报文 | 说明 |
|---|---|---|
| 应用 → 设备 | `SCAN\n` | 开始连续输出 |
| 应用 → 设备 | `STOP\n` | 暂停 |
| 设备 → 应用 | `<序号>,<值>\n` | 值域 -1.0..1.0；序号用来算丢帧 |

页面**不预设设备型号**：换真实传感器只要改解析函数。读法也不是长阻塞读——
`serial:read` 单次上限 4096 字节、`timeoutMs` 到期返回空，页面循环短读再按行拼。

## 自检与证据（Linux 实机，2026-10-13）

| 指标 | 实测 | 它证明什么 |
|---|---|---|
| 速率 | **404.2 /s** | 对端按 400 Hz 出样本，页面按自己收到的时间戳算——不是抄对端报的数 |
| 上穿次数 | 8 | 正弦过零 8 次，与画出来的波形对得上 |
| 丢帧 | 0 | 序号连续，读循环没丢样本 |
| 判定 | `verdict=ok` | 速率在容差内且无丢帧（页面自评，探针据此退出） |
| 统计行 | 样本 2002 / 画布 1148x566 | 与视口一致（布局缺陷不会被自检掩盖，故另有截图人眼验） |

**进程外证据**：应用写出的 `SCAN` 必须出现在**对端落盘的文件**里（`--write-rx` 指定的那个）——
「页面说它写了」证明不了它真写到了线路上；这条由 E2E 入口断言。

- 一键复跑：`bash run.sh`（10 条断言全绿）
- 汇总：`bash scripts/e2e/run-all.sh` → 通过 2 / 跳过 0 / 失败 0
- 证据 JSON：`dist/e2e-evidence/linux-linux-serial-waveform.json`
- 截图：`docs/images/example-serial-waveform.png`

## 权限（`capabilities/default.json`）

```json
{ "commands": ["report", "quit", "system:version"], "permissions": ["serial:default"] }
```

- `serial:default` 是命名集，一次放行 `open` / `read` / `write` / `close`——
  示波器要先发 `SCAN`（写）再连续读，`serial:readonly` 不够；
- 插件**只声明「我提供什么」，不自动放行**：清单里不写就是 `command not allowed`；
- 路径参数最终要过白名单（`serial` 的路径校验在 C 桥 core 里，不在页面）。

## 边界（如实）

- **Linux 已实机取证**（上表就是本机 Xvfb + 内核 pty 量出来的）；
  **Windows 侧尚未实机取证**——桥里有对应实现（`cj_bridge_serial_list` 走 `QueryDosDeviceW` 扫 MS-DOS 设备名），
  但没有那台机器上的证据，所以别对外说 Windows 也能跑通。
- 界面只画**滚动窗口**内的样本，不做缩放/游标测量；这是示波器的入门形态，不是分析仪。
- **尚未接单文件打包**：缺 `src/packed_assets.cj` 存根与 `src/packed_resources.cj`
  （照 `examples/music/src/` 抄最快，见 `AGENTS.md` §4）；想打 `serial-waveform.exe` 先补这两样。
