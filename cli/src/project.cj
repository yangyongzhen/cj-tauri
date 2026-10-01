/**
 * cj-tauri CLI：项目构建 / 运行 / 诊断（dev / build / run / info）
 */
package cli

import std.env.*
import std.process.*
import std.fs.*
import std.collection.*

func cliVersion(): String {
    return "0.1.0"
}

/** 一次命令所需的路径上下文 */
public class AppContext {
    let projectRoot: String
    let frameworkRoot: String
    let stdx: String
    let cjpm: String

    public init(projectRoot: String, frameworkRoot: String, stdx: String, cjpm: String) {
        this.projectRoot = projectRoot
        this.frameworkRoot = frameworkRoot
        this.stdx = stdx
        this.cjpm = cjpm
    }
}

/** 项目根目录：从当前目录向上找含 cjpm.toml 的目录 */
func findProjectRoot(): Option<String> {
    var cur: Option<String> = Some(currentDir())
    var guard = 0
    while (guard < 64) {
        guard++
        if (let Some(d) <- cur) {
            if (exists(joinPath(d, "cjpm.toml"))) {
                return Some(d)
            }
            cur = parentDir(d)
        } else {
            return None
        }
    }
    return None
}

/** 可执行产物：优先 target/release/bin/main[.exe] */
func findAppBinary(projectRoot: String): Option<String> {
    let binDir = joinPath(joinPath(joinPath(projectRoot, "target"), "release"), "bin")
    if (!exists(binDir)) {
        return None
    }
    let preferred = "main" + exeSuffix()
    var fallback = ""
    for (info in listDir(binDir)) {
        if (info.isDirectory()) {
            continue
        }
        let nm = baseName(info.path.toString())
        if (nm.endsWith(".cjo") || nm.endsWith(".o") || nm.endsWith(".d") || nm.endsWith(".bc")) {
            continue
        }
        if (hostIsWindows() && !nm.endsWith(".exe")) {
            continue
        }
        if (nm == preferred) {
            return Some(joinPath(binDir, nm))
        }
        fallback = joinPath(binDir, nm)
    }
    if (fallback.size > 0) {
        return Some(fallback)
    }
    return None
}

/** 把若干目录前置到某个路径型环境变量（PATH / LD_LIBRARY_PATH） */
func prependPath(key: String, dirs: ArrayList<String>): Unit {
    let sep = pathListSep()
    var head = ""
    for (d in dirs) {
        if (d.size == 0) {
            continue
        }
        head = head + d + sep
    }
    setVariable(key, head + envOr(key, ""))
}

/**
 * 准备子进程运行环境：
 * 动态库搜索路径需要「框架 native（含同步的 WebView2 loader）+ stdx + 仓颉运行时」，
 * PATH 还需要「桥、cjpm、cjc」（Windows 下 DLL 也走 PATH）。
 */
func prepareEnv(fwRoot: String, stdx: String): Unit {
    let libDirs = ArrayList<String>()
    libDirs.add(joinPath(fwRoot, "native"))
    libDirs.add(joinPath(joinPath(fwRoot, "native"), "webview2"))
    if (stdx.size > 0) {
        libDirs.add(stdx)
    }
    let pathDirs = ArrayList<String>()
    for (d in libDirs) {
        pathDirs.add(d)
    }
    if (let Some(home) <- resolveCangjieHome()) {
        if (let Some(rt) <- findRuntimeLibDir(home)) {
            libDirs.add(rt)
            pathDirs.add(rt)
        }
        pathDirs.add(joinPath(joinPath(home, "tools"), "bin")) // cjpm
        pathDirs.add(joinPath(joinPath(home, "tools"), "lib")) // cjpm 依赖
        pathDirs.add(joinPath(home, "bin"))                     // cjc
    }
    prependPath("PATH", pathDirs)
    if (!hostIsWindows()) {
        prependPath("LD_LIBRARY_PATH", libDirs)
    }
}

/** 确保 C 桥已构建（缺失时调用平台构建脚本） */
func ensureBridge(fwRoot: String): Bool {
    let nativeDir = joinPath(fwRoot, "native")
    let lib = joinPath(nativeDir, bridgeLibName())
    if (exists(lib)) {
        return true
    }
    println("[cj-tauri] C 桥未构建，正在构建: ${lib}")
    if (hostIsWindows()) {
        let script = joinPath(nativeDir, "build_win.bat")
        if (!exists(script)) {
            eprintln("[cj-tauri] 错误: 缺少 ${script}")
            return false
        }
        let code = execute("cmd.exe", ["/c", "\"" + script + "\""], workingDirectory: Path(nativeDir))
        if (code != 0) {
            eprintln("[cj-tauri] 错误: C 桥构建失败（exit=${code}）")
            return false
        }
        if (exists(lib)) {
            return true
        }
        eprintln("[cj-tauri] 错误: 构建脚本执行完仍未生成 ${lib}")
        return false
    }
    let script = joinPath(nativeDir, "build_linux.sh")
    if (!exists(script)) {
        eprintln("[cj-tauri] 错误: 缺少 ${script}")
        return false
    }
    let code = execute("bash", [script], workingDirectory: Path(nativeDir))
    if (code != 0) {
        eprintln("[cj-tauri] 错误: C 桥构建失败（exit=${code}）")
        return false
    }
    if (exists(lib)) {
        return true
    }
    eprintln("[cj-tauri] 错误: 构建脚本执行完仍未生成 ${lib}")
    return false
}

/** 解析项目上下文（项目根 / 框架根 / stdx / cjpm） */
func loadContext(): Option<AppContext> {
    var proj = ""
    if (let Some(p) <- findProjectRoot()) {
        proj = p
    } else {
        eprintln("[cj-tauri] 错误: 当前目录不在 cj-tauri 项目内（未找到 cjpm.toml）")
        return None
    }
    var fw = ""
    if (let Some(f) <- frameworkFromProject(proj)) {
        fw = f
    } else if (let Some(f) <- resolveFrameworkRoot()) {
        fw = f
    } else {
        eprintln("[cj-tauri] 错误: 无法确定 cj-tauri 框架目录")
        eprintln("          cjpm.toml 里的 cjTauri 依赖路径不可用，且未设置 CJ_TAURI_ROOT")
        return None
    }
    if (!exists(fw)) {
        eprintln("[cj-tauri] 错误: 框架目录不存在: ${fw}")
        eprintln("          请修改 cjpm.toml 的 cjTauri 依赖路径，或设置 CJ_TAURI_ROOT")
        return None
    }
    var stdx = ""
    if (let Some(s) <- resolveStdx(fw, Some(proj))) {
        stdx = s
    } else {
        eprintln("[cj-tauri] 告警: 未找到 stdx 目录，构建可能失败（可用 CANGJIE_STDX 指定）")
    }
    var cjpm = ""
    if (let Some(c) <- resolveCjpm()) {
        cjpm = c
    } else {
        eprintln("[cj-tauri] 错误: 找不到 cjpm")
        eprintln("          请把仓颉 SDK 的 tools/bin 与 bin 加入 PATH，或设置 CANGJIE_HOME")
        return None
    }
    return Some(AppContext(proj, fw, stdx, cjpm))
}

/** 构建：桥 + cjpm build */
func buildProject(c: AppContext): Bool {
    prepareEnv(c.frameworkRoot, c.stdx)
    if (!ensureBridge(c.frameworkRoot)) {
        return false
    }
    println("[cj-tauri] cjpm build ...")
    let code = execute(c.cjpm, ["build"], workingDirectory: Path(c.projectRoot))
    if (code != 0) {
        eprintln("[cj-tauri] 构建失败（exit=${code}）")
        return false
    }
    if (let Some(bin) <- findAppBinary(c.projectRoot)) {
        println("[cj-tauri] 构建完成: ${bin}")
    } else {
        println("[cj-tauri] 构建完成（未在 target/release/bin 找到可执行产物）")
    }
    return true
}

/** 运行已构建产物（App 以项目根为工作目录，页面/能力清单按相对路径读取） */
func runProject(c: AppContext): Int64 {
    var bin = ""
    if (let Some(b) <- findAppBinary(c.projectRoot)) {
        bin = b
    } else {
        eprintln("[cj-tauri] 错误: 未找到可执行产物，请先 cj-tauri build")
        return 1
    }
    prepareEnv(c.frameworkRoot, c.stdx)
    if (!hostIsWindows()) {
        if (getVariable("DISPLAY").isNone()) {
            eprintln("[cj-tauri] 告警: 未设置 DISPLAY，需要可用的 X 显示环境（或 Wayland+XWayland）")
        }
    }
    println("[cj-tauri] 启动: ${bin}")
    let code = execute(bin, Array<String>(), workingDirectory: Path(c.projectRoot))
    println("[cj-tauri] 应用退出（exit=${code}）")
    return code
}

func cmdBuild(): Int64 {
    if (let Some(c) <- loadContext()) {
        if (buildProject(c)) {
            return 0
        }
        return 1
    }
    return 1
}

func cmdDev(): Int64 {
    if (let Some(c) <- loadContext()) {
        if (!buildProject(c)) {
            return 1
        }
        return runProject(c)
    }
    return 1
}

func cmdRun(): Int64 {
    if (let Some(c) <- loadContext()) {
        return runProject(c)
    }
    return 1
}

/** 环境自检：把解析结果打出来，排障用 */
func cmdInfo(): Int64 {
    println("cj-tauri CLI ${cliVersion()}")
    println("")
    println("  宿主平台    : ${hostOsName()} (${hostTriple()})")
    println("  工作目录    : ${currentDir()}")
    if (let Some(exe) <- currentExePath()) {
        println("  CLI 可执行  : ${exe}")
    }
    if (let Some(fw) <- resolveFrameworkRoot()) {
        println("  框架根目录  : ${fw}")
        let lib = joinPath(joinPath(fw, "native"), bridgeLibName())
        if (exists(lib)) {
            println("  C 桥        : ${lib} [已构建]")
        } else {
            println("  C 桥        : ${lib} [未构建，cj-tauri dev/build 会自动构建]")
        }
    } else {
        println("  框架根目录  : 未找到（请设置 CJ_TAURI_ROOT）")
    }
    if (let Some(proj) <- findProjectRoot()) {
        println("  项目根目录  : ${proj}")
        if (let Some(bin) <- findAppBinary(proj)) {
            println("  可执行产物  : ${bin}")
        } else {
            println("  可执行产物  : 未构建（cj-tauri build）")
        }
    } else {
        println("  项目根目录  : （当前不在 cj-tauri 项目内）")
    }
    if (let Some(fw) <- resolveFrameworkRoot()) {
        if (let Some(s) <- resolveStdx(fw, findProjectRoot())) {
            println("  stdx        : ${s}")
        } else {
            println("  stdx        : 未找到（请设置 CANGJIE_STDX）")
        }
    }
    if (let Some(home) <- resolveCangjieHome()) {
        println("  CANGJIE_HOME: ${home}")
        if (let Some(rt) <- findRuntimeLibDir(home)) {
            println("  仓颉运行时  : ${rt}")
        }
    } else {
        println("  CANGJIE_HOME: 未找到（请设置 CANGJIE_HOME 或把 cjc 加入 PATH）")
    }
    if (let Some(cjpm) <- resolveCjpm()) {
        println("  cjpm        : ${cjpm}")
    } else {
        println("  cjpm        : 未找到")
    }
    if (hostIsWindows()) {
        println("")
        println("  提示: Windows 需要 WebView2 Runtime（Win11 自带），且构建桥用的 WebView2 SDK")
        println("        版本不得高于本机 Runtime 版本；详见框架 native/build_win.bat 头部注释。")
    }
    return 0
}
