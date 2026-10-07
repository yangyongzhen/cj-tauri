package cjTauri.tests

import cjTauri.*
import std.collection.*
import std.unittest.*
import std.unittest.testmacro.*

/*
 * 宿主级回调路由（C 侧句柄 → 本窗回调）的回归用例。
 *
 * 病根（docs/架构演进-多平台与多窗口.md §7.5）：C 侧所有回调只有一个模块级函数指针入口，
 * 仓颉侧若把「本窗回调」写进全局单槽，后装配的窗口就会覆盖先装配的——「哪扇窗关了」认错、
 * 两窗同时开文件框时结果串台。
 *
 * 这里用**真句柄**（cj_bridge_create 只分配宿主对象，不 init / 不 start、不碰图形栈）
 * 把「按句柄认领」钉死：回调签名退回不带句柄、或改回全局单槽，本文件的用例立刻红。
 * 句柄不销毁（cj_bridge_destroy 会走平台 fini）——测试进程退出时一并回收，泄漏两个 calloc 无妨。
 */

/** 取一个宿主句柄：只分配宿主对象（不 init / 不 start、不碰图形栈），拿不到就抛（后续断言才有意义） */
func newHandle(): CPointer<Unit> {
    let h = createBareHostHandle()
    if (h.isNull()) {
        throw Exception("cj_bridge_create 返回空句柄：单元测试拿不到宿主")
    }
    return h
}

@Test
func testDestroyRoutesByHandle(): Unit {
    let h1 = newHandle()
    let h2 = newHandle()
    let fired = ArrayList<String>()
    HostGlobals.registerHostRoute(h1, { _ => () }, { => fired.add("h1") }, { _ => () })
    HostGlobals.registerHostRoute(h2, { _ => () }, { => fired.add("h2") }, { _ => () })
    // 后装配的 h2 被销毁：只能触发 h2 自己那条（单槽实现会触发「最后装配的」，先装配的永远收不到）
    unsafe {
        hostOnDestroy(h2)
    }
    @Expect(fired.size, 1)
    @Expect(fired[0], "h2")
    // 再销毁先装配的 h1：它那条必须还在（单槽实现到这一步只会重新触发 h2）
    unsafe {
        hostOnDestroy(h1)
    }
    @Expect(fired.size, 2)
    @Expect(fired[1], "h1")
}

@Test
func testDialogResultLandsOnOwningWindow(): Unit {
    let h1 = newHandle()
    let h2 = newHandle()
    let got1 = ArrayList<String>()
    let got2 = ArrayList<String>()
    HostGlobals.registerHostRoute(h1, { _ => () }, { => () }, { p => got1.add(p) })
    HostGlobals.registerHostRoute(h2, { _ => () }, { => () }, { p => got2.add(p) })
    // h2 那扇窗的用户选了文件：结果只许落 h2（单槽实现会写进全局槽位，h1 的调用方读到别人的路径）
    unsafe {
        dialogOnResult(h2, LibC.mallocCString("/tmp/picked.txt"))
    }
    @Expect(got2.size, 1)
    @Expect(got1.size, 0)
    @Expect(got2[0], "/tmp/picked.txt")
}

@Test
func testShellEventRoutesByHandle(): Unit {
    let h1 = newHandle()
    let h2 = newHandle()
    let seen = ArrayList<String>()
    HostGlobals.registerHostRoute(h1, { json => seen.add("h1:" + json) }, { => () }, { _ => () })
    HostGlobals.registerHostRoute(h2, { json => seen.add("h2:" + json) }, { => () }, { _ => () })
    unsafe {
        shellOnEvent(h1, LibC.mallocCString("{\"kind\":\"menu\"}"))
    }
    @Expect(seen.size, 1)
    @Expect(seen[0], "h1:{\"kind\":\"menu\"}")
}

@Test
func testUnknownHandleIsIgnored(): Unit {
    let stranger = newHandle()
    let before = HostGlobals.hostRoutes.size
    // 没登记过的句柄：一律静默（C 侧回调不许把异常抛穿 FFI 边界），也不许往表里塞东西
    unsafe {
        hostOnDestroy(stranger)
        shellOnEvent(stranger, LibC.mallocCString("{\"kind\":\"menu\"}"))
        dialogOnResult(stranger, LibC.mallocCString("/tmp/x"))
    }
    @Expect(HostGlobals.hostRoutes.size, before)
}

@Test
func testRegisterIsIdempotentPerHandle(): Unit {
    let h = newHandle()
    let before = HostGlobals.hostRoutes.size
    let sink = ArrayList<String>()
    HostGlobals.registerHostRoute(h, { _ => () }, { => sink.add("old") }, { _ => () })
    // 同一句柄重新装配＝换掉旧闭包，不叠加（宿主被重新 prepare 时事件不许派发两次）
    HostGlobals.registerHostRoute(h, { _ => () }, { => sink.add("new") }, { _ => () })
    @Expect(HostGlobals.hostRoutes.size, before + 1)
    unsafe {
        hostOnDestroy(h)
    }
    @Expect(sink.size, 1)
    @Expect(sink[0], "new")
}
