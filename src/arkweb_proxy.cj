package cjTauri

/**
 * HarmonyOS ArkWeb 的**桥接函数**（ArkUI-free 的那一半）
 *
 * ## 为什么组件本体不在这里
 *
 * 2026-10-19 真机定位到一个必须先说清的硬约束：**框架包（独立编译单元，`output-type = "static"`）
 * 一旦 import `kit.ArkUI.*` / `kit.ArkWeb.*` / `ohos.arkui.component.web.Web`，应用就会在启动瞬间
 * 死在包初始化**——`InitCJLibrary → cangjie_entry::package_global_init → cjTauri::package_global_init`
 * 里那条 `bl _CGP9kit.ArkUIiiHv@plt` 跳进未映射地址，`hilog` 里只有一行
 * `SIGSEGV(SEGV_MAPERR)@0x0004exxx`，窗口起不来、我方日志一行都没有。
 *
 * 判据来自一组对照实验（都在这台真机上跑的）：
 * 1. 入口包自己写 `@Component` + `Web`（不引用框架）→ 正常启动，还拉起了 `:gpu` / `:render`；
 * 2. 入口包只引用框架的一个字符串常量（`DEFAULT_WINDOW_LABEL`）→ 照样崩在包初始化；
 * 3. 把 `arkweb_view.cj`（框架里唯一碰 ArkUI 的文件）移出编译 → 立刻正常启动
 *    （`onCreated` / `onWindowStageCreate` 都有、`SIGSEGV` 计数为 0）。
 *
 * 也就是说：**同一张 PLT 表，在入口包里调用 `_CGP9kit.ArkUIiiHv` 是好的，在框架包里就解析不了。**
 * 所以 ArkUI 声明式组件只能由**应用模块**持有（这也正是 ArkUI 的模型：组件树属于应用的 UIAbility），
 * 框架这边只保留与 UI 无关的接线——报文、脚本队列、label 注入。
 *
 * 应用侧要写的东西见 `docs/鸿蒙ArkWeb接入踩坑.md`：一个 `@Component`，`build()` 里放 `Web(...)` 并
 * 把下面两个函数塞进 `javaScriptProxy` 的 `funcList`。
 */

/**
 * 页面 → 原生：`javaScriptProxy` 的 `post`（同步调用，返回值无意义）
 *
 * ArkWeb 的 proxy 只能挂在组件上，且回调签名固定为 `(String) -> String`；窗口身份靠
 * **闭包捕获 label** 传进来（应用侧写 `{ raw => arkWebProxyPost(this.windowLabel, raw) }`），不靠全局单槽——
 * 多窗口下静态单槽会让后建的窗口认领先前窗口的报文（AGENTS §4 的「静态单槽」坑）。
 */
@When[env == "ohos"]
public func arkWebProxyPost(label: String, raw: String): String {
    match (ArkWebRuntime.hostFor(label)) {
        case Some(h) => h.acceptPageMessage(raw)
        case None => ()
    }
    return ""
}

/**
 * 原生 → 页面：`javaScriptProxy` 的 `poll`（同步调用，返回待执行脚本的 JSON 数组）
 *
 * 页面侧 `setInterval` 每 10ms 拉一次（见 `ARKWEB_BRIDGE_JS` 的 pump）——
 * 这样框架线程不需要定时器、也不需要碰 ArkUI。
 */
@When[env == "ohos"]
public func arkWebProxyPoll(label: String): String {
    match (ArkWebRuntime.hostFor(label)) {
        case Some(h) => return h.pollScriptsJson()
        case None => return "[]"
    }
}
