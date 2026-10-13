package cjTauri


/**
 * 剪贴板 / 通知桥（plugin_clipboard、plugin_notification 的 FFI 面）：
 * C 桥 `cj_bridge_clipboard_*` / `cj_bridge_notification_*` 的声明与薄包装。
 *
 * 这里**不带 @When**：两平台的导出同名同签名（AGENTS §2 的硬约束），平台差异全在
 * `native/bridge_*.c` 里——Linux 是 GTK clipboard + GDBus，Windows 是 Win32 clipboard +
 * 通知桩（返回 -4 未实现）。所以仓颉侧一份声明就能同时编两个平台，上层不需要平台分支。
 *
 * 这组导出**收宿主句柄**：剪贴板与通知是宿主能力（GTK 环境依赖 / UI 线程投递），
 * 与对话框同一类——必须等宿主就绪，句柄由 WebViewHost 持有。
 */

/**
 * 写文本进系统剪贴板（8 MiB 上限在 C 侧 core 校验）。0 = 成功；-1 参数非法，-3 宿主未就绪 / 平台失败。
 */
@C
foreign func cj_bridge_clipboard_write_text(h: CPointer<Unit>, text: CString): Int32

/**
 * 读系统剪贴板文本：返回 malloc 的 UTF-8 字符串（NULL = 剪贴板为空 / 非文本 / 平台失败）。
 * 返回值必须经 `cj_bridge_clipboard_free` 释放——**不许**在仓颉侧 free（跨 CRT 堆不安全）。
 */
@C
foreign func cj_bridge_clipboard_read_text(h: CPointer<Unit>): CString

/**
 * 释放 read_text 返回的缓冲（NULL 安全，幂等）
 */
@C
foreign func cj_bridge_clipboard_free(s: CString): Unit

/**
 * 发一条系统通知（发后即忘：投递即返回，显示成败不回传）。
 * 0 = 已提交；-1 参数非法（title 空 / 超长），-3 宿主未就绪 / 平台失败，-4 本平台未实现。
 */
@C
foreign func cj_bridge_notification_notify(h: CPointer<Unit>, title: CString, body: CString): Int32
