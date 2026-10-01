/**
 * cj-tauri CLI：宿主平台 / 框架根目录 / stdx / 仓颉工具链 解析
 */
package cli

import std.env.*
import std.fs.*
import std.collection.*

// ===== 宿主平台 =====

func hostIsWindows(): Bool {
    if (let Some(os) <- getVariable("OS")) {
        if (os.contains("Windows")) {
            return true
        }
    }
    if (getVariable("WINDIR").isSome()) {
        return true
    }
    return false
}

func hostOsName(): String {
    if (hostIsWindows()) {
        return "Windows"
    }
    return "Linux"
}

func hostTriple(): String {
    if (hostIsWindows()) {
        return "x86_64-w64-mingw32"
    }
    return "x86_64-unknown-linux-gnu"
}

func bridgeLibName(): String {
    if (hostIsWindows()) {
        return "libcjtbridge.dll"
    }
    return "libcjtbridge.so"
}

func pathListSep(): String {
    if (hostIsWindows()) {
        return ";"
    }
    return ":"
}

func exeSuffix(): String {
    if (hostIsWindows()) {
        return ".exe"
    }
    return ""
}

/** 生成项目 cjpm.toml 里的 cjc-version（最低要求，非精确版本） */
func minCjcVersion(): String {
    return "1.0.5"
}

// ===== 环境 / 工具链 =====

func envOr(key: String, def: String): String {
    if (let Some(v) <- getVariable(key)) {
        return v
    }
    return def
}

func currentDir(): String {
    try {
        return stripTrailingSep(getWorkingDirectory().toString())
    } catch (e: Exception) {
        return "."
    }
}

/** 当前可执行文件路径（Windows 支持 getCommandLine，其它平台可能抛异常） */
func currentExePath(): Option<String> {
    try {
        let cmd = getCommandLine()
        if (cmd.size > 0) {
            return Some(cmd[0])
        }
    } catch (e: Exception) {
        return None
    }
    return None
}

/** 在 PATH 中查找可执行文件（Windows 自动补 .exe） */
func findOnPath(name: String): Option<String> {
    let path = envOr("PATH", "")
    for (dir in path.split(pathListSep())) {
        if (dir.size == 0) {
            continue
        }
        let cand = joinPath(stripTrailingSep(dir), name)
        if (exists(cand)) {
            return Some(cand)
        }
        if (hostIsWindows()) {
            let candExe = cand + ".exe"
            if (exists(candExe)) {
                return Some(candExe)
            }
        }
    }
    return None
}

/** 仓颉 SDK 根目录：CANGJIE_HOME → PATH 中的 cjc */
func resolveCangjieHome(): Option<String> {
    if (let Some(h0) <- getVariable("CANGJIE_HOME")) {
        let h = stripTrailingSep(h0)
        if (exists(joinPath(h, "bin"))) {
            return Some(h)
        }
    }
    if (let Some(cjc) <- findOnPath("cjc")) {
        if (let Some(binDir) <- parentDir(cjc)) {
            if (let Some(home) <- parentDir(binDir)) {
                return Some(home)
            }
        }
    }
    return None
}

/** cjpm：PATH → <SDK>/tools/bin/cjpm[.exe] */
func resolveCjpm(): Option<String> {
    if (let Some(p) <- findOnPath("cjpm")) {
        return Some(p)
    }
    if (let Some(home) <- resolveCangjieHome()) {
        let cand = joinPath(joinPath(joinPath(home, "tools"), "bin"), "cjpm" + exeSuffix())
        if (exists(cand)) {
            return Some(cand)
        }
    }
    return None
}

/** 仓颉运行时库目录（含 libcangjie-runtime） */
func findRuntimeLibDir(home: String): Option<String> {
    let libRoot = joinPath(joinPath(home, "runtime"), "lib")
    if (!exists(libRoot)) {
        return None
    }
    var prefix = "linux"
    if (hostIsWindows()) {
        prefix = "windows"
    }
    for (info in listDir(libRoot)) {
        if (!info.isDirectory()) {
            continue
        }
        let nm = baseName(info.path.toString())
        if (nm.startsWith(prefix)) {
            return Some(joinPath(libRoot, nm))
        }
    }
    return None
}

// ===== 框架根目录 =====

func looksLikeFrameworkRoot(dir: String): Bool {
    if (!exists(joinPath(dir, "cjpm.toml"))) {
        return false
    }
    return exists(joinPath(joinPath(joinPath(dir, "cli"), "templates"), "app"))
}

func findFrameworkRootFrom(start: String): Option<String> {
    var cur: Option<String> = Some(stripTrailingSep(start))
    var guard = 0
    while (guard < 64) {
        guard++
        if (let Some(d) <- cur) {
            if (looksLikeFrameworkRoot(d)) {
                return Some(d)
            }
            cur = parentDir(d)
        } else {
            return None
        }
    }
    return None
}

/** 框架根目录：CJ_TAURI_ROOT → 工作目录向上 → 可执行文件位置向上 */
func resolveFrameworkRoot(): Option<String> {
    if (let Some(env) <- getVariable("CJ_TAURI_ROOT")) {
        let dir = stripTrailingSep(env)
        if (looksLikeFrameworkRoot(dir)) {
            return Some(dir)
        }
        eprintln("[cj-tauri] 告警: CJ_TAURI_ROOT=${env} 不是有效的 cj-tauri 框架根目录")
    }
    if (let Some(found) <- findFrameworkRootFrom(currentDir())) {
        return Some(found)
    }
    if (let Some(exe) <- currentExePath()) {
        if (let Some(dir) <- parentDir(exe)) {
            if (let Some(found) <- findFrameworkRootFrom(dir)) {
                return Some(found)
            }
        }
    }
    return None
}

// ===== TOML 取值 =====

/** 取字符串中第一个 TOML 双引号串（并反转义 \\ 与 \"） */
func firstQuoted(s: String): Option<String> {
    let b = s.toArray()
    var i = 0
    while (i < b.size && b[i] != 0x22) {
        i++
    }
    if (i >= b.size) {
        return None
    }
    let out = ArrayList<UInt8>()
    var j = i + 1
    while (j < b.size) {
        if (b[j] == 0x5C && j + 1 < b.size) {
            out.add(b[j + 1])
            j += 2
            continue
        }
        if (b[j] == 0x22) {
            break
        }
        out.add(b[j])
        j++
    }
    return Some(String.fromUtf8(out.toArray()))
}

/** 从 cjpm.toml 文本取指定 target 段的 path-option 首项 */
func pathOptionFor(content: String, triple: String): Option<String> {
    var inSection = false
    for (rawLine in content.split("\n")) {
        let line = trimAscii(rawLine)
        if (line.startsWith("[")) {
            inSection = line.contains(triple)
            continue
        }
        if (inSection && line.startsWith("path-option")) {
            if (let Some(v) <- firstQuoted(line)) {
                return Some(v)
            }
        }
    }
    return None
}

/** 项目 cjpm.toml 中 cjTauri 依赖路径 */
func frameworkFromProject(projectRoot: String): Option<String> {
    let toml = joinPath(projectRoot, "cjpm.toml")
    if (!exists(toml)) {
        return None
    }
    for (rawLine in readText(toml).split("\n")) {
        let line = trimAscii(rawLine)
        if (line.startsWith("cjTauri")) {
            if (let Some(v) <- firstQuoted(line)) {
                return Some(stripTrailingSep(v))
            }
        }
    }
    return None
}

/** stdx 目录：CANGJIE_STDX → 项目 cjpm.toml → 框架 cjpm.toml */
func resolveStdx(fwRoot: String, projectRoot: Option<String>): Option<String> {
    if (let Some(v0) <- getVariable("CANGJIE_STDX")) {
        let v = stripTrailingSep(v0)
        if (v.size > 0 && exists(v)) {
            return Some(v)
        }
    }
    if (let Some(proj) <- projectRoot) {
        let toml = joinPath(proj, "cjpm.toml")
        if (exists(toml)) {
            if (let Some(v) <- pathOptionFor(readText(toml), hostTriple())) {
                return Some(stripTrailingSep(v))
            }
        }
    }
    let fwToml = joinPath(fwRoot, "cjpm.toml")
    if (exists(fwToml)) {
        if (let Some(v) <- pathOptionFor(readText(fwToml), hostTriple())) {
            return Some(stripTrailingSep(v))
        }
    }
    return None
}
