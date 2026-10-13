# mqtt-client · MQTT 3.1.1 调试台

用 cj-tauri 的 `mqtt` 插件搭的桌面调试台：**连 broker、订阅、发布、看报文流**。
MQTT 协议由框架侧纯仓颉实现（标准库 `std.net` 的 TCP socket），页面只管界面——协议不该让每个应用重写一遍。

## 跑起来

```bash
bash run.sh          # Linux 一键：自带 mock broker 对端 + 探针自检 + 落证据 JSON
```

手动跑（对着真实 broker）：

```bash
cd examples/mqtt-client
CANGJIE_HOME=/opt/cangjie/cangjie \
LD_LIBRARY_PATH=../../native:$CANGJIE_HOME/runtime/lib/linux_x86_64_cjnative:<stdx 动态库目录> \
  ./target/release/bin/main
```

前置：桥已构建（`bash native/build_linux.sh`）；`run.sh` 需要 python3（只用标准库，不需要装 broker）。

## 界面

| 区域 | 干什么 |
| --- | --- |
| 左：连接 / 订阅 / 发布 | 填 host、port、clientId、保活、用户名口令；订阅主题过滤器；发布文本或十六进制载荷 |
| 中：报文流 | 一条时间线装两个方向（`→` 发 / `←` 收），可过滤、暂停、清空 |
| 右：状态 / 订阅表 | 收发条数、缓冲条数、丢弃条数、待回执、每条订阅的授予 QoS |

## 权限（能力清单）

命令**只声明不自动放行**，要用就在 `capabilities/default.json` 里写清楚：

```json
{
  "commands": ["report", "quit", "system:version"],
  "permissions": ["mqtt:debug"],
  "events": ["mqtt:message", "mqtt:state"]
}
```

`mqtt:debug` 是插件声明的命名权限集，一次放行七个命令：`connect` / `subscribe` / `unsubscribe` /
`publish` / `disconnect` / `status` / `recent`（全名 `<插件名>:<短名>`）。
事件 `mqtt:message` / `mqtt:state` 也要在 `events` 里声明，否则页面收不到。

## 两条数据通道

| 通道 | 形式 | 用途 |
| --- | --- | --- |
| 事件 | `mqtt:message`（每条报文）/ `mqtt:state`（状态变迁） | 实时列表与状态徽章 |
| 拉取 | `mqtt:recent` 一次取走并清空（上限 500 条，单条正文按 256 KiB 截断） | 页面重载 / 标签失活回来补齐、无人值守脚本取证据 |

同一条报文可能两条路都到，页面按报文里的 `seq` 去重（`ui/index.html` 的 `seenSeq`）。

## 探针（无人值守）

设了 `CJ_MQTT_PROBE_HOST` 后，宿主把配置经 **document-start 预执行脚本**注入页面，页面自动跑完
`连接 → 订阅 → 发布(QoS 1) → 发布(QoS 2) → 等回推 → recent 对账 → 断开 → 重连 → 自退`，
每一步都往 stderr 打一行 `[frontend] MQTT …`：

```bash
CJ_MQTT_PROBE_HOST=127.0.0.1 CJ_MQTT_PROBE_PORT=18830 CJ_MQTT_PROBE_MS=6000 ./target/release/bin/main
```

其它变量：`CJ_MQTT_PROBE_QUIT=0` 可让它跑完不退出（留着看界面）。

## 对端：自写的 mock broker

`mock-broker.py` 是**测试对端**，不是 broker 实现：只做 MQTT 3.1.1 必需报文
（CONNECT/CONNACK、SUB/UNSUB 及其回执、PUBLISH 收发、PUBACK/PUBREC/PUBREL/PUBCOMP、PINGREQ/PINGRESP、DISCONNECT），
订阅一成功就主动回推 QoS 0 与 QoS 1 各一条——**真实 broker 不会这么配合**，但这样一轮就能把客户端收侧
（含回 PUBACK）也验掉。

```bash
python3 mock-broker.py --selftest        # 自检：本进程起 broker + 裸 socket 客户端走一轮（对端先证明自己是对的）
python3 mock-broker.py --port 18830 --log /tmp/broker.log
```

自己不写对端的两个理由：① 两侧都有日志（`[mock-broker]` 与 `[cj-tauri] mqtt:` / `[frontend] MQTT `），
「到底谁没说话」一眼可分；② 本机不需要装 broker、不需要 systemd、不受发行版版本影响。

## 实机证据

`bash scripts/e2e/test-linux-mqtt-client.sh`（`run.sh` 就是它的转发）在 Linux 上跑通并落
`dist/e2e-evidence/linux-mqtt-client.json`——**27 条断言全过**，两侧都取到证：

- 应用侧：`[cj-tauri] mqtt: state=connected`（状态变迁落 stderr）、`[frontend] MQTT connect ok …`、
  `subscribe result state=subscribed`、`publish ok topic=demo/tx`、`probe recent count=35`、`probe reconnect state=connected`；
- 对端侧：`CONNECT`（同一轮出现 2 次，重连被对端看见）、`CONNACK tx rc=0`、`SUBACK tx`、
  `PUBLISH rx topic=demo/tx qos=1 retain=False` 与 `qos=2`（载荷逐字 `hello-mock` / `hello-qos2`）、
  `PUBREC tx` → `PUBREL rx` → `PUBCOMP tx`（QoS 2 发送侧状态机整条走完）、
  `PUBACK rx`（客户端对回推的 QoS 1 回了确认）、`PINGRESP tx`（1 秒保活心跳）、`DISCONNECT rx`。

## 边界（如实）

- 只做 **MQTT 3.1.1（协议级别 4）的明文 TCP**；不做 TLS（MQTTS）、不做 WebSocket 传输、不做 MQTT 5.0 的属性与原因码。
- 连不上时给明确错误，**不静默重试**（调试工具最怕「看起来还连着」）。
- 高吞吐订阅下缓冲会持续被打满，如实上报丢弃计数，不假装无损。
- 目前只在 **Linux 实机**取证；Windows 侧未跑（协议与 socket 部分无平台分支，但「未验证」就说未验证）。
- 未接单文件打包（缺 `src/packed_assets.cj` / `src/packed_resources.cj` 存根，照 `examples/music/src/` 抄即可）。
