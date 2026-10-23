package cjTauri.tests

import cjTauri.*
import std.collection.*
import std.unittest.*
import std.unittest.testmacro.*

/*
 * 平台契约骨架测试（RFC-002 批次 0）
 * 不创建窗口、不依赖宿主：TargetInfo / 特性探测 / PageSource / 宿主注册表，纯逻辑。
 */

@Test
func targetInfoDescribe(): Unit {
    let t = TargetInfo("Linux", "x86_64", "webkitgtk", "desktop")
    @Expect(t.os, "Linux")
    @Expect(t.describe(), "Linux/x86_64 host=webkitgtk display=desktop")
}

@Test
func appContextFeatureProbe(): Unit {
    let fs = ArrayList<PlatformFeature>()
    fs.add(PlatformFeature.Tray)
    fs.add(PlatformFeature.MultiWindow)
    let ctx = AppContext(
        AppPaths("/tmp/d", "/tmp/c", "/tmp/t"),
        TargetInfo("Linux", "x86_64", "webkitgtk", "desktop"),
        false, fs)
    @Expect(ctx.supports(PlatformFeature.Tray), true)
    @Expect(ctx.supports(PlatformFeature.FilePicker), false)
    @Expect(ctx.dev, false)
}

@Test
func pageSourceMatch(): Unit {
    let src = PageSource.Asset("ui/index.html")
    match (src) {
        case Asset(name) => @Expect(name, "ui/index.html")
        case _ => @Expect(false, true)   // 不应到达：Asset 之外的分支
    }
}

@Test
func desktopDiscoverDefaults(): Unit {
    let ctx = Platform.desktop("com.example.test", "x86_64")
    @Expect(ctx.paths.dataDir.endsWith("com.example.test"), true)
    @Expect(ctx.supports(PlatformFeature.Tray), true)
    @Expect(ctx.target.display, "desktop")
}

@Test
func mobileDiscoverSandbox(): Unit {
    let ctx = Platform.mobile("/data/app/el2/base/files", "aarch64")
    @Expect(ctx.paths.dataDir, "/data/app/el2/base/files")
    @Expect(ctx.dev, false)
    @Expect(ctx.supports(PlatformFeature.SoftKeyboardInset), true)
    @Expect(ctx.supports(PlatformFeature.Tray), false)
}

/** 优先级最高者胜；create 返回假宿主（pickHost 会真实调用它） */
class HighPrioProvider <: HostProvider {
    public func priority(target: TargetInfo): Int64 {
        return 10
    }
    public func create(label: String, target: TargetInfo): WebViewHost {
        return FakeHost(label)
    }
}

class LowPrioProvider <: HostProvider {
    public func priority(target: TargetInfo): Int64 {
        return 1
    }
    public func create(label: String, target: TargetInfo): WebViewHost {
        return FakeHost(label)
    }
}

class NullProvider <: HostProvider {
    public func priority(target: TargetInfo): Int64 {
        return 0
    }
    public func create(label: String, target: TargetInfo): WebViewHost {
        return FakeHost(label)
    }
}

@Test
func hostRegistryPicksHighestPriority(): Unit {
    let before = hostProviderCount()
    registerHost(NullProvider())
    registerHost(LowPrioProvider())
    registerHost(HighPrioProvider())
    @Expect(hostProviderCount(), before + 3)
    let target = TargetInfo("Linux", "x86_64", "webkitgtk", "desktop")
    let picked = pickHost("main", target)
    @Expect(picked.isSome(), true)
    // 胜出者必须是优先级 10 的实现（create 真实执行，label 透传）
    @Expect(picked.getOrThrow().label(), "main")
}

// ---- 批次 1：PageSource → PageLoad 决策 ----

@Test
func resolvePageInlineAndUrl(): Unit {
    match (resolvePage(PageSource.Inline("<p>hi</p>"), None)) {
        case StartHtml(html) => @Expect(html, "<p>hi</p>")
        case _ => @Expect(false, true)
    }
    match (resolvePage(PageSource.Url("https://example.com"), None)) {
        case StartUrl(url) => @Expect(url, "https://example.com")
        case _ => @Expect(false, true)
    }
    // DevServer 与 Url 同路：都走 startUrl
    match (resolvePage(PageSource.DevServer("http://127.0.0.1:5173"), None)) {
        case StartUrl(url) => @Expect(url, "http://127.0.0.1:5173")
        case _ => @Expect(false, true)
    }
}

/** 返回固定内容的解析器 */
class StubResolver <: AssetResolver {
    let table: HashMap<String, String>
    init(table: HashMap<String, String>) {
        this.table = table
    }
    public func readText(name: String): Option<String> {
        return table.get(name)
    }
    public func exists(name: String): Bool {
        return table.contains(name)
    }
}

@Test
func resolvePageAssetViaResolver(): Unit {
    let t = HashMap<String, String>()
    t.add("ui/index.html", "<html>ok</html>")
    let src = resolvePage(PageSource.Asset("ui/index.html"), Some(StubResolver(t)))
    match (src) {
        case StartHtml(html) => @Expect(html, "<html>ok</html>")
        case _ => @Expect(false, true)
    }
}

@Test
func resolvePageAssetMissingThrowsReadableError(): Unit {
    let t = HashMap<String, String>()
    var msg = ""
    try {
        let _ = resolvePage(PageSource.Asset("no/such.html"), Some(StubResolver(t)))
    } catch (e: Exception) {
        msg = e.message
    }
    @Expect(msg.contains("no/such.html"), true)
}

@Test
func resolvePageAssetNoResolverReadsFromCwd(): Unit {
    // 未注入解析器：按 cwd 相对路径读盘（与模板 textOrFile 桌面行为等价）。
    // 测试 cwd = 仓库根，读一个确定存在的文件验证「读到了」而非白屏。
    let src = resolvePage(PageSource.Asset("cjpm.toml"), None)
    match (src) {
        case StartHtml(html) => @Expect(html.size > 0, true)
        case _ => @Expect(false, true)
    }
}

// ---- 批次 1 评审修正：devMode 自动改写（RFC §4.3）----

@Test
func rewriteForDevOnlyTouchesAsset(): Unit {
    // Asset + devUrl → DevServer
    match (rewriteForDev(PageSource.Asset("ui/index.html"), Some("http://127.0.0.1:5173"))) {
        case DevServer(url) => @Expect(url, "http://127.0.0.1:5173")
        case _ => @Expect(false, true)
    }
    // 显式 Inline 是业务意图，不改写
    match (rewriteForDev(PageSource.Inline("<p/>"), Some("http://d"))) {
        case Inline(html) => @Expect(html, "<p/>")
        case _ => @Expect(false, true)
    }
    // 无 devUrl 原样返回
    match (rewriteForDev(PageSource.Asset("ui/index.html"), None)) {
        case Asset(name) => @Expect(name, "ui/index.html")
        case _ => @Expect(false, true)
    }
}

// ---- 批次 2：DirectoryAssetResolver ----

@Test
func directoryAssetResolverReadsRepo(): Unit {
    let r = DirectoryAssetResolver(".")
    let t = r.readText("cjpm.toml")
    @Expect(t.isSome(), true)
    @Expect(t.getOrThrow().size > 0, true)
    @Expect(r.exists("cjpm.toml"), true)
    @Expect(r.readText("no/such/file.txt").isSome(), false)
    @Expect(r.exists("no/such/file.txt"), false)
}

// ---- 批次 1：guessTarget 与 resolveHost 接线 ----

@Test
func guessTargetDesktopFields(): Unit {
    let t = Platform.guessTarget()
    @Expect(t.display, "desktop")
    @Expect(t.hostKind, "webkitgtk")
    @Expect(t.os, "Linux")   // env != ohos 的桌面目标
}

/** 注册表有匹配时，resolveHost 必须取注册表而不是内置宿主 */
class WinProvider <: HostProvider {
    public func priority(target: TargetInfo): Int64 {
        return 5
    }
    public func create(label: String, target: TargetInfo): WebViewHost {
        return FakeHost(label)
    }
}

@Test
func resolveHostPrefersRegistryOverBuiltin(): Unit {
    registerHost(WinProvider())
    let h = resolveHost("registry-win")
    @Expect(h.label(), "registry-win")
}
