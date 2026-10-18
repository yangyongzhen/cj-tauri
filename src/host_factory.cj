package cjTauri

/**
 * 应用侧注入的宿主工厂（自定义平台的装配入口）
 *
 * 内置平台（Windows / 桌面 Linux）由 `createHost()` 直接选实现；没有内置宿主的平台
 * （鸿蒙 ArkWeb，以及 ARM64 Linux——两者 `os` 都报 `Linux`，只能用 `arch` 分开）
 * 由应用在**构造 `TauriApp()` 之前**注册工厂：
 *
 * ```
 * setHostFactory({ label => MyArkWebHost(label) })
 * let app = TauriApp()
 * ```
 *
 * 为什么放在框架外：ArkWeb 的宿主必须直接建 ArkUI 组件（`Web` + `WebviewController`），
 * 框架核心一旦 import 这些 kit，桌面目标的构建也要跟着拉 ArkUI 依赖。把「建组件」留在应用、
 * 把「桥与事件」留在框架，两边各自只依赖自己的那半边。
 *
 * 单一职责：本文件只管「工厂登记」这一件事，装配时机与语义见上面注释。
 */
private var HOST_FACTORY: Option<(String) -> WebViewHost> = None

/**
 * 注册自定义 WebView 宿主工厂（必须在构造 `TauriApp()` 之前调用）
 *
 * label 与内置宿主同义（默认窗口是 `DEFAULT_WINDOW_LABEL`）：工厂会为每个窗口各调一次，
 * 实现方要保证「一个 label 一个宿主实例」，否则多窗口下事件会串台。
 * 重复调用＝替换而非叠加（只保留最后一次登记）。
 */
public func setHostFactory(factory: (String) -> WebViewHost): Unit {
    HOST_FACTORY = Some(factory)
}

/**
 * 取注入的宿主；没登记就抛一条**可照做**的错误
 *
 * 不静默回落到空实现：宿主缺席时应用会拿到一个永远开不出窗口的对象，
 * 比启动即失败更难排查（AGENTS §1 第 4 条：跑不起来要如实说明）。
 */
func requireInjectedHost(label: String): WebViewHost {
    match (HOST_FACTORY) {
        case Some(factory) => return factory(label)
        case None =>
            throw CommandException(
                "当前平台没有内置 WebView 宿主：请在构造 TauriApp() 之前调用 cjTauri.setHostFactory({ label => ... }) 注入实现（鸿蒙 ArkWeb 走这条通路）"
            )
    }
}
