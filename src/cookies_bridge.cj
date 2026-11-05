package cjTauri

/**
 * Cookie 读取桥（「一键导出各平台登录态」类工具的平台面）。
 *
 * ## 为什么必须走原生，而不是注入 JS 读 `document.cookie`
 *
 * **httpOnly**。各平台的会话令牌（知乎 `z_c0`、掘金 `sessionid`、开源中国 `oscid`、
 * 百家号 `BDUSS` …）基本都是 httpOnly Cookie，JS 侧完全看不见。用 `document.cookie`
 * 那条路导出来的文件「字段看着齐全」，发文却 401——比导不出来更难查。cookie store 才是全量快照。
 *
 * ## 平台差异在哪
 *
 * 两平台导出同名同签名（AGENTS §2 的硬约束），差异全在 `native/platforms/` 下的平台文件：
 * Linux = `webkit_cookie_manager_get_all_cookies`（异步，GList<SoupCookie>），
 * Windows = `ICoreWebView2CookieManager::GetCookies`（异步，ICoreWebView2CookieList）。
 *
 * ## 鸿蒙侧为什么整段门禁掉
 *
 * 鸿蒙没有 C 桥产物，这两个符号无处解析；留着的风险不是编译报错，而是**模块加载期
 * SIGSEGV**（同 `clipboard_bridge.cj` 那次白屏，AGENTS §4 最后一条）。
 */

/**
 * 读宿主 WebView 的 cookie 仓库。返回 **malloc 的 JSON**，必须经 `cj_bridge_cookies_free` 释放。
 *
 * 成功：`{"ok":true,"count":N,"cookies":[{"name","value","domain","path","secure","httpOnly","expires","session"}]}`
 * 失败：`{"ok":false,"error":"…"}` —— 失败也返回 JSON，调用方永远不必判空指针。
 *
 * `filter` = 域名后缀（`"csdn.net"` 命中 `.csdn.net` / `www.csdn.net`），空串 = 全部。
 *
 * **线程口径**：必须在命令 worker 线程调用——内部投 UI 线程发起异步读并带 5s 超时；
 * 站在 UI 线程上调用会直接拿到错误 JSON（等待的事件得由 UI 线程处理，阻塞即自死锁）。
 */
@When[env != "ohos"]
@C
foreign func cj_bridge_get_cookies(h: CPointer<Unit>, filter: CString): CString

/** 释放 get_cookies 返回的缓冲（NULL 安全，幂等） */
@When[env != "ohos"]
@C
foreign func cj_bridge_cookies_free(s: CString): Unit
