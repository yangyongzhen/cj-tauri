package cjTauri.tests

import cjTauri.*
import cjTauri.platform.*
import cjTauri.plugins.store.*
import std.collection.*
import std.unittest.*
import std.unittest.testmacro.*

// ---- 批次 3-PR1：AppSpec 构造器链与 assemble 装配 ----

@Test
func appSpecBuilderChain(): Unit {
    let spec = AppSpec()
        .page(PageSource.Inline("<p/>"))
        .window(WindowConfig("t", 800, 600))
        .capabilities("assets/capabilities")
        .capabilityJson("{\"identifier\":\"default\"}")
    @Expect(spec.appId, "")
    @Expect(spec.capabilitiesDir, "assets/capabilities")
    @Expect(spec.capabilityJsons.size, 1)
    @Expect(spec.windowConfig.title, "t")
    @Expect(spec.windowConfig.width, 800)
    @Expect(spec.assetResolver.isSome(), false)
    @Expect(spec.wireFn.isSome(), false)
    @Expect(spec.plugins.size, 0)
    match (spec.pageSource) {
        case Inline(html) => @Expect(html, "<p/>")
        case _ => @Expect(false, true)
    }
}

/** wire 闭包执行标记（仓颉闭包捕获 var 的语义不冒风险，用对象装状态） */
class WireBox {
    public var on: Bool = false
}

/** 高优先级假宿主：TauriApp 字段初始化就调 resolveHost，无显示环境必须用注册表桩 */
class AppSpecProbeProvider <: HostProvider {
    public var last: FakeHost = FakeHost("seed")

    public func priority(target: TargetInfo): Int64 {
        let _ = target
        return 100
    }

    public func create(label: String, target: TargetInfo): WebViewHost {
        let _ = target
        this.last = FakeHost(label)
        return this.last
    }
}

@Test
func appSpecAssembleWiresApp(): Unit {
    let prov = AppSpecProbeProvider()
    registerHost(prov)
    let box = WireBox()
    let spec = AppSpec()
        .page(PageSource.Inline("<p/>"))
        .window(WindowConfig("spec窗", 640, 480))
        .plugin(StorePlugin())
        .wire({ _ =>
            box.on = true
        })
    let app = assemble(spec)
    @Expect(box.on, true)
    @Expect(app.hostOf("main").isSome(), true)
    @Expect(prov.last.label(), "main")
}

// ---- 批次 3-PR3：load(source) 收敛——装配层把 PageSource 原样交给宿主，resolver 随装配进宿主 ----

@Test
func fakeHostLoadDispatchesPageSource(): Unit {
    let h = FakeHost("main")
    h.load(PageSource.Inline("<p>hi</p>"))
    @Expect(h.shownHtml, "<p>hi</p>")
    @Expect(h.startedUrl, "")
    h.load(PageSource.Url("https://example.com"))
    @Expect(h.startedUrl, "https://example.com")
    h.load(PageSource.DevServer("http://127.0.0.1:5173"))
    @Expect(h.startedUrl, "http://127.0.0.1:5173")
    h.load(PageSource.Asset("ui/index.html"))
    @Expect(h.loadedSource, "asset:ui/index.html")
}

/** run 路径探针：优先级压过既有注册表里的桩，保证本用例拿到的是自己造的宿主 */
class RunProbeProvider <: HostProvider {
    public var last: FakeHost = FakeHost("seed")

    public func priority(target: TargetInfo): Int64 {
        let _ = target
        return 200
    }

    public func create(label: String, target: TargetInfo): WebViewHost {
        let _ = target
        this.last = FakeHost(label)
        return this.last
    }
}

/**
 * run() 路径：resolver 注入与页面来源交接发生在同一次装配（runWith）里。
 * 宿主用 FakeHost 桩（不建窗口）；run() 放后台线程，观测到交接后置 quitNow 让它返回。
 */
@Test
func runHandsResolverAndSourceToHost(): Unit {
    let prov = RunProbeProvider()
    let provIdx = registerHost(prov)
    let spec = AppSpec()
        .page(PageSource.Asset("ui/index.html"))
        .window(WindowConfig("t", 640, 480))
        .assets(StubResolver(HashMap()))
    spawn {
        let app = assemble(spec)
        app.run(spec.pageSource)
    }
    var polls = 0
    while (polls < 1000 && prov.last.loadedSource != "asset:ui/index.html") {
        sleep(Duration.millisecond * 2)
        polls += 1
    }
    @Expect(prov.last.loadedSource, "asset:ui/index.html")
    @Expect(prov.last.resolverInjected.isSome(), true)
    prov.last.quitNow = true
    // 探针宿主清出全局注册表，免得压过后续用例自己的桩
    unregisterHost(provIdx)
}
