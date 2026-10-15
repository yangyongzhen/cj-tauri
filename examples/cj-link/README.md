# cj-Link · 串口/网络二合一调试助手

cj-tauri 示例：串口与 TCP 客户端共用一块收发日志的调试小工具（路线图「旗舰选题」的落地样板）。

![界面截图](../docs/images/example-cj-link.png)

## 功能

- **串口链路**：端口枚举（连接前点 ↻）、波特率/数据位/校验/停止位参数面板，走官方 `serial` 插件
  （C 桥 termios，Linux/Windows 两平台同名导出）；收走前端轮询 `serial:read`。
- **网络链路（TCP 客户端）**：应用级 `link:tcpConnect/tcpSend/tcpClose`（`std.net` 的 `TcpSocket`，
  5s 建连超时），收走宿主事件推送 `link:tcpData`。
- **收发日志**：HEX/ASCII 双显（双显/HEX/文本三档视图）、方向分色（↑TX 黄 / ↓RX 绿 / ·系统灰）、
  毫秒时间戳、按方向过滤、TX/RX 字节与错误计数。
- **发送区**：HEX/文本双模式、追加 CRLF、定时发送（1s 周期）。
- **面板配置持久化**：`store:get/set` 落 `store.json`，重启自动恢复。

## 命令表

| 命令 | 归属 | 说明 |
| --- | --- | --- |
| `serial:list/open/read/write/close` | serial 插件 | 串口能力（`serial:default` 权限集） |
| `store:get/set` | store 插件 | 面板配置持久化 |
| `link:serialList` | 应用级 | 串口枚举统一出口 |
| `link:tcpConnect/tcpSend/tcpClose` | 应用级 | TCP 客户端 |
| `link:ping` / `report` / `quit` | 应用级 | 探针自检辅助 |

能力清单见 `capabilities/default.json`——没声明的命令一律 `command not allowed`。

## 运行

```bash
# Linux（自动套 Xvfb；对端由 python3 pty + TCP echo 扮演）
bash run.sh

# 手动
cd examples/cj-link && cjpm run
```

## 探针自检（自动化取证）

`CJ_LINK_PROBE=1` 时宿主经 document-start 预执行脚本注入配置，页面自动跑
「串口 open→write→read→close + TCP connect→send→recv→close」共 7 步，逐项经 `report` 回投 stderr；
对端由 `cj-link-peer.py` 扮演（串口 pty echo + TCP echo），收发证据落在应用进程之外
（`rx` 文件 + 对端日志）。`run.sh` 的 26 条断言全绿即两条链路都是活的。

```bash
CJ_LINK_PROBE=1 CJ_LINK_PROBE_SERIAL_PATH=/dev/pts/N \
CJ_LINK_PROBE_TCP_HOST=127.0.0.1 CJ_LINK_PROBE_TCP_PORT=15021 \
  ./target/release/bin/main 2> app.log
```

其余变量：`CJ_LINK_PROBE_QUIT=0` 不自动退出（人眼手测用）。

## 已知边界

- 串口与 TCP 各自独立收发、同一时刻只用一条（单链路收发，互斥提示在页面）；
  「串口↔网口透明互转」是有意不做的二期。
- TCP 只有客户端；服务端监听（`TcpServerSocket`）二期。
- 不做 UDP（路线图口径）。
