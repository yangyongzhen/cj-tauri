package cjTauri


/**
 * 日志落盘桥（RFC-003 第 5 期）：C 桥 `cj_bridge_log_*` 的声明与薄包装。
 *
 * 桌面两平台导出同名同签名（AGENTS §2 的硬约束），实现只有一份
 * （`native/core/bridge_core.c`）——落盘是把 fd 2 指到日志文件，与宿主 UI 栈无关，
 * 所以不吃宿主句柄、也不进 `WebViewHost` 接口：它是**进程级**的，不是窗口级的。
 *
 * 为什么非得在 fd 层接管：要让「没有控制台的 GUI 产物」也有凭证，就必须把 C 桥与仓颉侧
 * **两侧**的诊断收进同一份文件，只有 fd 层的接管做得到（见 core 里那段注释的取舍）。
 *
 * 鸿蒙（`arch == "aarch64"`）侧没有 C 桥产物（`native/platforms/harmonyos/` 目前只有契约），
 * 这三个 FFI 符号无处解析——若照桌面那份写下去，**模块加载期就 SIGSEGV**（实测 2026-10-18：
 * 应用进程 signal:11，AbilityStage.onCreate 一行都执行不到）。所以这里按 arch 分叉，
 * 鸿蒙侧如实降级：不落盘、`writeLogLine` 返回 false，绝不假装成功。
 */

/** 门禁口径与 `host.cj` 的 FFI 一致：桌面（x86_64）走 C 桥，鸿蒙 aarch64 走降级实现。 */
@When[arch != "aarch64"]
@C
foreign func cj_bridge_set_log_file(path: CString, maxKB: Int32, keep: Int32): Int32

/**
 * 回读生效中的日志路径；未开启时为空串。
 * 返回的是 C 侧内部静态缓冲，**不要**释放（也不要在别的线程上长期持有）。
 */
@When[arch != "aarch64"]
@C
foreign func cj_bridge_log_file(): CString

/**
 * 追加一行到日志出口（同样走轮转）：0 = 已写入，-1 = 参数非法。
 * 给 `log` 插件用——页面报错也并进同一份文件（单文件产物里它原本同样看不见）。
 */
@When[arch != "aarch64"]
@C
foreign func cj_bridge_log_write(line: CString): Int32

/** 开日志落盘，返回是否真的开了（被拒时 C 侧已出声，这里绝不假装成功） */
@When[arch != "aarch64"]
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
 * 鸿蒙侧：没有 C 桥，落盘能力位如实为 0。
 *
 * 返回 false 而不抛异常——调用方（`setLogToDefaultFile`）本就是「尽力而为」语义，
 * 抛异常会把应用启动带走。留一行 stderr 说明「哪条路没走通」。
 */
@When[arch == "aarch64"]
func enableLogFile(path: String, maxKB: Int64, keep: Int64): Bool {
    let _ = maxKB
    let _ = keep
    eprintln("[cj-tauri] log file sink unavailable on this platform (no C bridge): ${path}")
    return false
}

/** 生效中的日志路径（未开启 = 空串）。公开是给插件子包用（子包看不到父包非 public 符号） */
@When[arch != "aarch64"]
public func currentLogFilePath(): String {
    let cs = unsafe { cj_bridge_log_file() }
    if (cs.isNull()) {
        return ""
    }
    return cs.toString()
}

/** 鸿蒙侧没有落盘出口：恒为空串（与「未开启」同口径，调用方无需分支） */
@When[arch == "aarch64"]
public func currentLogFilePath(): String {
    return ""
}

/** 往日志出口追加一行（log 插件用）。公开理由同上 */
@When[arch != "aarch64"]
public func writeLogLine(line: String): Bool {
    var rc: Int32 = -1
    unsafe {
        rc = cj_bridge_log_write(LibC.mallocCString(line))
    }
    return rc == 0
}

/** 鸿蒙侧：没有出口可写，返回 false（调用方据返回值如实回报，不冒充已写入） */
@When[arch == "aarch64"]
public func writeLogLine(line: String): Bool {
    let _ = line
    return false
}
