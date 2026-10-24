package cjTauri

/**
 * 鸿蒙侧 pasteboard 的唯一依赖：`LibC.mallocCString` / `malloc` / `free`
 *
 * 加 `@When` 门禁是必须的——桌面两平台走 C 桥（下面那段 `cj_bridge_clipboard_*`），
 * 用不到 LibC；不门禁就会在桌面构建里变成一条 `unused import` 警告（AGENTS §3 零警告）。
 */
@When[env == "ohos"]
import std.posix.*


/**
 * 剪贴板 / 通知桥（plugin_clipboard、plugin_notification 的 FFI 面）：
 * C 桥 `cj_bridge_clipboard_*` / `cj_bridge_notification_*` 的声明与薄包装。
 *
 * 桌面两平台导出同名同签名（AGENTS §2 的硬约束），平台差异全在
 * `native/bridge_*.c` 里——Linux 是 GTK clipboard + GDBus，Windows 是 Win32 clipboard +
 * 通知桩（返回 -4 未实现）。所以仓颉侧一份声明就能同时编两个平台，上层不需要平台分支。
 *
 * 这组导出**收宿主句柄**：剪贴板与通知是宿主能力（GTK 环境依赖 / UI 线程投递），
 * 与对话框同一类——必须等宿主就绪，句柄由 WebViewHost 持有。
 *
 * ## 鸿蒙侧为什么整段门禁掉（2026-10-19）
 *
 * 鸿蒙没有 C 桥产物（`native/platforms/harmonyos/` 目前只有契约），这四个符号无处解析。
 * 留着的风险不是「编译报错」而是**模块加载期 SIGSEGV**——与 `log_bridge.cj` 那次
 * 白屏三轮同源（AGENTS §4 最后一条：不带 `@When` 的核心 `foreign func` 在无桥平台
 * 会留成未解析符号，`llvm-nm -D --undefined-only` 能一眼看出）。
 *
 * 门禁后鸿蒙侧**没有**这组导出，插件要剪贴板能力得走 `WebViewHost.clipboardWriteText` /
 * `clipboardReadText`（`ArkWebHost` 目前如实返回 false / None，等 pasteboard 模块接上）；
 * 谁在这儿补回同名导出，就等于把「宿主能力位 = 0」这条如实约定破坏掉。
 */

/**
 * 写文本进系统剪贴板（8 MiB 上限在 C 侧 core 校验）。0 = 成功；-1 参数非法，-3 宿主未就绪 / 平台失败。
 */
@When[env != "ohos"]
@C
foreign func cj_bridge_clipboard_write_text(h: CPointer<Unit>, text: CString): Int32

/**
 * 读系统剪贴板文本：返回 malloc 的 UTF-8 字符串（NULL = 剪贴板为空 / 非文本 / 平台失败）。
 * 返回值必须经 `cj_bridge_clipboard_free` 释放——**不许**在仓颉侧 free（跨 CRT 堆不安全）。
 */
@When[env != "ohos"]
@C
foreign func cj_bridge_clipboard_read_text(h: CPointer<Unit>): CString

/**
 * 释放 read_text 返回的缓冲（NULL 安全，幂等）
 */
@When[env != "ohos"]
@C
foreign func cj_bridge_clipboard_free(s: CString): Unit

/**
 * 发一条系统通知（发后即忘：投递即返回，显示成败不回传）。
 * 0 = 已提交；-1 参数非法（title 空 / 超长），-3 宿主未就绪 / 平台失败，-4 本平台未实现。
 */
@When[env != "ohos"]
@C
foreign func cj_bridge_notification_notify(h: CPointer<Unit>, title: CString, body: CString): Int32

/* ==========================================================================
 * 鸿蒙侧剪贴板：直接 FFI 到原生 pasteboard（`libpasteboard.so`）
 *
 * ## 为什么不是 `ohos.pasteboard`
 *
 * 仓颉套件里**没有**这个包。查过两套 SDK 的包清单（`api/lib/linux_ohos_aarch64_cjnative/`）：
 * 6.1（apiVersion 24，`build-hap.sh` 默认选它的那套）的 340 个 ohos 包里没有 pasteboard，
 * `kit/` 下也没有再导出；只有旧的 5.0（apiVersion 15，Beta2）带 `ohos.pasteboard.cjo`。
 * 于是在设备上能用的只有原生 C API（`native/sysroot/usr/include/database/pasteboard/`，
 * 同一 sysroot 里就有 `libpasteboard.so`，`entry/cjpm.toml` 的 `-L` 已指着它）。
 *
 * ## 为什么这不算「破坏宿主能力位如实约定」
 *
 * 平台差异只落在 `@When[env == "ohos"]` 这一处（AGENTS §2 允许的第二个落点就是条件编译），
 * 桌面两平台仍走 C 桥同名导出，上层（`WebViewHost.clipboardWriteText/ReadText`）一行都不用分叉。
 *
 * ## 权限前提（判据在设备上，不在代码里）
 *
 * 写（SetData）不需要权限；**读（GetData）要 `ohos.permission.READ_PASTEBOARD`**
 * （`udmf_datashare_config.json` 里是 user_grant + system_basic）。普通签名的应用拿不到该权限时，
 * GetData 不抛异常、只回空数据 / 非 0 状态——所以读路径**只能靠真机实测**判定通没通，
 * 代码里不许假设它「应该能读」。`arkwebClipboardReadText` 因此对「空 / 被拒 / 非文本」一律回 None。
 * ========================================================================== */

/** 取本进程的粘贴板句柄（失败回空指针） */
@When[env == "ohos"]
@C
foreign func OH_Pasteboard_Create(): CPointer<Unit>

@When[env == "ohos"]
@C
foreign func OH_Pasteboard_Destroy(pasteboard: CPointer<Unit>): Unit

/** 0 = 成功；非 0 = 平台拒绝（状态码见 `oh_pasteboard_err_code.h`） */
@When[env == "ohos"]
@C
foreign func OH_Pasteboard_SetData(pasteboard: CPointer<Unit>, data: CPointer<Unit>): Int32

/** 读：`status` 是出参（`Pasteboard_Status` 的 0 是 E_OK）；返回的 UdmfData 由调用方 Destroy */
@When[env == "ohos"]
@C
foreign func OH_Pasteboard_GetData(pasteboard: CPointer<Unit>, status: CPointer<Int32>): CPointer<Unit>

@When[env == "ohos"]
@C
foreign func OH_UdmfData_Create(): CPointer<Unit>

@When[env == "ohos"]
@C
foreign func OH_UdmfData_Destroy(pThis: CPointer<Unit>): Unit

@When[env == "ohos"]
@C
foreign func OH_UdmfData_AddRecord(pThis: CPointer<Unit>, record: CPointer<Unit>): Int32

/** 取「主纯文本」（不必自己遍历 records）；没有纯文本时回非 0 */
@When[env == "ohos"]
@C
foreign func OH_UdmfData_GetPrimaryPlainText(data: CPointer<Unit>, plainText: CPointer<Unit>): Int32

@When[env == "ohos"]
@C
foreign func OH_UdmfRecord_Create(): CPointer<Unit>

@When[env == "ohos"]
@C
foreign func OH_UdmfRecord_Destroy(pThis: CPointer<Unit>): Unit

@When[env == "ohos"]
@C
foreign func OH_UdmfRecord_AddPlainText(pThis: CPointer<Unit>, plainText: CPointer<Unit>): Int32

@When[env == "ohos"]
@C
foreign func OH_UdsPlainText_Create(): CPointer<Unit>

@When[env == "ohos"]
@C
foreign func OH_UdsPlainText_Destroy(pThis: CPointer<Unit>): Unit

@When[env == "ohos"]
@C
foreign func OH_UdsPlainText_SetContent(pThis: CPointer<Unit>, content: CString): Int32

/** 回的是库内自有缓冲（**不要** free），并发的另一次读会让它失效——取到就立刻拷成 String */
@When[env == "ohos"]
@C
foreign func OH_UdsPlainText_GetContent(pThis: CPointer<Unit>): CString

/**
 * 写文本进系统剪贴板（鸿蒙侧）。true = 平台接受了这次写入。
 *
 * 收尾是**显式**的：本机仓颉没有 `defer`（实测 `error: undeclared identifier 'defer'`），
 * 每个出口都要自己 Destroy，漏一个就是一处泄漏。
 */
@When[env == "ohos"]
public func arkwebClipboardWriteText(text: String): Bool {
    let pb = unsafe { OH_Pasteboard_Create() }
    if (unsafe { pb.isNull() }) {
        return false
    }
    let data = unsafe { OH_UdmfData_Create() }
    let record = unsafe { OH_UdmfRecord_Create() }
    let plain = unsafe { OH_UdsPlainText_Create() }
    if (unsafe { data.isNull() } || unsafe { record.isNull() } || unsafe { plain.isNull() }) {
        unsafe { OH_UdsPlainText_Destroy(plain) }
        unsafe { OH_UdmfRecord_Destroy(record) }
        unsafe { OH_UdmfData_Destroy(data) }
        unsafe { OH_Pasteboard_Destroy(pb) }
        return false
    }
    let content = unsafe { LibC.mallocCString(text) }
    var ok = false
    if (unsafe { OH_UdsPlainText_SetContent(plain, content) } == 0) {
        if (unsafe { OH_UdmfRecord_AddPlainText(record, plain) } == 0) {
            if (unsafe { OH_UdmfData_AddRecord(data, record) } == 0) {
                ok = unsafe { OH_Pasteboard_SetData(pb, data) } == 0
            }
        }
    }
    unsafe { LibC.free(content) }
    unsafe { OH_UdsPlainText_Destroy(plain) }
    unsafe { OH_UdmfRecord_Destroy(record) }
    unsafe { OH_UdmfData_Destroy(data) }
    unsafe { OH_Pasteboard_Destroy(pb) }
    return ok
}

/**
 * 读系统剪贴板文本（鸿蒙侧）：None = 空 / 非文本 / 平台拒绝（含缺 READ_PASTEBOARD 权限）。
 *
 * 三种 None 在页面侧看起来一样，**这是有意的**：WebViewHost 的契约就是 Option，
 * 平台没给出文本与平台拒绝了读取，对调用方是同一个「没拿到」。要区分得看 hilog 里的
 * `[cj-bridge] pasteboard read status=` 行（由应用侧 `probeLog` 打，框架侧 eprintln 在设备上不可见）。
 */
@When[env == "ohos"]
public func arkwebClipboardReadText(): Option<String> {
    let pb = unsafe { OH_Pasteboard_Create() }
    if (unsafe { pb.isNull() }) {
        return None
    }
    let statusBox = unsafe { LibC.malloc<Int32>(count: 1) }
    if (unsafe { statusBox.isNull() }) {
        unsafe { OH_Pasteboard_Destroy(pb) }
        return None
    }
    let statusPtr = unsafe { CPointer<Int32>(statusBox) }
    unsafe { statusPtr.write(0) }
    let data = unsafe { OH_Pasteboard_GetData(pb, statusPtr) }
    var out: Option<String> = None
    if (!unsafe { data.isNull() }) {
        let plain = unsafe { OH_UdsPlainText_Create() }
        if (!unsafe { plain.isNull() }) {
            if (unsafe { OH_UdmfData_GetPrimaryPlainText(data, plain) } == 0) {
                let cstr = unsafe { OH_UdsPlainText_GetContent(plain) }
                if (!unsafe { cstr.isNull() }) {
                    let value = unsafe { cstr.toString() }
                    out = Some(value)
                }
            }
            unsafe { OH_UdsPlainText_Destroy(plain) }
        }
        unsafe { OH_UdmfData_Destroy(data) }
    }
    unsafe { LibC.free(statusBox) }
    unsafe { OH_Pasteboard_Destroy(pb) }
    return out
}
