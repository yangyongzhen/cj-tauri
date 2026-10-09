package cjTauri

/**
 * 串口桥（plugin_serial 的 FFI 面）：C 桥 `cj_bridge_serial_*` 的声明与薄包装。
 *
 * 为什么这里**不带 @When**：两平台的导出同名同签名（AGENTS §2 的硬约束），平台差异全在
 * `native/bridge_*.c` 里——Linux 是 termios，Windows 侧接口已留、实现待补（返回可读的
 * 「暂不支持」，不是静默失败）。所以仓颉侧一份声明就能同时编两个平台，上层不需要平台分支。
 *
 * 参数约定（与 native/bridge_core.h 逐字一致）：parity 0=无 1=奇 2=偶，stopBits 1|2，
 * dataBits 5..8。**路径白名单与参数校验都在 C 侧 core**——页面可控的字符串绝不能只在仓颉侧挡。
 *
 * 这组导出**不收宿主句柄**：串口不是宿主能力，不必先建窗口才能用（无头进程里照样能开）。
 */
@C
foreign func cj_bridge_serial_open(path: CString, baud: Int32, dataBits: Int32, parity: Int32,
                                   stopBits: Int32): Int64

/**
 * 读：最多 len 字节、最多等 timeoutMs 毫秒（0 = 立即返回）。返回实际字节数（0 = 超时无数据）
 */
@C
foreign func cj_bridge_serial_read(h: Int64, buf: CPointer<UInt8>, len: Int32, timeoutMs: Int32): Int32

/**
 * 写：在 timeoutMs 预算内尽量写完；返回实际写入字节数（可能小于 len）
 */
@C
foreign func cj_bridge_serial_write(h: Int64, buf: CPointer<UInt8>, len: Int32,
                                    timeoutMs: Int32): Int32

/**
 * 关闭并释放句柄（幂等：重复关同一句柄返回 -4）
 */
@C
foreign func cj_bridge_serial_close(h: Int64): Int32

/**
 * 最近一次失败的明细（UTF-8，C 侧**线程局部**：命令各自跑在 worker 线程上，
 * 静态单槽会被并发调用互相覆盖）
 */
@C
foreign func cj_bridge_serial_last_error(): CString

/**
 * 打开串口：成功返回 >0 句柄，失败返回负码（-1 参数/白名单、-2 句柄表满、-3 平台打不开）。
 * 失败明细用 serialLastError() 取（C 侧线程局部，同一线程内取才有意义）。
 */
public func serialOpen(path: String, baud: Int32, dataBits: Int32, parity: Int32,
                       stopBits: Int32): Int64 {
    var h: Int64 = -1
    unsafe {
        let cpath = LibC.mallocCString(path)
        h = cj_bridge_serial_open(cpath, baud, dataBits, parity, stopBits)
        // C 侧（core）当场把路径拷进自己的句柄槽，不持有我们的指针——这里立刻归还，
        // 免得每次打开漏一小块（跨 FFI 的内存一律「谁分配谁释放」）
        LibC.free(cpath)
    }
    return h
}

/**
 * C 侧最近一次失败的明细；取不到时返回空串（调用方自行降级成数字码）
 */
public func serialLastError(): String {
    unsafe {
        return cj_bridge_serial_last_error().toString()
    }
}

/**
 * 读：最多 maxBytes 字节。返回实际读到的字节（空数组 = 超时无数据）。
 * 缓冲在这里现分配现释放——每次读的用量都很小，不值得为它引一层对象池。
 */
public func serialRead(h: Int64, maxBytes: Int32, timeoutMs: Int32): Array<UInt8> {
    let cap = Int64(maxBytes)
    let buf = LibC.malloc<UInt8>(count: cap)
    var n: Int32 = 0
    unsafe {
        n = cj_bridge_serial_read(h, buf, maxBytes, timeoutMs)
    }
    var out = Array<UInt8>(0, repeat: 0)
    if (n > 0) {
        out = Array<UInt8>(Int64(n), repeat: 0)
        unsafe {
            for (i in 0..Int64(n)) {
                out[i] = buf.read(i)
            }
        }
    }
    unsafe {
        LibC.free(buf)
    }
    return out
}

/**
 * 写：在 timeoutMs 预算内尽量写完，返回实际写入字节数（可能 < data.size；0 = 一个字节都没出去）
 */
public func serialWrite(h: Int64, data: Array<UInt8>, timeoutMs: Int32): Int32 {
    if (data.size == 0) {
        return 0
    }
    let n = data.size
    let buf = LibC.malloc<UInt8>(count: n)
    unsafe {
        for (i in 0..n) {
            buf.write(i, data[i])
        }
    }
    var w: Int32 = 0
    unsafe {
        w = cj_bridge_serial_write(h, buf, Int32(n), timeoutMs)
    }
    unsafe {
        LibC.free(buf)
    }
    return w
}

/**
 * 关句柄：0 = 成功，负码 = 失败（重复关返回 -4）
 */
public func serialClose(h: Int64): Int32 {
    var rc: Int32 = 0
    unsafe {
        rc = cj_bridge_serial_close(h)
    }
    return rc
}
