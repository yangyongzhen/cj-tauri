package cjTauri

/**
 * 后台（静默）子进程：起一个**控制台程序**，但不要那个控制台窗口。
 *
 * 为什么需要它：cj-tauri 的应用产物是 GUI 子系统（Windows 的 `--subsystem=windows`），父进程
 * 没有控制台；此时用 `std.process.launch` 拉起一个**控制台子系统**的程序（cjh、ffmpeg 这类 CLI），
 * Windows 会给子进程单独配一个控制台窗口——用户看到的就是「点了一下，旁边蹦出一个黑窗口」。
 * `std.process.launch` 的签名里没有可以传创建标志的地方，所以这条下沉到 C 桥
 * （平台差异只允许出现在 `@When` 与 `bridge_*.c`，AGENTS §2）：
 * Windows = `CreateProcessW` + `DETACHED_PROCESS`（子进程**根本没有** console：`CREATE_NO_WINDOW`
 * 只是不显示窗口，它仍持有一个隐藏 console、conhost 照挂；三个标准句柄显式指到 NUL，否则子进程一
 * println 就可能死在自己的控制台上），Linux = `posix_spawn` + 自成会话（终端 Ctrl-C 不连带打死）。
 *
 * 与 `std.process.launch` 的取舍：这条**拿不到子进程的 stdout / stderr**（Windows 指向 NUL、
 * Linux 指向 /dev/null）。要读它的输出就别用这个——那需要管道，是另一件事。
 *
 * 句柄口径：只留 pid（Windows 的进程句柄当场关掉，不占句柄表；Linux 的子进程是分离的，
 * 父进程退出后它照样活着）。要让它结束就 `stop()`，要判它还在不在就 `isAlive()`。
 */
public class BackgroundProcess {
    private let pid: Int64

    init(pid: Int64) {
        this.pid = pid
    }

    /** 进程号（恒 > 0：拿到它的路径只有 `launchHidden` 成功那一条） */
    public func processId(): Int64 {
        return pid
    }

    /** 还在跑吗（查不到即按「不在」上报——调用方据此决定要不要重新拉起） */
    public func isAlive(): Bool {
        return hiddenPidAlive(pid)
    }

    /**
     * 让它结束：先按正常终止（Windows = TerminateProcess；Linux = SIGTERM，3 秒不走再 SIGKILL）。
     * 幂等——进程已经不在了也算成功。
     */
    public func stop(): Unit {
        if (!hiddenPidKill(pid)) {
            eprintln("[cj-tauri] 终止子进程失败（pid=${pid}）")
        }
    }
}

/**
 * 静默启动一个后台进程：`exePath` 是程序路径，`args` 是参数表（**不要自己加引号**，
 * 空格 / 引号由平台按各自规则转义）。
 *
 * 返回 `None` 的三种情况：路径为空、参数里混进了内部分隔符（0x1F）、平台起不来进程
 * （原因已由 C 桥打进 stderr）。**绝不在没起进程时返回一个 pid**。
 *
 * 典型用法（应用侧 AI 后端：随包的 cjh）：
 *
 * ```cangjie
 * match (launchHidden(bin, ["web", "--port", "8765"])) {
 *     case Some(p) => backendPid = p.processId()
 *     case None => eprintln("[app] 后端没起来")
 * }
 * ```
 */
public func launchHidden(exePath: String, args: Array<String>): Option<BackgroundProcess> {
    if (exePath.isEmpty()) {
        eprintln("[cj-tauri] launchHidden: 程序路径为空")
        return None
    }
    let wire = match (joinHiddenArgs(args)) {
        case Some(w) => w
        case None => return None
    }
    let pid = spawnHiddenPid(exePath, wire)
    if (pid <= 0) {
        return None
    }
    return Some(BackgroundProcess(pid))
}

/**
 * 把参数表拼成 C 桥认的「线格式」：按 0x1F（单元分隔符）连接，由平台侧再切成 argv。
 *
 * 这个字节不会出现在正常参数里，所以一旦出现就**当场拒绝**（`None`）——默默拼错比拒绝更糟：
 * 参数被劈成两个、而调用方拿到的是「启动成功」。
 *
 * 抽成纯函数是为了单测：真正难的不是拼接，是「拼出来还能不能原样切开」这条不变量
 * （`src/tests/process_hidden_test.cj`）。
 */
public func joinHiddenArgs(args: Array<String>): Option<String> {
    let sep = "\u{1F}"
    var wire = ""
    var first = true
    for (a in args) {
        if (let Some(_) <- a.indexOf(sep)) {
            eprintln("[cj-tauri] launchHidden: 参数里不允许出现 0x1F 分隔符（${a}）")
            return None
        }
        if (!first) {
            wire += sep
        }
        wire += a
        first = false
    }
    return Some(wire)
}

/**
 * 静默启动的 C 桥出口：成功回 pid（> 0），失败回 0（平台已把原因写进 stderr）。
 *
 * 鸿蒙侧没有 C 桥产物（`native/platforms/harmonyos/` 目前只有契约），照桌面那份写会让模块
 * 加载期就 SIGSEGV（与 `log_bridge.cj` 同一条坑，AGENTS §4）——所以按 `env` 分叉，如实降级。
 * 判据用 `env` 而不是 `arch`：桌面 aarch64 Linux 也有 C 桥。
 */
@When[env != "ohos"]
@C
foreign func cj_bridge_spawn_hidden(exe: CString, args: CString): Int64

/** 终止 pid（幂等）；鸿蒙侧无桥，不用声明。 */
@When[env != "ohos"]
@C
foreign func cj_bridge_kill_pid(pid: Int64): Int32

/** 探活（1 = 活着）；鸿蒙侧无桥，不用声明。 */
@When[env != "ohos"]
@C
foreign func cj_bridge_pid_alive(pid: Int64): Int32

@When[env != "ohos"]
func spawnHiddenPid(exePath: String, argsWire: String): Int64 {
    var pid: Int64 = 0
    unsafe {
        pid = cj_bridge_spawn_hidden(LibC.mallocCString(exePath), LibC.mallocCString(argsWire))
    }
    return pid
}

/** 鸿蒙侧：没有桥就没有后台静默启动，如实报 0 并说清代价（用 std.process.launch 会带出控制台） */
@When[env == "ohos"]
func spawnHiddenPid(exePath: String, argsWire: String): Int64 {
    let _ = argsWire
    eprintln("[cj-tauri] 本平台没有 C 桥，无法后台静默启动：${exePath}")
    return 0
}

@When[env != "ohos"]
func hiddenPidAlive(pid: Int64): Bool {
    var alive: Int32 = 0
    unsafe {
        alive = cj_bridge_pid_alive(pid)
    }
    return alive == 1
}

@When[env == "ohos"]
func hiddenPidAlive(pid: Int64): Bool {
    let _ = pid
    return false
}

@When[env != "ohos"]
func hiddenPidKill(pid: Int64): Bool {
    var rc: Int32 = 0
    unsafe {
        rc = cj_bridge_kill_pid(pid)
    }
    return rc == 1
}

@When[env == "ohos"]
func hiddenPidKill(pid: Int64): Bool {
    let _ = pid
    return false
}
