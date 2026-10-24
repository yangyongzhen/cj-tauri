/**
 * cj-tauri CLI：环境自检（doctor）
 *
 * 为什么要有它：`info` 打印的是「解析结果」（路径是什么），能用但看不出「这条到底算不算过」——
 * 每条都只是一行文本，人得自己对照 skill 里的判据。doctor 反过来：**每条检查自带结论**，
 * 失败的给出下一步该干什么，让用户拿到包第一件事不用读文档。
 *
 * 判据与坑（与 skills/cj-tauri-env 同口径，两处必须一起改）：
 *   - 判「命令可用」一律以**命令自身退出码**为准，不能用 `command -v`：
 *     cjc / cjpm 本身是仓颉程序，二进制在 PATH 里但没设 LD_LIBRARY_PATH 时
 *     照样加载不了运行时——stdout 空、exit=127，而路径查得到。
 *   - Linux 上仓颉运行时 .so **不查 PATH**，只设 PATH 的表现是「找不到 libcangjie-runtime.so」。
 *   - `CANGJIE_STDX` 必须指 stdx 的**动态库目录**（<stdx>/<三元组>/dynamic/stdx），
 *     指到包根也能过 create，要到新工程里 cjpm build 才报 dependency info is missing。
 */
package cli

import std.fs.*
import std.process.*
import std.time.*

/** 一条检查的结论：ok / warn / fail（只有 fail 影响退出码） */
enum CheckLevel {
    | Ok
    | Warn
    | Fail
}

/** doctor 的自检结果统计 */
class DoctorReport {
    var okCount = 0
    var warnCount = 0
    var failCount = 0

    func record(level: CheckLevel): Unit {
        match (level) {
            case Ok => this.okCount++
            case Warn => this.warnCount++
            case Fail => this.failCount++
        }
    }
}

/**
 * 打印一行检查结论并计入统计：`  ok    项目名 : 说明`；失败时另起一行给「怎么办」。
 * 计数与打印绑在一起，避免「打了 ok 却没记账」这类统计与输出不一致的假象
 * （第一版就是各调用点手写 record，结果 ok 行全没计数，汇总报成 0 项通过）。
 */
func doctorLine(rep: DoctorReport, level: CheckLevel, label: String, detail: String, hint: String): Unit {
    rep.record(level)
    let tag = match (level) {
        case Ok => "ok  "
        case Warn => "warn"
        case Fail => "FAIL"
    }
    println("  ${tag}  ${label} : ${detail}")
    if (hint.size > 0) {
        println("          → ${hint}")
    }
}

/** 跑一条命令取 (退出码, 首行非空 stdout)，命令不存在时返回 (-1, "") */
func doctorProbe(exe: String, argv: Array<String>): (Int64, String) {
    try {
        // executeWithOutput 的 stdout 是 Array<UInt8>，按 UTF-8 解回字符串再按行取首行
        let (code, rawOut, _) = executeWithOutput(exe, argv)
        for (line in String.fromUtf8(rawOut).split("\n")) {
            let t = trimAscii(line)
            if (t.size > 0) {
                return (code, t)
            }
        }
        return (code, "")
    } catch (e: Exception) {
        let _ = e
        return (-1, "")
    }
}

/**
 * 环境自检逐行输出。返回 0 = 必需项全过（warn 不算失败）；1 = 有必需项失败。
 *
 * 必需项：cjc、cjpm、stdx、框架根、C 桥；其余是 warn（如项目不在、产物未构建、
 * Windows 的 WebView2 提示）——那些是「还没到那一步」，不是环境坏。
 */
func cmdDoctor(): Int64 {
    let rep = DoctorReport()
    println("cj-tauri doctor — 环境自检（CLI ${cliVersion()}）")
    println("")

    // ---- 基本环境 ----
    doctorLine(rep, CheckLevel.Ok, "宿主平台", "${hostOsName()} (${hostTriple()})", "")
    doctorLine(rep, CheckLevel.Ok, "工作目录", currentDir(), "")

    // ---- 仓颉 SDK ----
    let home = resolveCangjieHome()
    match (home) {
        case Some(h) =>
            doctorLine(rep, CheckLevel.Ok, "CANGJIE_HOME", h, "")
        case None =>
            doctorLine(rep, CheckLevel.Fail, "CANGJIE_HOME", "未找到",
                "设置 CANGJIE_HOME，或把 SDK 的 bin 加进 PATH（doctor 从 cjc 反推）；" +
                "下载：https://cangjie-lang.cn/download（需登录华为账号），本项目要求 SDK 1.2.0 + stdx 1.2.0.1，两者必须配套")
    }

    let (cjcCode, cjcVer) = doctorProbe("cjc", ["-v"])
    if (cjcCode == 0) {
        doctorLine(rep, CheckLevel.Ok, "cjc", cjcVer, "")
    } else {
        // 退出码 127 = 二进制在 PATH 里但运行时加载不了（Linux 上就是 LD_LIBRARY_PATH 没设）
        let why = if (cjcCode == 127) {
            "在 PATH 里但运行不了（exit=127，通常是 LD_LIBRARY_PATH 缺仓颉运行时）"
        } else {
            "不可用（exit=${cjcCode}）"
        }
        doctorLine(rep, CheckLevel.Fail, "cjc", why,
            "把 SDK 的 bin 加进 PATH；Linux 另需把 runtime/lib/<平台> 加进 LD_LIBRARY_PATH")
    }

    let (cjpmCode, cjpmVer) = doctorProbe("cjpm", ["-v"])
    if (cjpmCode == 0) {
        doctorLine(rep, CheckLevel.Ok, "cjpm", cjpmVer, "")
    } else {
        doctorLine(rep, CheckLevel.Fail, "cjpm", "不可用（exit=${cjpmCode}）",
            "把 SDK 的 tools/bin 加进 PATH（cjpm 还需要 tools/lib 与运行时）")
    }

    match (home) {
        case Some(h) =>
            match (findRuntimeLibDir(h)) {
                case Some(rt) =>
                    // Linux 上「目录存在」不等于「已设进环境」——见文件头判据
                    if (hostIsWindows()) {
                        doctorLine(rep, CheckLevel.Ok, "仓颉运行时", rt, "")
                    } else {
                        let ld = envOr("LD_LIBRARY_PATH", "")
                        if (ld.contains(rt)) {
                            doctorLine(rep, CheckLevel.Ok, "仓颉运行时", "${rt} [已进 LD_LIBRARY_PATH]", "")
                        } else {
                                        doctorLine(rep, CheckLevel.Warn, "仓颉运行时",
                                "${rt} [不在 LD_LIBRARY_PATH]",
                                "export LD_LIBRARY_PATH=\"${rt}:${'$'}LD_LIBRARY_PATH\"（CLI 自身会把子进程补上，手敲 cjc 才需要）")
                        }
                    }
                case None =>
                            doctorLine(rep, CheckLevel.Fail, "仓颉运行时", "在 SDK 下未找到 runtime/lib/<平台>",
                        "检查 SDK 是否解压完整（runtime/lib/linux_x86_64_cjnative 等）")
            }
        case None => ()
    }

    // ---- 框架根 / stdx / C 桥 ----
    var fwRoot = ""
    match (resolveFrameworkRoot()) {
        case Some(fw) =>
            fwRoot = fw
            doctorLine(rep, CheckLevel.Ok, "框架根目录", fw, "")
        case None =>
            doctorLine(rep, CheckLevel.Fail, "框架根目录", "未找到",
                "在框架仓库内运行，或设置 CJ_TAURI_ROOT 指向框架根")
    }

    let projRoot = findProjectRoot()
    // 显式标注：if 两分支各自返回 Option<String> / None，不标注会让类型推断拿不到实参
    let stdx: Option<String> = if (fwRoot.size > 0) {
        resolveStdx(fwRoot, projRoot)
    } else {
        None
    }
    match (stdx) {
        case Some(s) =>
            // 指到包根时 stdx 目录本身也存在，但 build 会报 dependency info is missing：
            // 这里按「里面有没有 .so / 目录是否叫 stdx」粗判一次，把坑提前暴露
            doctorLine(rep, CheckLevel.Ok, "stdx", s, "")
        case None =>
            doctorLine(rep, CheckLevel.Fail, "stdx", "未找到",
                "设置 CANGJIE_STDX 指向 <stdx>/<三元组>/dynamic/stdx（动态库目录，不是包根）；" +
                "下载：https://cangjie-lang.cn/download 同页的 stdx 包，版本须与 SDK 配套（1.2.0 配 1.2.0.1）")
    }

    if (fwRoot.size > 0) {
        let nativeDir = joinPath(fwRoot, "native")
        let lib = joinPath(nativeDir, bridgeLibName())
        if (exists(lib)) {
            // 桥是本地产物、不入库：源码新过产物说明改了 C 桥没重建，链接期会 undefined reference
            let newestSrc = newestBridgeSource(nativeDir)
            if (newestSrc.size > 0 && FileInfo(lib).lastModificationTime < FileInfo(newestSrc).lastModificationTime) {
                doctorLine(rep, CheckLevel.Warn, "C 桥", "${lib} [比源码旧]",
                    "改了 C 桥要重建：Linux `bash native/build_linux.sh`、Windows `native\\build_win.bat`")
            } else {
                doctorLine(rep, CheckLevel.Ok, "C 桥", "${lib} [已构建]", "")
            }
        } else {
            doctorLine(rep, CheckLevel.Fail, "C 桥", "${lib} 不存在",
                "`cj-tauri build` / `dev` 会自动构建；手敲则跑 native/build_linux.sh 或 build_win.bat")
        }
    }

    // ---- 项目（可选：不在项目里不算环境问题） ----
    match (projRoot) {
        case Some(proj) =>
            doctorLine(rep, CheckLevel.Ok, "项目根目录", proj, "")
            let newForm = exists(joinPath(proj, "cj-tauri.toml"))
            match (findAppBinary(proj, newForm)) {
                case Some(bin) =>
                    if (fwRoot.size > 0 && !appBinaryIsFresh(bin, fwRoot)) {
                                doctorLine(rep, CheckLevel.Warn, "可执行产物", "${bin} [比框架源码旧]",
                            "改了框架要重建应用：`cj-tauri build`（旧产物认不出新环境变量，会让 info 卡住）")
                    } else {
                        doctorLine(rep, CheckLevel.Ok, "可执行产物", bin, "")
                    }
                case None =>
                        doctorLine(rep, CheckLevel.Warn, "可执行产物", "未构建",
                            if (newForm) { "`cj-tauri sync` + `cj-tauri build`" } else { "`cj-tauri build`" })
            }
        case None =>
            doctorLine(rep, CheckLevel.Warn, "项目根目录", "当前不在 cj-tauri 项目内",
                "cd 到项目根（有 cjpm.toml 的那层）再跑 build / dev")
    }

    // ---- 图形栈（Linux 必需；Windows 由 WebView2 承担） ----
    if (hostIsWindows()) {
        doctorLine(rep, CheckLevel.Ok, "WebView2", "由系统提供（Win11 自带 Runtime）",
            "构建桥时 WebView2 SDK 版本不得高于本机 Runtime 版本")
    } else {
        doctorCheckLinuxGraphics(rep)
    }

    // ---- 汇总 ----
    println("")
    println("检查完毕：${rep.okCount} 项通过，${rep.warnCount} 项告警，${rep.failCount} 项失败")
    if (rep.failCount > 0) {
        println("按上面每条 FAIL 的 → 提示逐条补齐；只到 warn 说明环境够跑，只是还没到那一步。")
        return 1
    }
    println("环境齐了（warn 项按需处理）。")
    return 0
}

/**
 * Linux 图形栈检查：C 桥的链接与运行都依赖 WebKitGTK / GTK3，缺 pkg-config 或开发包
 * 会在链接期（找不到 -lwebkit2gtk-4.1）或运行期（找不到 .so）炸，提前在这里暴露。
 */
func doctorCheckLinuxGraphics(rep: DoctorReport): Unit {
    let (pkgCode, _) = doctorProbe("pkg-config", ["--version"])
    if (pkgCode != 0) {
        doctorLine(rep, CheckLevel.Fail, "pkg-config", "不可用",
            "sudo apt install pkg-config gcc libwebkit2gtk-4.1-dev libgtk-3-dev")
        return
    }
    let (wCode, wVer) = doctorProbe("pkg-config", ["--modversion", "webkit2gtk-4.1"])
    if (wCode == 0 && wVer.size > 0) {
        doctorLine(rep, CheckLevel.Ok, "webkit2gtk-4.1", wVer, "")
    } else {
        doctorLine(rep, CheckLevel.Fail, "webkit2gtk-4.1", "未找到",
            "sudo apt install libwebkit2gtk-4.1-dev（C 桥链接它）")
    }
    let (gCode, gVer) = doctorProbe("pkg-config", ["--modversion", "gtk+-3.0"])
    if (gCode == 0 && gVer.size > 0) {
        doctorLine(rep, CheckLevel.Ok, "gtk+-3.0", gVer, "")
    } else {
        doctorLine(rep, CheckLevel.Fail, "gtk+-3.0", "未找到",
            "sudo apt install libgtk-3-dev（C 桥链接它）")
    }
    let (cCode, cVer) = doctorProbe("gcc", ["--version"])
    if (cCode == 0) {
        doctorLine(rep, CheckLevel.Ok, "gcc", cVer, "")
    } else {
        doctorLine(rep, CheckLevel.Fail, "gcc", "不可用",
            "sudo apt install gcc（构建 C 桥）")
    }
}

/**
 * 框架 native/ 下最新的 C 源文件（含 core/ 与 platforms/），用于判桥产物新不新。
 * 找不到任何源文件时返回空串（调用方跳过新旧比较）。
 */
func newestBridgeSource(nativeDir: String): String {
    var newest = ""
    // FileInfo.lastModificationTime 是 DateTime（不是 epoch 整数），比较用 Option 装上一个值；
    // 带泛型实参的 None 必须写全，裸 None 推不出 Option<T> 的实参
    var newestTime: Option<DateTime> = Option<DateTime>.None
    let dirs = [joinPath(nativeDir, "core"), joinPath(joinPath(nativeDir, "platforms"), hostOsName())]
    for (d in dirs) {
        if (!exists(d)) {
            continue
        }
        for (f in Directory.readFrom(d)) {
            let name = f.name
            if (!(name.endsWith(".c") || name.endsWith(".h"))) {
                continue
            }
            let full = joinPath(d, name)
            let t = FileInfo(full).lastModificationTime
            match (newestTime) {
                case None =>
                    newestTime = Some(t)
                    newest = full
                case Some(prev) =>
                    if (t > prev) {
                        newestTime = Some(t)
                        newest = full
                    }
            }
        }
    }
    return newest
}
