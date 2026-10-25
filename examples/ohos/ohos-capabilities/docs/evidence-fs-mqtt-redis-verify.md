# fs / mqtt / redis 插件鸿蒙真机核验（2026-10-25）

设备：3QC0124B20000048（HarmonyOS PC / 2in1）
应用：ohos-capabilities（com.yang.testcj）探针页自跑，断言经 probeLog 写 hilog（tag CjProbe）
hilog 原文：`.atomcode/tmp/fs-verify-hilog7.txt`（fs）、`.atomcode/tmp/mqtt-verify-hilog2.txt`（mqtt）、
`.atomcode/tmp/redis-verify-hilog2.txt`（redis）——均为流式抓取

## 结论：三个插件鸿蒙真机全部通过

### fs（12 PASS + 1 SKIP + 2 条期望拒绝）

```
PASS fsR write / read("cj-fs-…") / read-back / stat{name,size,lastModified}
PASS fsR mkdir (already exists, skipped) / mkdir-sub
PASS fsR copy / rename / list / remove
PASS fsR outside-scope rejected（../etc/passwd 不命中 allow）
PASS fsR deny-path rejected（probe-fs/secret.txt 被 **/secret* 拒，对照同形态 hello.txt 写成功）
SKIP fsR cleanup-dir（fs:remove 只删文件是命令面语义，与桌面一致）
```

**scope 口径定案（鸿蒙）**：进程 cwd = 应用 el2 沙箱 `files` 目录
（`/data/storage/el2/base/haps/entry/files`），相对路径折叠到它；清单 allow 用
`$CWD/probe-fs/**` 命中。两个坑：① `**` **不匹配裸目录本身**——`mkdir 'probe-fs'`
被拒，allow 需另加 `$CWD/probe-fs`；② `writeText` 不自动建父目录（先 mkdir）。

### mqtt（全链 PASS，got=10 条报文）

对端是 PC 上的本仓 mock broker（`examples/mqtt-client/mock-broker.py`），经
**`hdc rport tcp:18830 tcp:18830`** 反向转发（设备连自己的 `127.0.0.1:18830`）。

```
PASS mqtt connect（CONNACK rc=0）→ subscribe（SUBACK 授予 QoS1）
PASS mqtt publish（QoS1，PUBACK 回执 seq=9）
PASS mqtt message ×10（tx/rx 逐条：CONNECT/CONNACK/SUBSCRIBE/SUBACK/PUBLISH×3/PUBACK×2/DISCONNECT）
PASS mqtt recent / status（rx=4 tx=4 subscriptions 在案）/ disconnect
```

公网明文 broker（test.mosquitto.org:1883）实测 **connect timeout**（设备出网非 443/80
端口被拦）——真机取证的可行对端是 rport + 本机 mock。三处联动无平台代码改动
（mqtt 命令面跨平台共用，明文 TCP 不碰 TLS）。

### redis（5 PASS）

对端是 PC 上的本仓 mock-redis（`examples/redis-client/mock-redis.py`），经
**`hdc rport tcp:6380 tcp:6379`** 反向转发（设备连自己的 `127.0.0.1:6380`）。

```
PASS redis connect（AUTH→SELECT→PING 握手）→ valueWrite set（simple(OK)）
PASS redis get round-trip expect=cj-redis-… actual=cj-redis-…（逐字一致）
PASS redis status（calls=6）/ disconnect
```

前端注意：`redis:value` 的 `value` 字段是展示对象 `{bytes,truncated,text,hex}`
（`redisValueDisplay`），取 `v.value.text` 不是 `v.value`。

### `hdc rport` 取证通道备忘

`hdc rport tcp:<设备端口> tcp:<PC 端口>` = **设备侧监听**、转发到 PC
（`fport` 反过来，且与 PC 本地监听冲突时报 `TCP Port listen failed`）。
`rport ls` 会报 `Incorrect forward command`（查询语法问题），不影响转发本身生效。
两台 mock 对端（broker/redis）都只听 `127.0.0.1`，不改脚本即可用。

## notification 落地路径评估（本轮结论：blocked）

仓颉 SDK `api/modules/linux_ohos_aarch64_cjnative/ohos/` 共 183 个绑定，**无
notification**（`ohos.hilog`/`ohos.common_event_*` 在、`ohos.notification` 不在）；
`api/lib/.../ohos/` 也无对应 so。 ArkTS 通道已被 D-022 定死（纯仓颉进程没有
ArkTS VM）。剩下唯一可能：NDK 直连 C API（`libnative_notification` 一类）+ entry
link-option——未验证，重开时先 `hdc shell stat -L` 设备侧确认库存在再动手。
