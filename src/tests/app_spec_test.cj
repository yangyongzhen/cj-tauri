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
    @Expect(spec.appId, "")
    @Expect(spec.capabilitiesDir, "assets/capabilities")
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
        return 100
    }

    public func create(label: String, target: TargetInfo): WebViewHost {
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
        .wire({ app =>
            box.on = true
        })
    let app = assemble(spec)
    @Expect(box.on, true)
    @Expect(app.hostOf("main").isSome(), true)
    @Expect(prov.last.label(), "main")
}
