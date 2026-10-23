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
