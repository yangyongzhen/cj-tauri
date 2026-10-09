# 串口调试助手（serial-assistant）

cj-tauri 官方 `serial` 插件的业务向示例：**端口下拉自动枚举**（`serial:list`，↻ 刷新）+
参数面板（波特率 / 数据位 / 校验 / 停止位）+ TX/RX 分色收发日志（时间戳、字节数、HEX 显示、按方向过滤）+
收发计数与连接态 + 发送区（HEX、「追加 CRLF」、**定时发送**、Enter 直发）。
由 `cj-tauri create serial-assistant --template app` 起骨架，再一行 `.plugin(SerialPlugin())` 接入。

## 怎么跑

```bash
cd examples/serial-assistant
cjpm build
bash run.sh        # Linux：pty 造虚拟串口对端，探针自动跑一轮 收→发→收 自检并断言
```

手动模式：直接 `cjpm run`（工作目录必须是本示例根），从「端口」下拉选设备（下拉由 `serial:list`
自动枚举；没插设备或刚接上点「↻ 刷新」）→ 连接 → 收发。

Windows 侧串口桥目前是**同名桩**（未实机），连接会失败——见 `examples/plugin-serial` 同款说明。

## 探针环境变量

设 `CJ_SERIAL_PROBE_PATH` 即进探针模式（配置经 document-start 预执行脚本注入页面）：
`CJ_SERIAL_PROBE_BAUD` / `_DATA` / `_READ_MS` / `_QUIT(0|1)`（默认 1：跑完自退；0：保持连接便于截图）。
探针对端（pty）不算「本机串口」，会额外补进端口下拉便于复现。

