# ws / log / sqlite 插件鸿蒙真机核验（2026-10-25，第三批）

设备：3QC0124B20000048（HarmonyOS PC / 2in1）
应用：ohos-capabilities（com.yang.testcj）探针页自跑，断言经 probeLog 写 hilog（tag CjProbe）
hilog 原文：`.atomcode/tmp/ws-verify-hilog4.txt`（ws）、`.atomcode/tmp/log-verify-hilog.txt`（log）、
`.atomcode/tmp/sqlite-verify-hilog4.txt`（sqlite）——均为流式抓取

## 结论

### ws：鸿蒙侧如实降级（blocked），降级契约真机取证通过（2 PASS）

真机 connect 实测死于 stdx 层：`Can not load openssl library or function RAND_bytes`
——stdx 的 WebSocket 升级依赖 OpenSSL（帧掩码随机数），仓颉运行时在鸿蒙装不了 OpenSSL 3
（与 http 的 https 同族死因）；SDK 也没有 `ohos.net.websocket` 绑定（183 个绑定逐一确认）。

落法（`src/plugins/ws/plugin_ws.cj`）：`wsUnavailableOnOhos()` 双平台分支——ohos 的
connect 在 **scope 判定之后**当场拒绝并说明原因（安全判定先于可用性判定，越界请求
该报 scope 错而不是平台错；首版放 connect 开头被真机测出顺序反了，已修）；desktop 空实现。

```
PASS ws degraded-connect rejected: ws:connect is not available on HarmonyOS: stdx WebSocket requires OpenSSL (RAND_bytes) …
PASS ws outside-scope rejected（scopes.ws 之外的 host 当场拒）
```

### log：鸿蒙降级契约真机取证通过（2 PASS）

```
PASS log path empty=""（currentLogFilePath 回空串）
PASS log write-degraded=false（writeLogLine 返 false，不伪装成功）
```

### sqlite：真机落地成功（FFI 直连随包 so，5 PASS）

设备与 NDK sysroot 都没有 sqlite 库（`stat -L` 五个候选路径 ENOENT、`find /system/lib64
/vendor/lib64 -name '*sqlite*'` 无命中、sysroot 无 aarch64 libsqlite）——走 **amalgamation
随包编 so** 路线（SQLite 是 public domain，随包不产生附许可证义务）：

1. `sqlite-amalgamation-3.50.4` 用 NDK clang 编 `libsqlite3.so`（1.4 MB aarch64）：
   `--target=aarch64-linux-ohos --sysroot=<NDK>/native/sysroot -shared -fPIC -O2`
2. so 放 `entry/libs/arm64-v8a/` 随 hap 分发（hvigor 自动打包）
3. entry link-option 加 `-L./libs/arm64-v8a -lsqlite3` 生成 DT_NEEDED（缺了模块加载期
   `U sqlite3_*` 解析失败——与 `-lohos.net.http` 同族）
4. **删桩**：`sqlite_ohos_stub.cj` 整文件删除，`plugin_sqlite.cj` / `sqlite_ffi.cj` 的
   10 处 `@When[env != "ohos"]` 门禁摘除（真实现三端共用）——桩文件头注释写的就是这个条件

```
PASS sqlite exec {"changes":1,"lastInsertRowid":1}（读写连接建库建表）
PASS sqlite query round-trip rows=[[{integer,1},{text,cj-sqlite}]]（只读连接回读逐字一致）
PASS sqlite info {"sqliteVersion":"3.50.4","tableCount":1,"attachBlocked":true …}
PASS sqlite tables [{"name":"t","kind":"table","rows":1,"columns":2}]
PASS sqlite outside-scope rejected（scopes.sqlite 之外的 path 当场拒）
```

两个形状：① **只读命令对不存在的库如实报「no such database file」**（不顺手造空库）——
探针必须先 `exec`（读写连接建库）再 `info`/`query`/`tables`；② `query` 回读的每个单元格是
`{type, value}` 对象（`sqliteReadCell`），取 `rows[i][j].value`。

## 欠账清理（同轮）

- `scripts/test.sh` 入口加 `rm -rf /tmp/fs-unit-test`——fs 单测基座目录第二次跑撞
  「already exists」的欠账（会话交接 §四十五 留）。
- 骨架 `build-hap.sh` 模板（`cli/templates/ohos-skeleton/`）加 **assets 自动同步段**：
  构建前把工程根 `assets/ui`、`assets/capabilities` 拷进 rawfile——消除「改了 assets
  不 sync 直接构建、hap 装旧页且改动静默丢失」的坑（本轮 http 探针第一轮踩的）。
  本地生成物已同步该段并验证（构建日志出现 `assets 已从工程根同步到 rawfile`）。

---

## store 插件真机取证（同日第五轮，2026-10-25）

命令面跨平台共用、无平台代码改动——探针应用挂 `StorePlugin()`（落盘
`<cwd>/store.json`，鸿蒙 cwd = el2 files 目录，可写），权限集 `store:default`。

第一轮（`store-verify-hilog3.txt`，7 条断言）：

```
SKIP store persist first-round (no persisted key yet)   # 首轮无持久化键，如实记 SKIP
PASS store set true
PASS store get round-trip {"s":"cj-store","n":42,"nested":{"ok":true}}   # 任意 JSON 嵌套值逐字一致
PASS store keys ["probe-key"]
PASS store delete {"existed":true,"saved":true}
PASS store get-default "fallback"                        # 键删后取缺省值
PASS store clear / persist-write true                    # clear 后写 persist-key 供下一轮
```

第二轮（force-stop 重启，`store-verify-hilog4.txt`）：

```
PASS store persist survived-restart "cj-persist-1792897060760"   # 跨重启持久化的直接证据
```

**store 鸿蒙真机 7 PASS + 跨重启持久化成立**（force-stop 后 store.json 逐字回读）。
探针页注意：开场探 persist-key、末尾重写——每轮重启自动打一条 persist 证据。

### 同轮新坑：build-hap.sh 的 assets 同步段首版是嵌套拷贝

`cp -r "$APP_ROOT/assets/ui" "$RAWFILE/ui"` 在 `RAWFILE/ui` **已存在**时会把 src 拷成
`RAWFILE/ui/ui/`（嵌套目录）——rawfile 里的 index.html 静默变旧，探针行全无又无失败行
（store 首轮取证就栽在这里）。修法：先 `rm -rf "$RAWFILE/ui" "$RAWFILE/capabilities"` 再拷。
模板（`cli/templates/ohos-skeleton/build-hap.sh`）与本地生成物已同步修正，验证判据是
hap 内 `grep -c probeStore index.html` 非零。
