package cjTauri.plugins.serial

/**
 * ohos 侧 serial 桩（RFC §4.6.4 P-1）：插件子包三端必须可编译——某端未接通的能力，
 * 在子包内给「调用即可照做地报错」的桩实现（业务 build() 三端共用、import 全部所用插件，
 * 不能靠编译期排除子包兜底——与「业务零平台分支」冲突，RFC §4.6.4 有完整论证）。
 *
 * 真实现批次 4 走 NDK FFI 接通（§4.6.5 四通道决策）；届时删掉本文件的桩，
 * 并在 serial_bridge.cj / plugin_serial.cj 的同名函数上补 ohos 实现段。
 * 桩行为与 SerialPlugin.describe().supportedHosts（webkitgtk + webview2）严格一致（P-2）。
 */

@When[env == "ohos"]
import std.collection.*

@When[env == "ohos"]
import cjTauri.*

@When[env == "ohos"]
public func serialOpen(path: String, baud: Int32, dataBits: Int32, parity: Int32,
                       stopBits: Int32): Int64 {
    throw CommandException("serial: 打开串口在 ohos 端暂不支持（P-1 桩，批次 4 走 NDK FFI 接通，见 RFC §4.6.4）")
}

/**
 * 桩的 lastError 返回可读文案而不是抛异常：桌面口径里它出现在错误消息拼接里
 * （`serial:open failed (code …): ${serialLastError()}`），抛异常会打断拼接。
 */
@When[env == "ohos"]
public func serialLastError(): String {
    return "serial: 串口在 ohos 端尚未接通（P-1 桩，批次 4 走 NDK FFI，见 RFC §4.6.4）"
}

@When[env == "ohos"]
public func serialListC(): Option<ArrayList<String>> {
    return None
}

@When[env == "ohos"]
public func serialRead(h: Int64, maxBytes: Int32, timeoutMs: Int32): Array<UInt8> {
    throw CommandException("serial: 读串口在 ohos 端暂不支持（P-1 桩，批次 4 走 NDK FFI 接通，见 RFC §4.6.4）")
}

@When[env == "ohos"]
public func serialWrite(h: Int64, data: Array<UInt8>, timeoutMs: Int32): Int32 {
    throw CommandException("serial: 写串口在 ohos 端暂不支持（P-1 桩，批次 4 走 NDK FFI 接通，见 RFC §4.6.4）")
}

@When[env == "ohos"]
public func serialClose(h: Int64): Int32 {
    throw CommandException("serial: 关闭串口在 ohos 端暂不支持（P-1 桩，批次 4 走 NDK FFI 接通，见 RFC §4.6.4）")
}

/**
 * 枚举桩抛异常而不是返回空数组：空数组在页面侧语义是「没有串口」，
 * 与「端不支持」是两回事（P-2 的如实失败）。
 */
@When[env == "ohos"]
public func serialPortList(): ArrayList<String> {
    throw CommandException("serial: 枚举串口在 ohos 端暂不支持（P-1 桩，批次 4 走 NDK FFI 接通，见 RFC §4.6.4）")
}
