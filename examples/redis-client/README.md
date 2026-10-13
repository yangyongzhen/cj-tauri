# redis-client · Redis 客户端调试台

用 cj-tauri 的 `redis` 插件搭的桌面调试台：**连服务器、浏览键空间、按类型看值改值、发布订阅、看服务器诊断**。
RESP2 协议由框架侧纯仓颉实现（标准库 `std.net` 的 TCP socket），页面只管界面——协议不该让每个应用重写一遍。

## 跑起来

```bash
bash run.sh          # Linux 一键：自带 mock redis 对端 + 探针自检 + 落证据 JSON
```

手动跑（对着真实 redis）：

```bash
cd examples/redis-client
CANGJIE_HOME=/opt/cangjie/cangjie \
LD_LIBRARY_PATH=../../native:$CANGJIE_HOME/runtime/lib/linux_x86_64_cjnative:<stdx 动态库目录> \
  ./target/release/bin/main
```

前置：桥已构建（`bash native/build_linux.sh`）；`run.sh` 需要 python3（只用标准库，不需要装 redis-server）。

## 界面

| 区域 | 干什么 |
| --- | --- |
| 左：连接 / 键列表 | 填 host、port、db、口令、超时；连上后按 `SCAN` 游标分页列键，支持 `MATCH` 模式与 `TYPE` 过滤，每行带类型与 TTL |
| 中：值面板 | 按类型给对的形状：string 看文本与十六进制、hash 看字段对、list 看区间、set 看成员、zset 看分值、stream 看条目；可改值、改 TTL、重命名、删键 |
| 右：发布订阅 / 服务器 | 订阅频道与模式、发消息、消息流（`message` 与 `pmessage` 分流）；INFO / DBSIZE / SLOWLOG 服务器信息 |

## 权限（能力清单）

命令**只声明不自动放行**，要用就在 `capabilities/default.json` 里写清楚：

```json
{
  "identifier": "default",
  "windows": ["main"],
  "commands": ["report", "quit", "system:version"],
  "permissions": ["redis:default"],
  "events": ["redis:message", "redis:state"]
}
```

插件声明两个命名权限集（集声明 ≠ 放行，清单不引用就不生效）：

| 集合 | 条数 | 覆盖 |
| --- | --- | --- |
| `redis:default` | 19 | 全部命令 |
| `redis:readonly` | 13 | 只读：`connect` / `disconnect` / `select` / `status` / `info` / `dbsize` / `slowlog` / `scan` / `keyInfo` / `value` / `subscribe` / `unsubscribe` / `messages` |

写类命令（`keyRename` / `keyDelete` / `keyExpire` / `keyPersist` / `valueWrite` / `publish`）只在前者里。
事件 `redis:message` / `redis:state` 也要在 `events` 里声明，否则页面收不到。

## 两条数据通道

| 通道 | 形式 | 用途 |
| --- | --- | --- |
| 事件 | `redis:message`（订阅收到的一条）/ `redis:state`（连接与订阅状态变迁） | 实时消息流与状态徽章 |
| 拉取 | `redis:messages` 一次取走并清空（上限 500 条） | 页面重载 / 标签失活回来补齐、无人值守脚本取证据 |

同一条消息可能两条路都到，页面按报文里的 `seq` 去重。

## 值的形状（按类型）

`redis:value` 的返回**跟着类型走**，不是一律塞字符串：

| 类型 | 形状 |
| --- | --- |
| `string` | `mode=whole` + `value{bytes, truncated, text, hex}`——二进制值 `text` 可能不是给人看的，`hex` 逐字节保真（单值文本上限 64 KiB，超了 `truncated=true`） |
| `hash` | `mode=cursor` + `cursor` / `total` / `entries`（字段对数组），游标由页面原样带回来翻页 |
| `set` | `mode=cursor` + `cursor` / `total` / `members` |
| `list` | `mode=range` + `total` / `items`（`offset` + `limit`，单页上限 200） |
| `zset` | `mode=range` + `total` / `entries`（含分值） |
| `stream` | `mode=range` + `total` / `entries`（含条目 id） |

## 探针（无人值守）

设了 `CJ_REDIS_PROBE_HOST` 后，宿主把配置经 **document-start 预执行脚本**注入页面，页面自动跑完
`连接 → INFO/SLOWLOG → SCAN(全量/match/type) → 六种类型取值 → 写与回读 → EXPIRE/PERSIST/RENAME/DEL
→ 订阅(频道+模式) → 发布 → messages 对账 → 状态 → 断开 → 重连 → 自退`，每一步都往 stderr 打一行
`[frontend] REDIS …`：

```bash
CJ_REDIS_PROBE_HOST=127.0.0.1 CJ_REDIS_PROBE_PORT=6379 CJ_REDIS_PROBE_DB=0 \
CJ_REDIS_PROBE_MS=8000 ./target/release/bin/main
```

其它变量：`CJ_REDIS_PROBE_QUIT=0` 可让它跑完不退出（留着看界面）。

## 对端：自写的 mock redis

`mock-redis.py` 是**测试对端**，不是 redis 实现：只做这个客户端会用到的 RESP2 命令
（键空间 `TYPE/TTL/PTTL/EXISTS/DEL/RENAME/EXPIRE/PERSIST/STRLEN/SCAN/KEYS/HSCAN/SSCAN`、
string `GET/SET/SETEX/MGET/APPEND`、hash `HGETALL/HSET/HDEL/HLEN/HGET/HEXISTS`、
list `LRANGE/LPUSH/RPUSH/LLEN/LSET/LREM/LPOP`、set `SMEMBERS/SADD/SREM/SCARD/SISMEMBER`、
zset `ZRANGE(WITHSCORES)/ZADD/ZREM/ZCARD/ZSCORE`、stream `XADD/XRANGE/XLEN`、
发布订阅 `SUBSCRIBE/UNSUBSCRIBE/PSUBSCRIBE/PUNSUBSCRIBE/PUBLISH`，以及
`PING/ECHO/AUTH/SELECT/CLIENT/COMMAND/INFO/DBSIZE/CONFIG GET/SLOWLOG GET/FLUSHDB`）。

启动即 seed 14 个键（db0）+ 1 个（db1），刻意各带一个样本：普通字符串、`expires-soon`（TTL 600s）、
`forever`（无 TTL）、`blob:bin`（非 UTF-8 字节 `00 01 FF FE`，验二进制保真）、hash / list / set / zset / stream 各一。
未知命令一律回 `-ERR unknown command '<name>'`——**不猜、不静默**。

```bash
python3 mock-redis.py --selftest        # 自检：本进程起服务端 + 裸 socket 客户端走一轮 12 项断言
python3 mock-redis.py --port 63790 --log /tmp/mock.log
```

自己不写对端的两个理由：① 两侧都有日志（`[mock-redis]` 与 `[cj-tauri] redis` / `[frontend] REDIS `），
「到底谁没说话」一眼可分；② 本机不需要装 redis、不需要配置文件、不受发行版版本影响。

## 实机证据

`bash scripts/e2e/test-linux-redis-client.sh`（`run.sh` 就是它的转发）在 Linux 上跑通并落
`dist/e2e-evidence/linux-linux-redis-client.json`——**47 条断言全过**，两侧都取到证：

- 应用侧：`scan all keys=14 done=true enriched=14`（每键都补了 TYPE/TTL）、`scan match=user:* keys=3`、
  `scan type=hash keys=1`、六种类型的取值行、`value … hex=0001FFFE`（二进制逐字节保真）、
  `read back … text=hello-probe-tail bytes=16`（写后回读一致）、`keyInfo … ttl=`、`keyPersist applied=true`、
  `keyRename newKey=probe:renamed`、`keyDelete requested=2 deleted=2`、`subscribe ok=true channels=1 patterns=1`、
  `message seq=1 kind=message` 与 `seq=2 kind=pmessage`（频道与模式两条路都收到）、
  `messages count=2 seen=2 dropped=0`、`disconnect hadSub=true droppedChannels=1`、`reconnect ok state=connected`；
- 对端侧：`client connected`（同一轮出现 3 次：命令连接 + 订阅连接 + 重连后的命令连接）、
  `HSCAN/​SSCAN/DEL/EXPIRE/RENAME/SUBSCRIBE/PUBLISH rx`、`PUBLISH push ch=… subscribers=1`；
- 负向：`command not allowed` / `not registered` 一次都没响；取值失败行（`HSCAN/SSCAN 回复形状不对`）零条。

## 边界（如实）

- 只做 **RESP2 与单实例**：不做 Cluster / Sentinel 拓扑发现、不做 TLS（`rediss://`）、
  不做 ACL 管理类命令、不做事务（MULTI/EXEC）与脚本（EVAL）。对端要是 RESP3，编解码层会明确报协议错误，不猜。
- **控制台式「任意命令直发」有意不做**：那等于把整台服务器的权限面直接摊给页面，与「命令白名单」的模型相悖。
- 连不上时给明确错误，**不静默重试**（调试工具最怕「看起来还连着」）。
- 命令是**一问一答的同步阻塞**（跑在命令 worker 线程上，窗口不会被冻住）：没有流式输出、没有取消，
  等待上限由 connect 时的 `timeoutMs` 决定（默认 3s）。
- 发布订阅走**另一条** socket（订阅后那条连接按协议只能收推送）：两条连接任一断开的状态都会如实上报。
- 目前只在 **Linux 实机**取证；Windows 侧未跑（协议与 socket 部分无平台分支，但「未验证」就说未验证）。
- 首次 E2E 取证时出现过**一次**未复现的崩溃（重连阶段、SIGSEGV 落在 `libgobject`，同一份日志里另有
  `g_object_unref: assertion 'G_IS_OBJECT (object)' failed` 的 GLib 告警——后者在**已通过的** mqtt 示例
  日志里同样存在）。此后连续 6 轮 E2E 全绿、未再出现，**不判因**，如实记在这里。
- 未接单文件打包（缺 `src/packed_assets.cj` / `src/packed_resources.cj` 存根，照 `examples/music/src/` 抄即可）。
