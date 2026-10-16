package cjTauri


/**
 * 日志落盘桥（RFC-003 第 5 期）：C 桥 `cj_bridge_log_*` 的声明与薄包装。
 *
 * 这里**不带 @When**：两平台导出同名同签名（AGENTS §2 的硬约束），实现只有一份
 * （`native/core/bridge_core.c`）——落盘是把 fd 2 指到日志文件，与宿主 UI 栈无关，
 * 所以不吃宿主句柄、也不进 `WebViewHost` 接口：它是**进程级**的，不是窗口级的。
 *
 * 为什么非得在 fd 层接管：要让「没有控制台的 GUI 产物」也有凭证，就必须把 C 桥与仓颉侧
 * **两侧**的诊断收进同一份文件，只有 fd 层的接管做得到（见 core 里那段注释的取舍）。
 */

/**
 * 开启日志落盘：1 = 开了；0 = 被拒（空路径 / 超长 / 打不开，原因由 C 侧打在**还在的** stderr 上）。
 *
 * maxKB ≤ 0 = 不轮转（交给外部 logrotate）；keep = 保留几份档案（log.1 … log.keep），
 * ≤ 0 = 轮转时直接丢弃旧内容。父目录不存在时 C 侧会先按需建出来。
 */
@C
foreign func cj_bridge_set_log_file(path: CString, maxKB: Int32, keep: Int32): Int32

/**
 * 回读生效中的日志路径；未开启时为空串。
 * 返回的是 C 侧内部静态缓冲，**不要**释放（也不要在别的线程上长期持有）。
 */
@C
foreign func cj_bridge_log_file(): CString

/**
 * 追加一行到日志出口（同样走轮转）：0 = 已写入，-1 = 参数非法。
 * 给 `log` 插件用——页面报错也并进同一份文件（单文件产物里它原本同样看不见）。
 */
@C
foreign func cj_bridge_log_write(line: CString): Int32

/** 开日志落盘，返回是否真的开了（被拒时 C 侧已出声，这里绝不假装成功） */
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

/** 生效中的日志路径（未开启 = 空串）。公开是给插件子包用（子包看不到父包非 public 符号） */
public func currentLogFilePath(): String {
    let cs = unsafe { cj_bridge_log_file() }
    if (cs.isNull()) {
        return ""
    }
    return cs.toString()
}

/** 往日志出口追加一行（log 插件用）。公开理由同上 */
public func writeLogLine(line: String): Bool {
    var rc: Int32 = -1
    unsafe {
        rc = cj_bridge_log_write(LibC.mallocCString(line))
    }
    return rc == 0
}
