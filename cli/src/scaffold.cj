/**
 * cj-tauri CLI：项目脚手架（create）
 *
 * 模板位于 <框架根>/cli/templates/<模板目录>，占位符形如 {{PROJECT_NAME}}；
 * 递归拷贝 + 文本渲染，生成「新形态」工程（cj-tauri.toml 清单 + 业务 static 包 + assets/），
 * 骨架由 cj-tauri sync 派生（RFC-002 §7）：桌面 cj-tauri dev，鸿蒙 targets/ohos 的 build-hap.sh。
 * ohos-skeleton 目录是 cj-tauri sync ohos 的 DevEco 骨架源，不是 create 模板。
 */
package cli

import std.fs.*
import std.collection.*

/** 模板占位符取值 */
public class TemplateVars {
    let projectName: String
    let packageName: String
    let frameworkRoot: String
    let nativeDir: String
    let stdxDir: String
    let targetSection: String
    /** 鸿蒙应用的安装 ID（bundleName），桌面模板不用 */
    let bundleName: String
    /** 应用显示名（桌面模板用项目名，鸿蒙写进 string.json） */
    let appLabel: String

    public init(projectName: String, packageName: String, frameworkRoot: String, stdxDir: String,
                bundleName: String, appLabel: String) {
        this.projectName = projectName
        this.packageName = packageName
        this.frameworkRoot = frameworkRoot
        this.nativeDir = joinPath(frameworkRoot, "native")
        this.stdxDir = stdxDir
        this.targetSection = buildTargetSection(joinPath(frameworkRoot, "native"), stdxDir)
        this.bundleName = bundleName
        this.appLabel = appLabel
    }
}

/** 生成 cjpm.toml 的 [target.<triple>] 段落（含桥链接参数与 stdx 路径） */
func buildTargetSection(nativeDir: String, stdxDir: String): String {
    let triple = hostTriple()
    var linkOpt = "-L" + escapeTomlString(nativeDir) + " -lcjtbridge"
    if (hostIsWindows()) {
        // GUI 子系统：不写这个开关，产物是 console 程序，双击时会多出一个控制台黑窗口（AGENTS §4）。
        // 取值只能用链接器那套——cjc 把 --link-options 直通 ld.lld，gcc 的 -mwindows 会被拒。
        // 注意别在这儿写「行内 `#` 注释」:Cangjie 里 `#` 是 raw string 前缀、不是注释符，
        // 生成出来的 toml 那行也就只放开关、不放尾注（保证与文档里的行数表格一致）。
        linkOpt = linkOpt + " --subsystem=windows"
    } else {
        linkOpt = linkOpt + " -lwebkit2gtk-4.1 -lgtk-3 -lgdk-3 -lglib-2.0 -lgio-2.0 -lsoup-3.0" +
                  " -ljavascriptcoregtk-4.1 -lgobject-2.0"
    }
    var s = "[target." + triple + "]\n"
    s = s + "  link-option = \"" + linkOpt + "\"\n"
    s = s + "\n[target." + triple + ".bin-dependencies]\n"
    s = s + "    path-option = [\"" + escapeTomlString(stdxDir) + "\"]\n"
    return s
}

/** 渲染模板文本 */
func renderTemplate(content: String, v: TemplateVars): String {
    var out = content
    out = out.replace("{{PROJECT_NAME}}", v.projectName)
    out = out.replace("{{PACKAGE_NAME}}", v.packageName)
    out = out.replace("{{CJC_VERSION}}", minCjcVersion())
    out = out.replace("{{FRAMEWORK_ROOT_TOML}}", escapeTomlString(v.frameworkRoot))
    out = out.replace("{{NATIVE_DIR_TOML}}", escapeTomlString(v.nativeDir))
    out = out.replace("{{STDX_DIR_TOML}}", escapeTomlString(v.stdxDir))
    out = out.replace("{{TARGET_SECTION}}", v.targetSection)
    out = out.replace("{{FRAMEWORK_ROOT}}", v.frameworkRoot)
    out = out.replace("{{NATIVE_DIR}}", v.nativeDir)
    out = out.replace("{{STDX_DIR}}", v.stdxDir)
    out = out.replace("{{BUNDLE_NAME}}", v.bundleName)
    out = out.replace("{{APP_LABEL}}", v.appLabel)
    return out
}

/**
 * 模板里哪些文件必须**按字节原样拷**
 *
 * 模板要带图标（`resources/base/media/` 下的 png），而 `readText` 走 UTF-8——二进制过一遍
 * 文本渲染会当场损坏（就算侥幸没崩，png 也变得打不开，要到装到设备上才看得见白方块）。
 * 判据只看扩展名：模板里不需要「文本渲染的二进制」，真需要再另说。
 */
func isBinaryTemplateFile(name: String): Bool {
    let b = name.toArray()
    let out = ArrayList<UInt8>()
    for (i in 0..b.size) {
        out.add(toLowerByte(b[i]))
    }
    let lower = String.fromUtf8(out.toArray())
    let exts = ["png", "jpg", "jpeg", "gif", "webp", "ico", "ttf", "otf", "woff", "woff2",
                "so", "dll", "a", "lib", "hap", "zip", "gz", "pdf", "wav", "mp3", "mp4"]
    for (ext in exts) {
        if (lower.endsWith("." + ext)) {
            return true
        }
    }
    return false
}

/** 项目名 → 仓颉包名（lowerCamelCase）：my-app → myApp */
func packageNameFrom(name: String): Option<String> {
    let b = name.toArray()
    if (b.size == 0) {
        return None
    }
    let out = ArrayList<UInt8>()
    var upperNext = false
    var first = true
    for (i in 0..b.size) {
        let c = b[i]
        if (c == 0x2D || c == 0x5F || c == 0x2E) { // - _ .
            upperNext = true
            continue
        }
        if (!isAsciiAlpha(c) && !isAsciiDigit(c)) {
            return None
        }
        var ch = c
        if (upperNext) {
            ch = toUpperByte(c)
            upperNext = false
        }
        if (first) {
            if (!isAsciiAlpha(ch)) {
                return None
            }
            ch = toLowerByte(ch)
            first = false
        }
        out.add(ch)
    }
    if (out.size == 0 || first) {
        return None
    }
    return Some(String.fromUtf8(out.toArray()))
}

/**
 * 按字节覆盖写
 *
 * 模板里的图片不能走 `writeText`：`readText` 是 UTF-8 解码，读 png 当场抛
 * `IllegalArgumentException: Invalid unicode scalar value`（create 直接崩、目录留半成品）。
 */
func writeBytes(p: String, data: Array<UInt8>): Unit {
    if (exists(p)) {
        remove(p)
    }
    let f = File.create(p)
    f.write(data)
    f.close()
}

/** 递归拷贝模板目录：目录建目录、文本渲染后写出、二进制原样拷 */
func copyTree(src: String, dst: String, v: TemplateVars): Int64 {
    var count = 0
    for (info in listDir(src)) {
        let nm = baseName(info.path.toString())
        if (nm.size == 0) {
            continue
        }
        let s = joinPath(src, nm)
        let d = joinPath(dst, nm)
        if (info.isDirectory()) {
            ensureDir(d)
            count = count + copyTree(s, d, v)
        } else if (isBinaryTemplateFile(nm)) {
            writeBytes(d, File.readFrom(s))
            count = count + 1
        } else {
            writeText(d, renderTemplate(readText(s), v))
            count = count + 1
        }
    }
    return count
}

/** 模板别名 → 仓库里的模板目录名（缺省 app，0.3.x 的老用法不受影响） */
func templateDirName(tpl: String): Option<String> {
    if (tpl == "app" || tpl == "vanilla") {
        return Some("app")          // 内联 HTML 单文件，零 Node 依赖
    }
    if (tpl == "vue") {
        return Some("app-vue")      // Vue 3 + Vite：dev 走 HMR，发布产单文件
    }
    if (tpl == "react") {
        return Some("app-react")    // React 18 + Vite
    }
    // 鸿蒙生态（PC / 手机 / 平板）：新形态是统一工程，模板内容同 app——
    // 清单决定目标端，骨架由 cj-tauri sync ohos 派生；旧 ohos-pc 命名保留兼容
    if (tpl == "ohos" || tpl == "ohos-pc" || tpl == "harmonyos" || tpl == "harmonyos-pc") {
        return Some("app")
    }
    // 内部用：cj-tauri sync ohos 的骨架源（DevEco 工程，不是 create 模板）
    if (tpl == "ohos-skeleton") {
        return Some("ohos-skeleton")
    }
    return None
}

/** create --template 参数是否鸿蒙生态（下一步提示用；新形态下不能按目录名判） */
func isOhosTemplate(tpl: String): Bool {
    return tpl == "ohos" || tpl == "ohos-pc" || tpl == "harmonyos" || tpl == "harmonyos-pc"
}

/**
 * 项目名 → 缺省 bundleName（`com.example.<小写下划线名>`）
 *
 * 鸿蒙要求 bundleName 每一段以字母开头、只含字母数字下划线，且至少三段；
 * 项目名里的 `-` `.` 之类一律折成 `_`，数字开头补 `app` 前缀。用户可以用 `--bundle` 覆盖。
 */
func bundleNameFrom(projectName: String): String {
    let b = projectName.toArray()
    let out = ArrayList<UInt8>()
    for (i in 0..b.size) {
        let c = toLowerByte(b[i])
        if (isAsciiAlpha(c) || isAsciiDigit(c)) {
            out.add(c)
        } else {
            out.add(0x5F) // '_'
        }
    }
    var s = String.fromUtf8(out.toArray())
    if (s.size > 0 && isAsciiDigit(s.toArray()[0])) {
        s = "app" + s
    }
    if (s.size == 0) {
        s = "app"
    }
    return "com.example." + s
}

/** 解析模板目录：先查别名表，查不到就把参数当模板目录名直接用（方便自己往仓库里加模板） */
func resolveTemplateDir(fwRoot: String, tpl: String): Option<String> {
    let base = joinPath(joinPath(fwRoot, "cli"), "templates")
    var name = tpl
    if (let Some(n) <- templateDirName(tpl)) {
        name = n
    }
    let dir = joinPath(base, name)
    if (exists(dir)) {
        return Some(dir)
    }
    return None
}

/** 列出仓库里实际存在的模板目录（拼错误提示用） */
func availableTemplates(fwRoot: String): String {
    let base = joinPath(joinPath(fwRoot, "cli"), "templates")
    var out = ""
    if (exists(base)) {
        for (info in listDir(base)) {
            if (!info.isDirectory()) {
                continue
            }
            let nm = baseName(info.path.toString())
            if (nm.size == 0) {
                continue
            }
            if (out.size > 0) {
                out = out + " / "
            }
            out = out + nm
        }
    }
    return out
}

func cmdCreate(nameArg: String, tpl: String, bundleArg: String, labelArg: String): Int64 {
    let targetDir = stripTrailingSep(nameArg)
    if (targetDir.size == 0) {
        eprintln("用法: cj-tauri create <项目名> [--template app|vue|react|ohos]")
        return 1
    }
    let projectName = baseName(targetDir)
    var pkg = ""
    if (let Some(p) <- packageNameFrom(projectName)) {
        pkg = p
    } else {
        eprintln("[cj-tauri] 错误: 项目名 '${projectName}' 推导不出合法仓颉包名")
        eprintln("          要求以字母开头，只含字母/数字/-/_/.（例如 my-app）")
        return 1
    }
    if (exists(targetDir)) {
        eprintln("[cj-tauri] 错误: 目录已存在: ${targetDir}")
        return 1
    }
    var fwRoot = ""
    if (let Some(r) <- resolveFrameworkRoot()) {
        fwRoot = r
    } else {
        eprintln("[cj-tauri] 错误: 找不到 cj-tauri 框架根目录")
        eprintln("          请设置环境变量 CJ_TAURI_ROOT 指向 cj-tauri 仓库根目录")
        return 1
    }
    // 模板先解析。新形态业务 toml 的 stdx 走 ${CANGJIE_STDX} 环境变量
    // （cjpm 构建期替换），create 不再需要解析 stdx
    var tplDir = ""
    var dirName = ""
    if (let Some(d) <- resolveTemplateDir(fwRoot, tpl)) {
        tplDir = d
        dirName = baseName(d)
    } else {
        eprintln("[cj-tauri] 错误: 未知模板 '${tpl}'")
        eprintln("          可用模板: ${availableTemplates(fwRoot)}")
        eprintln("          别名: app（内联单文件，缺省）/ vue / react / ohos")
        return 1
    }
    if (dirName == "ohos-skeleton") {
        eprintln("[cj-tauri] 错误: ohos-skeleton 是 cj-tauri sync ohos 的骨架源，不能用于 create")
        eprintln("          创建鸿蒙工程请用: cj-tauri create ${nameArg} --template ohos")
        return 1
    }
    let ohos = isOhosTemplate(tpl)
    warnIfSpacey("框架", fwRoot)

    var bundle = bundleArg
    if (bundle.size == 0) {
        bundle = bundleNameFrom(projectName)
    }
    var label = labelArg
    if (label.size == 0) {
        label = projectName
    }

    let v = TemplateVars(projectName, pkg, fwRoot, "", bundle, label)
    ensureDir(targetDir)
    let count = copyTree(tplDir, targetDir, v)

    println("[cj-tauri] 已创建项目 ${targetDir}/（${count} 个文件）")
    println("")
    println("  项目名   : ${projectName}")
    println("  模板     : ${tpl}")
    println("  仓颉包名 : ${pkg}")
    println("  框架依赖 : ${fwRoot}")
    if (ohos) {
        println("  应用名   : ${label}")
        println("  bundle   : ${bundle}")
    }
    println("")
    println("下一步:")
    println("  cd ${targetDir}")
    println("  cj-tauri sync          # 按清单派生 targets/ 骨架（desktop + ohos）")
    if (dirName == "app-vue" || dirName == "app-react") {
        println("  cd assets/ui && npm install && cd ../..   # 前端依赖（需 Node.js）")
        println("  cj-tauri dev           # 起 Vite dev server（热更新）+ 编译 + 启动窗口")
    } else {
        println("  cj-tauri dev           # 构建 C 桥 + 编译 + 启动窗口")
    }
    if (ohos) {
        println("  鸿蒙端: export CANGJIE_STDX_OHOS=<鸿蒙版 stdx>/linux_ohos_aarch64_cjnative/dynamic/stdx")
        println("          cd targets/ohos && bash build-hap.sh [--install]")
        println("")
        println("  提示: 模板不带签名证书——首次在 DevEco 里 File → Project Structure → Signing Configs")
        println("        勾「Automatically generate signature」（要登录华为账号）；不签名只能编出")
        println("        *-unsigned.hap，装不进设备。")
    } else {
        println("")
        println("  提示: cjpm.toml 里的框架路径是本机绝对路径；换机器需重新执行 create 或手改这一处。")
    }
    if (exists(joinPath(joinPath(joinPath(targetDir, "assets"), "ui"), "package.json"))) {
        println("")
        println("  提示: 该模板前端用 Vite；首次 cj-tauri dev 会自动 npm install 并起 dev server")
        println("        （页面走 CJ_TAURI_DEV_URL，改 assets/ui/src 下的前端源码不重启应用就能看到效果）。")
    }
    return 0
}
