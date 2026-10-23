/**
 * 批次 2（RFC-002 §7.2）：cj-tauri check / sync
 *
 * check：清单静态校验 + 文件系统检查（entry/资产根/page）+ 骨架漂移检测；
 * sync：按清单派生 targets/desktop 骨架（幂等：重跑只覆盖生成物）。
 * 清单不设 [plugins] 段——插件真相是业务 build() 装配（RFC §4.6.7），插件依赖生成随批次 3。
 */
package cli

import std.collection.*
import std.env.*
import std.fs.*
import std.process.*
import stdx.encoding.json.*

/** 读清单并校验；失败打印原因并返回 None */
func loadValidatedManifest(): Option<Manifest> {
    let source = "cj-tauri.toml"
    var text = ""
    try {
        text = readText(source)
    } catch (e: Exception) {
        eprintln("[cj-tauri] 当前目录没有 ${source}（cwd=${currentDir()}）")
        return None
    }
    var mOpt: Option<Manifest> = None
    try {
        mOpt = Some(Manifest.fromToml(text, source))
    } catch (e: Exception) {
        eprintln("[cj-tauri] 清单解析失败：${e.message}")
        return None
    }
    let m = mOpt.getOrThrow()
    var failed = false
    for (err in m.validate()) {
        eprintln("[cj-tauri] 清单错误：${err}")
        failed = true
    }
    if (failed) {
        return None
    }
    return Some(m)
}

/** 文件系统层检查（entry / 资产根 / page / capabilities）；返回是否失败 */
func checkManifestOnDisk(m: Manifest): Bool {
    var failed = false
    if (!exists(m.entry)) {
        eprintln("[cj-tauri] 清单错误：entry 不存在：${m.entry}")
        failed = true
    }
    if (!exists(m.assetsRoot)) {
        eprintln("[cj-tauri] 清单错误：[assets] root 不存在：${m.assetsRoot}")
        failed = true
    } else {
        let pagePath = m.assetsRoot + "/" + m.page
        if (!exists(pagePath)) {
            eprintln("[cj-tauri] 清单错误：[assets] page 不存在：${pagePath}")
            failed = true
        }
    }
    if (!exists(m.capabilitiesDir)) {
        eprintln("[cj-tauri] 提示：capabilities 目录不存在（${m.capabilitiesDir}）——没有命令权限声明")
    }
    return failed
}

/** 骨架漂移：缺骨架=提示（引导 sync），内容不一致=失败 */
func checkDesktopDrift(m: Manifest, fwRoot: String): Bool {
    let tomlPath = "targets/desktop/cjpm.toml"
    let mainPath = "targets/desktop/src/main.cj"
    let expectToml = m.renderDesktopToml(fwRoot, cliVersion())
    let expectMain = m.renderDesktopMain(cliVersion())
    var failed = false
    if (!exists(tomlPath)) {
        eprintln("[cj-tauri] 提示：骨架尚未生成（${tomlPath}）——运行 cj-tauri sync desktop")
    } else if (readText(tomlPath) != expectToml) {
        eprintln("[cj-tauri] 骨架漂移：${tomlPath} 与生成器输出不一致（运行 cj-tauri sync desktop 重新生成）")
        failed = true
    }
    if (exists(mainPath) && readText(mainPath) != expectMain) {
        eprintln("[cj-tauri] 骨架漂移：${mainPath} 与生成器输出不一致（运行 cj-tauri sync desktop 重新生成）")
        failed = true
    }
    return failed
}

func cmdCheck(): Int64 {
    let mOpt = loadValidatedManifest()
    if (let None <- mOpt) {
        return 1
    }
    let m = mOpt.getOrThrow()
    var failed = checkManifestOnDisk(m)
    match (resolveFrameworkRoot()) {
        case Some(fw) =>
            let drift = checkDesktopDrift(m, fw)
            failed = drift || failed
        case None =>
            eprintln("[cj-tauri] 提示：未定位到框架根（CJ_TAURI_ROOT），跳过骨架漂移检查")
    }
    // 三方比对（RFC §4.6.7）：骨架未构建时提示跳过，不阻塞
    failed = checkThreeWay(m) || failed
    if (failed) {
        eprintln("[cj-tauri] check 未通过：${m.appId}@${m.version}")
        return 1
    }
    println("[cj-tauri] check 通过：${m.appId}@${m.version}（${m.name}）")
    return 0
}

/**
 * 三方比对（批次 3，RFC §4.6.7）：① 能力声明 × ② 插件 describe() 自描述 × ③ 无头导出（实际装配真相）。
 * ②③ 由 CJ_TAURI_MANIFEST=json 无头导出一起带出（插件数组，与启动日志同款形态）。
 *
 * 规则：
 *   - 已注册的插件命令未在 capabilities 声明 → 失败（「漏声明编不过」的运行时兜底）
 *   - requiredCapability 不在 capabilities 目录 → 失败
 *   - supportedHosts 不含当前宿主 → 提示（P-2：该端应以桩如实失败「端不支持」）
 *   - 骨架未构建 → 提示跳过（不阻塞，构建后重跑即生效）
 *
 * 边界如实说：应用自身命令（SystemCommands / wire 注册）不在无头导出里（该通道只带插件），
 * 它们的漏声明照旧由运行时能力门禁拒绝；导出形态将来再扩展。
 */
func checkThreeWay(m: Manifest): Bool {
    // cjpm 可执行工程的二进制恒名 main（music / CLI 同口径），与模块名无关
    let binPath = "targets/desktop/target/release/bin/main"
    if (!exists(binPath)) {
        eprintln("[cj-tauri] 提示：跳过三方比对（桌面骨架未构建：${binPath}；cd targets/desktop && cjpm build 后重跑）")
        return false
    }
    // ① 能力声明：commands 全名集合 + identifier 集合
    let declared = ArrayList<String>()
    let identifiers = ArrayList<String>()
    if (exists(m.capabilitiesDir)) {
        var entries: Array<FileInfo>
        try {
            entries = Directory.readFrom(m.capabilitiesDir)
        } catch (e: Exception) {
            eprintln("[cj-tauri] 三方比对：读 capabilities 目录失败 ${m.capabilitiesDir}: ${e.message}")
            return true
        }
        for (info in entries) {
            if (info.isDirectory()) {
                continue
            }
            let path = info.path.toString()
            if (!path.endsWith(".json")) {
                continue
            }
            var text = ""
            try {
                text = String.fromUtf8(File.readFrom(path))
            } catch (e: Exception) {
                eprintln("[cj-tauri] 三方比对：读 ${path} 失败: ${e.message}")
                return true
            }
            var obj: JsonObject
            try {
                obj = JsonValue.fromStr(text).asObject()
            } catch (e: Exception) {
                eprintln("[cj-tauri] 三方比对：${path} 不是合法 JSON: ${e.message}")
                return true
            }
            if (let Some(idVal) <- obj.get("identifier")) {
                let id = jsonStringOf(idVal)
                if (id.size > 0) {
                    identifiers.add(id)
                }
            }
            for (c in jsonStrArray(obj.get("commands"))) {
                declared.add(c)
            }
        }
    }
    // ②③ 无头导出（子进程继承环境；json 模式只打印插件数组后退出）
    setVariable("CJ_TAURI_MANIFEST", "json")
    var outText = ""
    try {
        let (code, raw, _) = executeWithOutput(binPath, [])
        outText = String.fromUtf8(raw)
        if (code != 0) {
            eprintln("[cj-tauri] 三方比对：无头导出退出异常（code=${code}）：${outText}")
            return true
        }
    } catch (e: Exception) {
        eprintln("[cj-tauri] 三方比对：运行 ${binPath} 失败：${e.message}")
        return true
    }
    var pluginsArr: JsonArray
    try {
        pluginsArr = JsonValue.fromStr(outText).asArray()
    } catch (e: Exception) {
        eprintln("[cj-tauri] 三方比对：无头导出输出解析失败：${e.message}")
        return true
    }
    let hostKind = localHostKind()
    var failed = false
    for (i in 0..pluginsArr.size()) {
        var obj: JsonObject
        try {
            obj = pluginsArr.get(i).getOrThrow().asObject()
        } catch (e: Exception) {
            continue
        }
        if (let Some(nameVal) <- obj.get("name")) {
            let pname = jsonStringOf(nameVal)
            if (pname.size > 0) {
                for (c in jsonStrArray(obj.get("commands"))) {
                    if (!declared.contains(c)) {
                        eprintln("[cj-tauri] 三方比对：已注册命令 ${c} 未在 capabilities 声明（补进 ${m.capabilitiesDir}/*.json 的 commands）")
                        failed = true
                    }
                }
                for (r in jsonStrArray(obj.get("requiredCapabilities"))) {
                    if (!identifiers.contains(r)) {
                        eprintln("[cj-tauri] 三方比对：插件 ${pname} 要求的能力 ${r} 不在 ${m.capabilitiesDir} 中")
                        failed = true
                    }
                }
                let hosts = jsonStrArray(obj.get("supportedHosts"))
                if (hosts.size > 0 && !hosts.contains(hostKind)) {
                    eprintln("[cj-tauri] 提示：插件 ${pname} 声明不支持当前宿主（${hostKind}，声明 ${joinComma(hosts)}）——该端应以桩如实失败「端不支持」（P-2）")
                }
            }
        }
    }
    return failed
}

/** JsonValue → 字符串（非字符串形态返回空串；用法与 cspub 先例一致：先过 kind 再转换） */
func jsonStringOf(v: JsonValue): String {
    match (v.kind()) {
        case JsonKind.JsString => return v.asString().getValue()
        case _ => return ""
    }
}

/** Option<JsonValue> → 字符串数组（缺失或非数组形态返回空） */
func jsonStrArray(v: Option<JsonValue>): ArrayList<String> {
    let out = ArrayList<String>()
    if (let Some(val) <- v) {
        try {
            let arr = val.asArray()
            for (i in 0..arr.size()) {
                if (let Some(item) <- arr.get(i)) {
                    let s = jsonStringOf(item)
                    if (s.size > 0) {
                        out.add(s)
                    }
                }
            }
        } catch (e: Exception) {
            // 非数组形态按空处理：上层消息会指出具体字段
        }
    }
    return out
}

/** 开发机 hostKind（CLI 只跑在桌面，映射与框架 discover 一致）：linux→webkitgtk、windows→webview2 */
func localHostKind(): String {
    if (let Some(v) <- getVariable("OS")) {
        if (v.contains("Windows")) {
            return "webview2"
        }
    }
    return "webkitgtk"
}

/** "a,b" 拼接，供提示消息 */
func joinComma(items: ArrayList<String>): String {
    var s = ""
    for (x in items) {
        if (s.size > 0) {
            s += ","
        }
        s += x
    }
    return s
}

func cmdSync(args: Array<String>): Int64 {
    var target = ""
    var fwOverride: Option<String> = None
    var i: Int64 = 1
    while (i < args.size) {
        let a = args[i]
        if (a == "--framework") {
            if (i + 1 >= args.size) {
                eprintln("用法: cj-tauri sync desktop [--framework <框架根路径>]")
                return 1
            }
            i += 1
            fwOverride = Some(args[i])
        } else {
            target = a
        }
        i += 1
    }
    if (target != "desktop") {
        eprintln("批次 2 仅支持 desktop（ohos/macos/android 随批次 3 起接入）。用法: cj-tauri sync desktop")
        return 1
    }
    let mOpt = loadValidatedManifest()
    if (let None <- mOpt) {
        return 1
    }
    let m = mOpt.getOrThrow()
    var fwRoot = ""
    match (fwOverride) {
        case Some(f) => fwRoot = f
        case None =>
            match (resolveFrameworkRoot()) {
                case Some(f) => fwRoot = f
                case None =>
                    eprintln("[cj-tauri] 未定位到框架根：请 export CJ_TAURI_ROOT=<框架仓库根>，或 --framework <路径>")
                    return 1
            }
    }
    ensureDir("targets/desktop/src")
    writeText("targets/desktop/cjpm.toml", m.renderDesktopToml(fwRoot, cliVersion()))
    writeText("targets/desktop/src/main.cj", m.renderDesktopMain(cliVersion()))
    println("[cj-tauri] 已生成 targets/desktop/cjpm.toml 与 targets/desktop/src/main.cj（launcher 调 ${m.pkg}.build()）")
    println("[cj-tauri] 下一步：cd targets/desktop && cjpm build（需 CANGJIE_STDX 指向 stdx dynamic/stdx）")
    return 0
}
