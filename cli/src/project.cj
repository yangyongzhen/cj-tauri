/**
 * cj-tauri CLI：项目构建 / 运行 / 诊断（dev / build / run / info）
 */
package cli

import std.env.*
import std.process.*
import std.fs.*
import std.collection.*

/** CLI 版本：须与 cli/cjpm.toml 的 version、CHANGELOG 顶部版本一致（scripts/check-version.sh 校验） */
func cliVersion(): String {
    return "0.4.0"
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

/** 前端工程（Vite）：项目里有 ui/package.json 才启用；没有就整段跳过，行为与 0.3.x 一致 */
class WebUi {
    let dir: String
    let devUrl: String
    let logFile: String
    let port: UInt16

    init(dir: String) {
        this.dir = dir
        this.devUrl = "http://127.0.0.1:5173/"
        this.logFile = joinPath(dir, devLogName())
        this.port = 5173
    }
}

func detectWebUi(projectRoot: String): Option<WebUi> {
    let dir = joinPath(projectRoot, "ui")
    if (exists(joinPath(dir, "package.json"))) {
        return Some(WebUi(dir))
    }
    return None
}

/**
 * dev server 的日志文件名：必须是**相对名**。
 * launch 会给整条命令行加引号，日志路径若再自己带引号，cmd.exe 会拿到嵌套引号并直接报
 * 「文件名、目录名或卷标语法不正确」。相对名 + 工作目录 = ui/ 即可，命令保持单层引号。
 */
func devLogName(): String {
    return "dev-server.log"
}

/** 拼一条 npm 命令行；给了日志文件名就重定向过去 */
func npmLine(parts: Array<String>, logName: String): String {
    var line = "npm"
    for (p in parts) {
        line = line + " " + p
    }
    if (logName.size > 0) {
        line = line + " > " + logName + " 2>&1"
    }
    return line
}

/** 阻塞跑一条 shell 命令行：npm 在两个平台上都是脚本，必须经 shell（cmd.exe /c 或 bash -lc） */
func runShellLine(line: String, dir: String): Int64 {
    if (hostIsWindows()) {
        return execute("cmd.exe", ["/c", line], workingDirectory: Path(dir))
    }
    return execute("bash", ["-lc", line], workingDirectory: Path(dir))
}

/** 后台跑一条 shell 命令行，返回子进程（收尾时连同子进程一起收掉） */
func launchShellLine(line: String, dir: String): SubProcess {
    if (hostIsWindows()) {
        return launch("cmd.exe", ["/c", line], workingDirectory: Path(dir))
    }
    // 刻意**不**用 setsid 另开会话：dev server 必须留在 CLI 的进程组里，
    // 终端 Ctrl-C 才能一并收掉它（实测 setsid 后 Ctrl-C 只杀 CLI，dev server 漏跑）。
    // npm → sh -c vite → node(vite) → esbuild 这条父子链改由 stopDevServer 递归收掉。
    return launch("bash", ["-lc", line], workingDirectory: Path(dir))
}

/**
 * 按「先子后父」递归收掉一棵进程树（对 rootPid 自身也发信号）。
 * npm → sh -c vite → node(vite) → esbuild 是一条父子链，只 terminate 直接子进程（bash）
 * 会留下后代继续跑（实测残留 vite + esbuild），所以收尾必须递归。用 shell 递归实现，
 * 省掉在仓颉侧解析 /proc 的复杂度。
 */
func killProcessTree(rootPid: Int64, sig: String): Unit {
    let script = "t() { for c in $(pgrep -P \"$1\" 2>/dev/null); do t \"$c\"; done; kill -" +
        sig + " \"$1\" 2>/dev/null; }; t ${rootPid}"
    try {
        execute("bash", ["-lc", script])
    } catch (e: Exception) {
        () // 进程已自己退掉等情况不值得让收尾流程失败
    }
}

/** 前端依赖：没有 node_modules 就先 npm install */
func ensureUiDeps(ui: WebUi): Bool {
    if (exists(joinPath(ui.dir, "node_modules"))) {
        return true
    }
    if (runShellLine("npm -v", ui.dir) != 0) {
        eprintln("[cj-tauri] 错误: ui/package.json 存在，但找不到 npm（需要 Node.js）")
        eprintln("          装好 Node.js 再试，或删掉 ui/package.json 走内联 HTML 模式")
        return false
    }
    println("[cj-tauri] 安装前端依赖: npm install（首次会慢一些）")
    let code = runShellLine(npmLine(["install"], ""), ui.dir)
    if (code != 0) {
        eprintln("[cj-tauri] 错误: npm install 失败（exit=${code}）")
        return false
    }
    return true
}

/** 前端发布构建：Vite + singlefile → ui/dist/index.html（后端 run(html) 读的就是它） */
func buildUiBundle(ui: WebUi): Bool {
    println("[cj-tauri] 前端构建: npm run build（产物 ui/dist/index.html）")
    let code = runShellLine(npmLine(["run", "build"], ""), ui.dir)
    if (code != 0) {
        eprintln("[cj-tauri] 错误: npm run build 失败（exit=${code}）")
        return false
    }
    if (!exists(joinPath(joinPath(ui.dir, "dist"), "index.html"))) {
        eprintln("[cj-tauri] 错误: npm run build 跑完仍没有 ui/dist/index.html")
        eprintln("          检查 ui/vite.config.js 里是否装上了 vite-plugin-singlefile")
        return false
    }
    return true
}

/**
 * dev server 是否就绪：看 Vite 自己打在日志里的启动行（`Local: http://127.0.0.1:5173/`）。
 * 不用 TCP 探活是为了少一个平台差异点；探不到也不硬失败——调用方超时后会告警并继续。
 */
func devServerReady(ui: WebUi): Bool {
    if (!exists(ui.logFile)) {
        return false
    }
    let txt = readText(ui.logFile)
    return txt.contains("Local:") && txt.contains("${ui.port}")
}

/** 等 dev server 就绪：200ms 一步，最多 timeoutSec 秒 */
func waitDevServer(ui: WebUi, timeoutSec: Int64): Bool {
    var steps: Int64 = 0
    let limit = timeoutSec * 5
    while (steps < limit) {
        if (devServerReady(ui)) {
            return true
        }
        sleep(Duration.millisecond * 200)
        steps += 1
    }
    return false
}

/** 收掉 dev server 整棵进程树：Windows 用 taskkill /T；其他平台递归收掉父子链 */
func stopDevServer(p: SubProcess): Unit {
    if (hostIsWindows()) {
        let code = execute("taskkill", ["/F", "/T", "/PID", "${p.pid}"])
        if (code == 0) {
            println("[cj-tauri] dev server 已收掉（pid=${p.pid}）")
        } else {
            eprintln("[cj-tauri] 告警: 收 dev server 失败（pid=${p.pid}），可手动结束")
        }
        return
    }
    // 先 TERM 让 Vite 自己退，再 KILL 兜底；两趟都按「先子后父」收整棵树，
    // 免得只收掉直接子进程后，后代（vite / esbuild）继续占着 5173 端口。
    killProcessTree(p.pid, "TERM")
    sleep(Duration.millisecond * 500)
    killProcessTree(p.pid, "KILL")
    p.terminate() // 极端情况（pgrep 不可用）下至少收掉直接子进程
    println("[cj-tauri] dev server 已收掉（pid=${p.pid} 及后代）")
}

/** dev 模式：起前端 dev server → 注入 CJ_TAURI_DEV_URL → 启动应用 → 退出后收掉 dev server */
func runWithDevServer(c: AppContext, ui: WebUi): Int64 {
    println("[cj-tauri] 启动前端 dev server: ${ui.dir}（npm run dev，日志 ${ui.logFile}）")
    let devCmd = npmLine(["run", "dev"], devLogName())
    var dev: Option<SubProcess> = None
    try {
        dev = Some(launchShellLine(devCmd, ui.dir))
    } catch (e: Exception) {
        eprintln("[cj-tauri] 错误: 起 dev server 失败: ${e.message}")
        eprintln("          命令: ${devCmd}（工作目录 ${ui.dir}）")
        return 1
    }
    // 阈值给得宽松：本机实测 npm 把 Vite 拉起来能花到 85 秒（node/npm 冷启动偏慢），
    // 90 秒会贴着超时线走，宁可多等也不要误报「没就绪」。
    if (waitDevServer(ui, 180)) {
        println("[cj-tauri] dev server 就绪: ${ui.devUrl}")
    } else {
        eprintln("[cj-tauri] 告警: 180 秒内没在日志里看到就绪行，仍按 ${ui.devUrl} 启动")
        eprintln("          日志: ${ui.logFile}")
    }
    setVariable("CJ_TAURI_DEV_URL", ui.devUrl)
    println("[cj-tauri] 注入 CJ_TAURI_DEV_URL=${ui.devUrl}")
    let code = runProject(c)
    if (let Some(p) <- dev) {
        stopDevServer(p)
    }
    return code
}

/** 构建：桥 + cjpm build；withUi=true 时先打前端发布包（有 ui/package.json 才会触发） */
func buildProject(c: AppContext, withUi: Bool): Bool {
    if (withUi) {
        if (let Some(ui) <- detectWebUi(c.projectRoot)) {
            if (!ensureUiDeps(ui)) {
                return false
            }
            if (!buildUiBundle(ui)) {
                return false
            }
        }
    }
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
        if (buildProject(c, true)) {
            return 0
        }
        return 1
    }
    return 1
}

func cmdDev(): Int64 {
    if (let Some(c) <- loadContext()) {
        // 有 ui/package.json 才走 Node 路径：dev 模式页面来自 dev server，不必先打发布包
        var withUi = true
        if (let Some(ui) <- detectWebUi(c.projectRoot)) {
            if (!ensureUiDeps(ui)) {
                return 1
            }
            withUi = false
        }
        if (!buildProject(c, withUi)) {
            return 1
        }
        if (let Some(ui) <- detectWebUi(c.projectRoot)) {
            return runWithDevServer(c, ui)
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
