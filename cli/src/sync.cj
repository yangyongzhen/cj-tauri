/**
 * 批次 2（RFC-002 §7.2）：cj-tauri check / sync
 *
 * check：清单静态校验 + 文件系统检查（entry/资产根/page）+ 骨架漂移检测（desktop/ohos）；
 * sync：按清单派生 targets/desktop + targets/ohos 骨架（幂等：重跑只覆盖生成物）。
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
            failed = checkOhosDrift(m, fw) || failed
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
 *   - 已注册的插件命令未在 capabilities 声明 → 失败（「漏声明编不过」的运行时兜底）；
 *     capabilities 的 permissions 命名权限集按插件自描述单层展开后与明文 commands 同权（对齐运行时）
 *   - requiredCapability 不在 capabilities 目录 → 失败
 *   - supportedHosts 不含当前宿主 → 提示（P-2：该端应以桩如实失败「端不支持」）
 *   - 骨架未构建 → 提示跳过（不阻塞，构建后重跑即生效）
 *
 * 边界如实说：应用自身命令（SystemCommands / wire 注册）不在无头导出里（该通道只带插件），
 * 它们的漏声明照旧由运行时能力门禁拒绝；导出形态将来再扩展。
 */
func checkThreeWay(m: Manifest): Bool {
    // cjpm 可执行工程的二进制恒名 main（music / CLI 同口径），与模块名无关；
    // 但 Windows 产物带 `.exe`（cjc 不补后缀，cmd 也不认无后缀名），裸名判定会让
    // 三方比对在 Windows 上恒被跳过——后缀与构建侧同源取（AGENTS §4「三处同源」）
    let binPath = "targets/desktop/target/release/bin/main" + exeSuffix()
    if (!exists(binPath)) {
        eprintln("[cj-tauri] 提示：跳过三方比对（桌面骨架未构建：${binPath}；cd targets/desktop && cjpm build 后重跑）")
        return false
    }
    // ① 能力声明：commands 全名集合 + identifier 集合 + permissions 引用的集名
    let declared = ArrayList<String>()
    let identifiers = ArrayList<String>()
    let permSetNames = ArrayList<String>()
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
            for (s in jsonStrArray(obj.get("permissions"))) {
                permSetNames.add(s)
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
    // 权限集单层展开（与运行时 CapabilityRegistry 同语义，见 src/capability.cj「单层展开」注释）：
    // 清单引用的每个集名，到插件自描述的 permissions（集全名 → 成员全名）里按名取成员并入 declared。
    // 成员若又是集名不再展开（避免环）。
    for (setName in permSetNames) {
        for (i in 0..pluginsArr.size()) {
            var pobj: JsonObject
            try {
                pobj = pluginsArr.get(i).getOrThrow().asObject()
            } catch (e: Exception) {
                continue
            }
            if (let Some(permVal) <- pobj.get("permissions")) {
                let permObj = permVal.asObject()
                if (let Some(membersVal) <- permObj.get(setName)) {
                    for (mm in jsonStrArray(membersVal)) {
                        if (!declared.contains(mm)) {
                            declared.add(mm)
                        }
                    }
                }
            }
        }
    }
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
                // ohos 端可用性汇总（P-2，批次 3-PR3）：check 跑在桌面，但要为「sync ohos 之后
                // 这些插件会变成桩」提前给一句可照做的提示——编译能过，运行期调用报「端不支持」
                if (hosts.size > 0 && !hosts.contains("arkweb")) {
                    eprintln("[cj-tauri] 提示：插件 ${pname} 无 ohos 端实现（声明 ${joinComma(hosts)}）——sync ohos 后为 P-1 桩，运行期调用将报「端不支持」")
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
                eprintln("用法: cj-tauri sync [desktop|ohos] [--framework <框架根路径>]")
                return 1
            }
            i += 1
            fwOverride = Some(args[i])
        } else {
            target = a
        }
        i += 1
    }
    if (target != "" && target != "desktop" && target != "ohos") {
        eprintln("用法: cj-tauri sync [desktop|ohos] [--framework <框架根路径>]")
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
    var code = 0
    if (target == "" || target == "desktop") {
        ensureDir("targets/desktop/src")
        writeText("targets/desktop/cjpm.toml", m.renderDesktopToml(fwRoot, cliVersion()))
        writeText("targets/desktop/src/main.cj", m.renderDesktopMain(cliVersion()))
        println("[cj-tauri] 已生成 targets/desktop/cjpm.toml 与 targets/desktop/src/main.cj（launcher 调 ${m.pkg}.build()）")
        println("[cj-tauri] 下一步：cd targets/desktop && cjpm build（需 CANGJIE_STDX 指向 stdx dynamic/stdx）")
    }
    if (target == "" || target == "ohos") {
        code = syncOhos(m, fwRoot)
    }
    return code
}

// ---------- ohos 骨架（批次 3-PR3，RFC §7.3） ----------

/** 能力清单文件名单：[capabilities] 目录下 .json 的 basename（sync 生成与 check 漂移共用） */
func listCapsFiles(dir: String): ArrayList<String> {
    let out = ArrayList<String>()
    if (!exists(dir)) {
        return out
    }
    var entries: Array<FileInfo>
    try {
        entries = Directory.readFrom(dir)
    } catch (e: Exception) {
        return out
    }
    for (info in entries) {
        if (info.isDirectory()) {
            continue
        }
        let path = info.path.toString()
        if (path.endsWith(".json")) {
            out.add(baseName(path))
        }
    }
    return out
}

/** 资产递归拷贝：资产根目录整体拷入 rawfile 目录（字节级、二进制安全——RFC §7.3 的 rawfile 资产注入口） */
func copyAssetsToRawfile(srcRoot: String, dstRoot: String): Int64 {
    if (!exists(srcRoot)) {
        eprintln("[cj-tauri] 错误：资产根不存在：${srcRoot}")
        return 0
    }
    ensureDir(dstRoot)
    var count = 0
    for (info in listDir(srcRoot)) {
        let nm = baseName(info.path.toString())
        if (nm.size == 0) {
            continue
        }
        let s = joinPath(srcRoot, nm)
        let d = joinPath(dstRoot, nm)
        if (info.isDirectory()) {
            count = count + copyAssetsToRawfile(s, d)
        } else {
            writeBytes(d, File.readFrom(s))
            count = count + 1
        }
    }
    return count
}

/**
 * ohos 骨架派生：ohos-skeleton 模板整体拷渲染（静态物 + 图标）+ 4 个清单派生文件覆盖 + rawfile 资产注入。
 * 幂等对齐 desktop：重跑覆盖生成物，rawfile 每次从 assets/ 全量重建。
 */
func syncOhos(m: Manifest, fwRoot: String): Int64 {
    let tplDirOpt = resolveTemplateDir(fwRoot, "ohos-skeleton")
    match (tplDirOpt) {
        case None =>
            eprintln("[cj-tauri] 未找到 ohos 骨架模板：${fwRoot}/cli/templates/ohos-skeleton（框架根定位有误？）")
            return 1
        case Some(tplDir) =>
            // 模板占位符取清单值：bundle=id、label=name；stdx 不参与（build-hap.sh 用 CANGJIE_STDX_OHOS）
            let v = TemplateVars(m.name, m.pkg, fwRoot, "", m.appId, m.name)
            ensureDir("targets/ohos")
            let count = copyTree(tplDir, "targets/ohos", v)
            // 4 个清单派生文件覆盖模板（check 的漂移检测复用同一批渲染器，二者必然一致）
            writeText("targets/ohos/AppScope/app.json5", m.renderOhosAppJson(cliVersion()))
            writeText("targets/ohos/entry/cjpm.toml", m.renderOhosEntryToml(fwRoot, cliVersion()))
            let capsFiles = listCapsFiles(m.capabilitiesDir)
            writeText("targets/ohos/entry/src/main/cangjie/app_host.cj", m.renderOhosAppHost(cliVersion(), capsFiles))
            writeText("targets/ohos/entry/src/main/cangjie/main_ability.cj", m.renderOhosMainAbility(cliVersion()))
            // rawfile 资产注入口：清掉模板自带的演示资产，按 assets/ 原样拷入（字节级）
            let rawfileDir = "targets/ohos/entry/src/main/resources/rawfile"
            if (exists(rawfileDir + "/index.html")) {
                remove(rawfileDir + "/index.html")
            }
            if (exists(rawfileDir + "/capabilities.json")) {
                remove(rawfileDir + "/capabilities.json")
            }
            let copied = copyAssetsToRawfile(m.assetsRoot, rawfileDir)
            println("[cj-tauri] 已生成 targets/ohos：模板 ${count} 文件 + 清单派生 4 文件 + rawfile ${copied} 资产")
            println("[cj-tauri] 下一步：export CANGJIE_STDX_OHOS=<鸿蒙版 stdx>/linux_ohos_aarch64_cjnative/dynamic/stdx")
            println("          cd targets/ohos && bash build-hap.sh")
            return 0
    }
}

/** ohos 骨架漂移：targets/ohos 存在才查（opt-in，不阻塞纯桌面应用）；4 派生文件 + rawfile 资产一致性 */
func checkOhosDrift(m: Manifest, fwRoot: String): Bool {
    if (!exists("targets/ohos/entry/cjpm.toml")) {
        eprintln("[cj-tauri] 提示：ohos 骨架未生成（应用要接鸿蒙端时运行 cj-tauri sync ohos）")
        return false
    }
    let ver = cliVersion()
    let capsFiles = listCapsFiles(m.capabilitiesDir)
    var failed = false
    failed = sameGeneratedFile("targets/ohos/AppScope/app.json5", m.renderOhosAppJson(ver), failed)
    failed = sameGeneratedFile("targets/ohos/entry/cjpm.toml", m.renderOhosEntryToml(fwRoot, ver), failed)
    failed = sameGeneratedFile("targets/ohos/entry/src/main/cangjie/app_host.cj", m.renderOhosAppHost(ver, capsFiles), failed)
    failed = sameGeneratedFile("targets/ohos/entry/src/main/cangjie/main_ability.cj", m.renderOhosMainAbility(ver), failed)
    // rawfile 资产：page 必须与资产根字节一致；能力文件名单必须与清单目录一致
    let rawfileDir = "targets/ohos/entry/src/main/resources/rawfile"
    let pageSrc = m.assetsRoot + "/" + m.page
    let pageDst = rawfileDir + "/" + m.page
    if (exists(pageSrc)) {
        if (!exists(pageDst) || !bytesEqual(File.readFrom(pageSrc), File.readFrom(pageDst))) {
            eprintln("[cj-tauri] 骨架漂移：${pageDst} 与 ${pageSrc} 不一致（重跑 cj-tauri sync ohos）")
            failed = true
        }
    }
    let capsDstDir = rawfileDir + "/capabilities"
    for (f in capsFiles) {
        if (!exists(capsDstDir + "/" + f)) {
            eprintln("[cj-tauri] 骨架漂移：缺 ${capsDstDir}/${f}（重跑 cj-tauri sync ohos）")
            failed = true
        }
    }
    if (exists(capsDstDir)) {
        for (info in listDir(capsDstDir)) {
            if (info.isDirectory()) {
                continue
            }
            let nm = baseName(info.path.toString())
            if (!capsFiles.contains(nm)) {
                eprintln("[cj-tauri] 骨架漂移：rawfile/capabilities 有残留文件 ${nm}（重跑 cj-tauri sync ohos）")
                failed = true
            }
        }
    }
    return failed
}

/** 生成物比对：缺失 = 漂移，内容不一致 = 漂移 */
func sameGeneratedFile(path: String, expect: String, failed: Bool): Bool {
    if (!exists(path)) {
        eprintln("[cj-tauri] 骨架漂移：缺生成文件 ${path}（重跑 cj-tauri sync ohos）")
        return true
    }
    if (readText(path) != expect) {
        eprintln("[cj-tauri] 骨架漂移：${path} 与生成器输出不一致（重跑 cj-tauri sync ohos）")
        return true
    }
    return failed
}

func bytesEqual(a: Array<UInt8>, b: Array<UInt8>): Bool {
    if (a.size != b.size) {
        return false
    }
    for (i in 0..a.size) {
        if (a[i] != b[i]) {
            return false
        }
    }
    return true
}
