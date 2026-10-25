# 多窗口 × sqlite/store 组合鸿蒙真机核验（2026-10-25，第四批）

设备：3QC0124B20000048（HarmonyOS PC / 2in1）
应用：ohos-capabilities（com.yang.testcj），第二窗 label `second` 由业务侧 `addWindow` 内联页面创建
hap：`entry-default-signed.hap` 10 176 225 字节
hilog 原文：`.atomcode/tmp/mw4.txt`（流式抓取，`hdc shell hilog >` 先起流再拉起应用）

## 结论

**多窗口按 label 路由成立，两窗互不串台**（47 PASS / 2 FAIL —— 两条 FAIL 是 mqtt / redis
的 mock 未启动，本轮不涉及这两个插件；2 INFO、2 SKIP）。

判据分四段，**缺任何一段都不算通过**：

### 1. 两窗各自登记、各自落页面（不共用一份）

```
CjTauri: host registered after 0 polls label=main
CjTauri: host registered after 0 polls label=second
CjTauri: host pageUrl label=main url="file:///data/storage/el2/base/haps/entry/files/cj-tauri-main.html"
CjTauri: host pageUrl label=second url="file:///data/storage/el2/base/haps/entry/files/cj-tauri-second.html"
CjTauri: host initScripts label=main count=9
CjTauri: host initScripts label=second count=1
CjTauri: aboutToAppear label=main pageUrl=file:///…/cj-tauri-main.html
CjTauri: aboutToAppear label=second pageUrl=file:///…/cj-tauri-second.html
CjTauri: page begin label=main
CjTauri: page begin label=second
CjTauri: page end label=second
CjTauri: page end label=main
```

页面文件名是 `cj-tauri-<label>.html`：两窗**不会共用一份**（共用就说明宿主登记串了）。
`initScripts` 条数不同是正常的——主窗页面走 shim 注入路径（9 段），第二窗是内联常量页（1 段）。

### 2. 页面自认 label 与原生路由一致

```
CjProbe: PASS second window up me=second
```

`me` 是页面读到的 `__CJ_TAURI_LABEL__`。这段的意义：页面**自己**认自己是 second，
而上面第 1 段的原生侧也按 second 登记——两边恒等才叫路由正确。

### 3. 第二窗的命令面独立可用（sqlite / store 往返）

```
CjProbe: PASS second sqlite round-trip v=cj-second
CjProbe: PASS second store round-trip v=second-value
```

第二窗用自己的库（`second-window.db`）写完读回、用 `second-key` 写进 store 读回。
同一轮主窗那边走的是另一个库与 `probe-key`，各自结果都对——**命令分发按窗口隔离**。

### 4. 定向投递必须发给**对面**窗口（这条才是路由的硬判据）

```
CjProbe: PASS main got directed event payload=from-second
CjProbe: INFO second emitted directed event to main
```

第二窗页面 `invoke('probeEmitTo', {target:'main', event:'crosstalk:probe'})` →
业务命令调 `app.emitToWindow(event, payload, "main")` → **主窗页面**的
`tauri.listen('crosstalk:probe', …)` 收到并回投上面那条 PASS。
**发给自己在错误实现下也会通过，等于没测**——所以必须跨窗（AGENTS §4 判据）。

## store 的 cross-window 观测（如实记录，不当隔离结论）

```
CjProbe: INFO second reads main-window key probe-key=absent
CjProbe: PASS store keys ["persist-key","probe-key","second-key"]
```

第二窗读主窗的 `probe-key` 得到 `absent`，但**主窗稍后 `store:keys` 里同时有 `second-key`**——
说明 store 是进程级共享（落盘 `<cwd>/store.json`），`absent` 只是**时序**：第二窗脚本轻量、
先跑完，那时主窗还没走完前序探针写入 `probe-key`。**不能把这条读成「store 按窗口隔离」**。

## 本轮踩的坑（已修）

### ① `AppSpec.wire` 是单槽：分两次 `.wire()` 会静默丢掉前一次

首轮 addWindow 单独写成一个 `.wire(...)`，被骨架里原有的 `.wire(...)` 覆盖，
表象是 `host not registered in 3s: label=second` + `aboutToAppear without host`（第二窗白屏），
而**第一条 wire 里的 `addWindow` 一行都没执行、日志里也没有任何提示**。
落法：所有 run 前装配（`addWindow` / `register` / `setMenu`）并进**同一个** lambda。

### ② 内联页面里的 SQL 字面量必须单引号

`INSERT INTO t2(v) VALUES (cj-second)` 报 `no such column: cj`——SQLite 把双引号优先当
**标识符**，未加引号的裸词被解析成列名。修正为 `VALUES ('cj-second')`（JS 侧把整条 SQL
换成双引号串，内层用单引号）。

### ③ 第二窗内联页的三引号常量必须以换行起始

仓颉三引号字符串吞首个换行（AGENTS §4），写 `"""<!DOCTYPE html>` 会报
`multi-line string must start with newline`。常量照 `"""` 后换行写。

## 复现命令

```bash
export CANGJIE_STDX_OHOS="$(cygpath -w ~/.cangjie/stdx/cangjie-stdx-ohos-aarch64-1.1.3.1/dynamic/stdx)"
cd examples/ohos/ohos-capabilities/targets/ohos && bash build-hap.sh --clean
cd entry/build/default/outputs/default && hdc install -r entry-default-signed.hap
hdc shell "aa force-stop com.yang.testcj"
(hdc shell hilog > /tmp/mw.txt &) ; sleep 1
hdc shell aa start -a EntryAbility -b com.yang.testcj
# 约 45s 后（第二窗定向投递延迟 2.5s）
grep -a "CjProbe\|CjTauri" /tmp/mw.txt | grep -aE "label=second|directed|round-trip|me=second"
```
