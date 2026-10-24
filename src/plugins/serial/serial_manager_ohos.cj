package cjTauri.plugins.serial

// 桌面侧看不到这个文件里的 `@When[env == "ohos"]` 函数体，`ArrayList` 就成「未使用」——
// 按 AGENTS §4「跨平台文件别按单平台警告去清 import」，给 import 加同款门禁，而不是删掉它。
@When[env == "ohos"]
import std.collection.*

/**
 * 鸿蒙侧 USB 串口后端：**如实降级，不做互操作**
 *
 * ## 为什么这里是空的（2026-10-24 真机 A/B 实测，别再徒手重试）
 *
 * 原本的落法是「仓颉侧经 `ohos.ark_interop` 调 `@ohos.usbManager.serial`」，三组对照把它否掉了：
 *
 * | 产物 | 内容 | 真机结果 |
 * | --- | --- | --- |
 * | 有互操作、真去用 | `spawn` 出 owner 线程建 `JSRuntime()` | 启动即 `signal:6`（SIGABRT），日志停在 `startApp begin`，`initScripts` 都没打印 |
 * | 只有互操作、从不执行 | 同名符号全留，owner 线程刻意不起 | **应用正常启动**，页面跑完自检（`pidof` 有、`page end label=main`） |
 * | 互操作整段摘掉 | 本文件上一版的空桩 | 同样正常启动 |
 *
 * 第三组证明「链接 `libohos.ark_interop.so` 本身无害」（`NEEDED` 里两个库、4 个 JSRuntime 符号都在，
 * 应用照跑）；**真正 abort 的是执行 `JSRuntime()`**。再补一个探针把创建点挪到 UI 线程
 * （`onWindowStageCreate`，与 ArkTS 同一条线程）——只打出 `runtime probe begin [ui-thread]`，
 * 结论行永远没出现、进程当场消失。所以不是「Cangjie 轻量线程没有 VM」，
 * 而是**纯仓颉进程里根本没有 ArkTS VM**；线程换哪儿都一样。
 *
 * 结论：`serialManager` 只能由**真正的 ArkTS 侧**调用（混合工程，或应用自己宿主 ArkTS 模块），
 * 不能关在框架插件的叶子内。ADR 见 `docs/设计决策记录.md` D-022 的 2026-10-24 结论段。
 *
 * ## 所以这里的选择
 *
 * 保持插件导出面（`serialOpen` 等已按句柄空间分流到这里），但一律**如实报不可用**——
 * 既不假装成功，也不让「没后台」变成「应用起不来」。POSIX 的 `/dev/ttyS*` 通路不受影响
 * （`serialOpen` 先试 POSIX，失败才落到这儿）。
 */

/** 降级原因（命令层原样回给前端，便于页面说清楚为什么不能开 USB 串口） */
@When[env == "ohos"]
const OHOS_USB_UNAVAILABLE: String =
    "USB 串口在鸿蒙上需要 ArkTS 侧调用 serialManager：纯仓颉进程里没有 ArkTS VM，" +
    "建 JSRuntime 会让进程 SIGABRT（真机 A/B 已证）；请改用 /dev/ttyS* 或走 ArkTS 宿主"

/** 句柄是否属于 USB 串口空间——降级后永远 false，`serialRead/Write/Close` 全部留在 POSIX 侧 */
@When[env == "ohos"]
public func usbSerialIsHandle(h: Int64): Bool {
    let _ = h
    return false
}

/** 枚举 USB 串口：降级后恒空（「没有 USB 串口」与「后端不可用」在命令层同形，原因进错误槽） */
@When[env == "ohos"]
public func usbSerialListNames(): ArrayList<String> {
    return ArrayList<String>()
}

/** 打开 USB 串口：恒回 -3（打不开/未授权）并写明原因 */
@When[env == "ohos"]
public func usbSerialOpenByPath(path: String, baud: Int32, dataBits: Int32, parity: Int32,
                                stopBits: Int32): Int64 {
    let _ = path
    let _ = baud
    let _ = dataBits
    let _ = parity
    let _ = stopBits
    serialOhosSetError(OHOS_USB_UNAVAILABLE)
    return -3
}

/** 读：不会有句柄走到这里（`usbSerialIsHandle` 恒 false），保留签名为了上层不分叉 */
@When[env == "ohos"]
public func usbSerialReadHandle(h: Int64, maxBytes: Int32, timeoutMs: Int32): Array<UInt8> {
    let _ = h
    let _ = maxBytes
    let _ = timeoutMs
    return Array<UInt8>(0, repeat: 0)
}

/** 写：同上，恒 0 字节 */
@When[env == "ohos"]
public func usbSerialWriteHandle(h: Int64, data: Array<UInt8>, timeoutMs: Int32): Int32 {
    let _ = h
    let _ = data
    let _ = timeoutMs
    return 0
}

/** 关句柄：同上，恒 -4 */
@When[env == "ohos"]
public func usbSerialCloseHandle(h: Int64): Int32 {
    let _ = h
    return -4
}
