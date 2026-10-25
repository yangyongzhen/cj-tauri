# http 插件鸿蒙真机核验（2026-10-25）

设备：3QC0124B20000048（鸿蒙 PC / 2in1）
应用：ohos-capabilities（com.yang.testcj），探针页启动自跑，断言经 probeLog 写 hilog（tag CjProbe）
hilog 原文：`.atomcode/tmp/http-verify-hilog4.txt`（流式抓取，09:20 轮）

## 结论：http 插件鸿蒙支（src/plugins/http/http_ohos.cj）真机核验通过，4/4

```
CjProbe: PASS http https-get status=200 ctype=text/html len=2349 truncated=false
CjProbe: PASS http plain-get status=200 len=2287
CjProbe: PASS http post status=200 echoed=true len=544
CjProbe: PASS http postStream rejected: http:postStream is not available on HarmonyOS: the system network stack returns the whole body at once (no incremental chunks). Use http:post instead.
```

四条核验点对应：
1. **https GET 走系统栈 TLS** —— https://www.baidu.com/ 回 200（此前 stdx 侧 https 全灭的缺陷已消除）；
2. **http GET（非 TLS）照旧** —— 200；
3. **POST 体经 `extraData: StringData(body)`** —— https://httpbin.org/post 回 200 且回显含请求体（echoed=true）；
4. **http:postStream 如实拒绝** —— 报文原样带回「系统栈一次回整包、用 http:post」的说明，无假句柄。

## 本轮修复的两处（会话交接 §四十五「两处形状待真机确认」的答案）

- **`HttpRequestOptions.extraData` 收 `HttpData` 枚举，不是 `String`**：
  真机首编即报 `expected 'Enum-HttpData', found 'Struct-String'`，
  修法 `src/plugins/http/http_ohos.cj`：`extraData: body` → `extraData: StringData(body)`。
- **`RequestMethod.Post` / `.Delete` 成员名正确**（编译即证，无需改）。

## 顺手踩掉的一个链接坑（同「剪贴板 libpasteboard」族）

加了 http 插件后应用启动即加载失败：
`relocating failed: symbol not found … ohos.net.http:HttpResponse.ti`——
`ohos.net.http` 模块符号在 `libohos.net.http.so`，但 entry（最终链接侧）的 link-option 没有
`-lohos.net.http`。已修 `cli/src/manifest.cj` `renderOhosEntryToml`（两个 arch 段都加），
本地生成物 `targets/ohos/entry/cjpm.toml` 同步。

## 另一个流程坑：assets 不会自动进 hap

`assets/ui/index.html` 与 `assets/capabilities/default.json` 改完直接 `build-hap.sh`，
hap 里装的仍是**骨架 rawfile 里的旧页**（页面自检看起来在跑、其实一行 http 都没发）。
本轮手动 `cp` 进 `targets/ohos/entry/src/main/resources/rawfile/{ui,capabilities}/`。
正规修法是重跑 `cj-tauri sync ohos`（CLI 需另行构建，本轮未做）。

## 同轮回归面

能力位 5/5（menu=true，其余如实 false）、版本、菜单勾选回写、剪贴板（写通/读被平台挡 SKIP）
全部与 2026-10-24 取证一致，无回归。
