package cjTauri

import std.collection.*

/**
 * 日志出口桥（RFC-003 第 5 期 + 2026-11-12 鸿蒙 hilog 收口）。
 *
 * 桌面两平台：C 桥 `cj_bridge_log_*`，导出同名同签名（AGENTS §2 的硬约束），实现只有一份
 * （`native/core/bridge_core.c`）——落盘是把 fd 2 指到日志文件，与宿主 UI 栈无关，
 * 所以不吃宿主句柄、也不进 `WebViewHost` 接口：它是**进程级**的，不是窗口级的。
 *
 * 为什么非得在 fd 层接管：要让「没有控制台的 GUI 产物」也有凭证，就必须把 C 桥与仓颉侧
 * **两侧**的诊断收进同一份文件，只有 fd 层的接管做得到（见 core 里那段注释的取舍）。
 *
 * 鸿蒙（`env == "ohos"`）侧没有 C 桥产物（`native/platforms/harmonyos/` 目前只有契约），
 * 那三个 FFI 符号无处解析——若照桌面那份写下去，**模块加载期就 SIGSEGV**（实测 2026-10-18：
 * 应用进程 signal:11，AbilityStage.onCreate 一行都执行不到）。但「没有落盘出口」不等于
 * 「没有日志出口」：设备上的日志出口是 hilog（`OH_LOG_Print`，`libhilog_ndk.z.so`）。
 *
 * 于是这里按平台分叉成两条出口，上层只认一个函数：
 * - 桌面：诊断走 stderr（`logd`），要留文件由 `enableLogFile` 接管 fd 2；
 * - 鸿蒙：诊断走 hilog（tag = `cj-tauri`），没有文件出口，`enableLogFile` 如实回 false。
 *
 * 判据用 `env` 而不是 `arch`（2026-10-19 校正）：`arch == "aarch64"` 连桌面 aarch64 Linux
 * 一起门禁掉了，那个平台**是有 C 桥的**，会白白失去日志落盘能力。
 */

/** 门禁口径与 `host.cj` 的 FFI 一致：桌面走 C 桥，鸿蒙走 hilog / 降级实现。 */
@When[env != "ohos"]
@C
foreign func cj_bridge_set_log_file(path: CString, maxKB: Int32, keep: Int32): Int32

/**
 * 回读生效中的日志路径；未开启时为空串。
 * 返回的是 C 侧内部静态缓冲，**不要**释放（也不要在别的线程上长期持有）。
 */
@When[env != "ohos"]
@C
foreign func cj_bridge_log_file(): CString

/**
 * 追加一行到日志出口（同样走轮转）：0 = 已写入，-1 = 参数非法。
 * 给 `log` 插件用——页面报错也并进同一份文件（单文件产物里它原本同样看不见）。
 */
@When[env != "ohos"]
@C
foreign func cj_bridge_log_write(line: CString): Int32

// ==========================================================================
// 鸿蒙侧：hilog 原生 C API（NDK，`libhilog_ndk.z.so`）
//
// 为什么不用 SDK 的 `ohos.hilog` 包：框架包对 ohos 模块的依赖要额外落链接开关，
// 而 hilog 的 NDK C 符号（`OH_LOG_Print`）是稳定接口、与 `libpasteboard` / `libudmf`
// 同一个套路（`src/clipboard_bridge.cj` 已真机验证），链接库名固定为 `hilog_ndk.z`。
// **链接开关写在入口模块**（`cli/src/manifest.cj` 的 `renderOhosEntryToml`）——最终链接发生在
// `output-type = dynamic` 的 entry，框架自己的 cjpm.toml 写了不生效，缺了就是模块加载期崩。
// ==========================================================================

/** hilog 的日志域（`OH_LOG_Print` 的 domain）与 tag；取证按 tag 过滤：`hdc shell hilog | grep cj-tauri` */
const HILOG_DOMAIN: Int32 = 0
const HILOG_TAG: String = "cj-tauri"

/** LogType：应用日志是 LOG_APP = 0 */
const HILOG_TYPE_APP: Int32 = 0
/** LogLevel：DEBUG = 3 / INFO = 4 / WARN = 5 / ERROR = 6 / FATAL = 7 */
const HILOG_INFO: Int32 = 4

/**
 * 单条 hilog 的字节预算：hilog 对单条日志有长度上限（1024 字节），留出 tag 与域的余量取 1000。
 * 超长行按 UTF-8 字符边界切片、分多条打印，**不截断**——取证要对得上每一条明细。
 */
const HILOG_MAX_BYTES: Int64 = 1000

/**
 * `int OH_LOG_Print(LogType type, LogLevel level, unsigned int domain, const char *tag,
 *                   const char *fmt, ...)`
 *
 * 变长参数是硬需求：hilog 的 `%s` 不带隐私修饰符会打成 `<private>`，正文必须经
 * `%{public}s` + 一个实参送进去。若把正文直接当 fmt 传（不传实参），正文里一个 `%`
 * 就会让 hilog 去消费不存在的参数——所以 fmt 恒为字面量，正文只做实参。
 */
@When[env == "ohos"]
@C
foreign func OH_LOG_Print(logType: Int32, level: Int32, domain: Int32, tag: CString, fmt: CString, ...): Int32

/**
 * 按字节预算把一行切成若干片，UTF-8 边界安全（不切在半个汉字中间）。
 *
 * 平台无关、无 FFI 依赖，public 是为了让单测与探针能直接验它——鸿蒙分支在本机编不了
 * （SDK 只有 linux / windows 两个目标），能本地验证的部分就别留在未验证里。
 */
public func hilogSplit(line: String, maxBytes: Int64): ArrayList<String> {
    let out = ArrayList<String>()
    // 预算下限 4 字节 = 一个 UTF-8 字符的最大长度，保证下面「回退到边界」一定落得下来
    let limit = if (maxBytes < 4) {
        4
    } else {
        maxBytes
    }
    let total = line.size
    if (total <= limit) {
        out.add(line)
        return out
    }
    let bytes = line.toArray()
    var start: Int64 = 0
    while (start < total) {
        var end = start + limit
        if (end > total) {
            end = total
        }
        if (end < total) {
            // 0b10xxxxxx 是 UTF-8 续字节：落在续字节上就往回退到字符起点
            while (end > start && (bytes[end] & 0xC0u8) == 0x80u8) {
                end = end - 1
            }
            if (end == start) {
                // 兜底（limit >= 4 时到不了这里）：与其硬切出非法 UTF-8，不如把余下整段一次交出
                end = total
            }
        }
        out.add(String.fromUtf8(bytes[start..end]))
        start = end
    }
    return out
}

/** 把一行打到 hilog（超预算分条）。返回是否全部送出（非 0 说明 hilog 侧拒了） */
@When[env == "ohos"]
func hilogPrint(level: Int32, text: String): Bool {
    var ok = true
    for (chunk in hilogSplit(text, HILOG_MAX_BYTES)) {
        unsafe {
            let tag = LibC.mallocCString(HILOG_TAG)
            let fmt = LibC.mallocCString("%{public}s")
            let msg = LibC.mallocCString(chunk)
            let rc = OH_LOG_Print(HILOG_TYPE_APP, level, HILOG_DOMAIN, tag, fmt, msg)
            // hilog 只拷贝内容，不接管入参所有权——每行都释放，长驻进程不能靠泄漏换省事
            LibC.free(tag)
            LibC.free(fmt)
            LibC.free(msg)
            if (rc < 0) {
                ok = false
            }
        }
    }
    return ok
}

/**
 * 框架统一的诊断出口：桌面写 stderr（可能已被 `enableLogFile` 接管到日志文件），鸿蒙写 hilog。
 *
 * 名字取 `logd`（log diagnostic）是因为调用点有两百来处，长名字把每行诊断都推过折行线；
 * 语义不变：一行一条、不加前缀、不加时间戳——前缀由调用方自己带（`[cj-tauri] …`）。
 *
 * 框架内新代码一律调它，**别再直接 `eprintln`**——鸿蒙上 `eprintln` 的 stderr 一行都不进
 * hilog，设备侧等于没有日志（AGENTS §4 实测：白屏排查时 hilog 里连 AbilityStage.onCreate
 * 都看不见，而 CANGJIE-RUNTIME 的行照常打）。
 */
@When[env != "ohos"]
public func logd(line: String): Unit {
    eprintln(line)
}

/** 鸿蒙侧：同上，出口换成 hilog（tag = cj-tauri，等级 INFO） */
@When[env == "ohos"]
public func logd(line: String): Unit {
    let _ = hilogPrint(HILOG_INFO, line)
}

/** 开日志落盘，返回是否真的开了（被拒时 C 侧已出声，这里绝不假装成功） */
@When[env != "ohos"]
func enableLogFile(path: String, maxKB: Int64, keep: Int64): Bool {
    var kb = maxKB
    var kp = keep
    if (kb > 1048576) {
        kb = 1048576 // 1 GiB 上限：Int64 → Int32 的转换不该被一个手滑的环境变量带崩
    }
    if (kp > 1000) {
        kp = 1000
    }
    var rc: Int32 = 0
    unsafe {
        rc = cj_bridge_set_log_file(LibC.mallocCString(path), Int32(kb), Int32(kp))
    }
    return rc == 1
}

/**
 * 鸿蒙侧：没有 C 桥，落盘能力位如实为 0——但日志出口仍在（hilog），
 * 所以这行提示要经 `logd` 发出去，否则「为什么没有日志文件」这件事本身也没凭证。
 *
 * 返回 false 而不抛异常——调用方（`setLogToDefaultFile`）本就是「尽力而为」语义，
 * 抛异常会把应用启动带走。
 */
@When[env == "ohos"]
func enableLogFile(path: String, maxKB: Int64, keep: Int64): Bool {
    let _ = maxKB
    let _ = keep
    logd("[cj-tauri] log file sink unavailable on this platform (no C bridge); " +
        "diagnostics go to hilog (tag=${HILOG_TAG}): ${path}")
    return false
}

/** 生效中的日志路径（未开启 = 空串）。公开是给插件子包用（子包看不到父包非 public 符号） */
@When[env != "ohos"]
public func currentLogFilePath(): String {
    let cs = unsafe { cj_bridge_log_file() }
    if (cs.isNull()) {
        return ""
    }
    return cs.toString()
}

/** 鸿蒙侧没有落盘文件：恒为空串（与「未开启」同口径，调用方无需分支） */
@When[env == "ohos"]
public func currentLogFilePath(): String {
    return ""
}

/** 往日志出口追加一行（log 插件用）。公开理由同上 */
@When[env != "ohos"]
public func writeLogLine(line: String): Bool {
    var rc: Int32 = -1
    unsafe {
        rc = cj_bridge_log_write(LibC.mallocCString(line))
    }
    return rc == 0
}

/** 鸿蒙侧：出口是 hilog，返回是否真的送出去了（调用方据返回值如实回报，不冒充已写入） */
@When[env == "ohos"]
public func writeLogLine(line: String): Bool {
    return hilogPrint(HILOG_INFO, line)
}
