/**
 * cj-tauri CLI：项目脚手架（create）
 *
 * 模板位于 <框架根>/cli/templates/app，占位符形如 {{PROJECT_NAME}}；
 * 递归拷贝 + 文本渲染，生成一个可直接 `cj-tauri dev` 的应用。
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

    public init(projectName: String, packageName: String, frameworkRoot: String, stdxDir: String) {
        this.projectName = projectName
        this.packageName = packageName
        this.frameworkRoot = frameworkRoot
        this.nativeDir = joinPath(frameworkRoot, "native")
        this.stdxDir = stdxDir
        this.targetSection = buildTargetSection(joinPath(frameworkRoot, "native"), stdxDir)
    }
}

/** 生成 cjpm.toml 的 [target.<triple>] 段落（含桥链接参数与 stdx 路径） */
func buildTargetSection(nativeDir: String, stdxDir: String): String {
    let triple = hostTriple()
    var linkOpt = "-L" + escapeTomlString(nativeDir) + " -lcjtbridge"
    if (!hostIsWindows()) {
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
    return out
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

/** 递归拷贝模板目录：目录建目录、文件渲染后写出 */
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
        } else {
            writeText(d, renderTemplate(readText(s), v))
            count = count + 1
        }
    }
    return count
}

/** 模板别名 → 仓库里的模板目录名（缺省 app，0.3.x 的老用法不受影响） */
func templateDirName(tpl: String): Option<String> {
    match (tpl) {
        case "app" => Some("app")          // 内联 HTML 单文件，零 Node 依赖
        case "vanilla" => Some("app")
        case "vue" => Some("app-vue")      // Vue 3 + Vite：dev 走 HMR，发布产单文件
        case "react" => Some("app-react")  // React 18 + Vite
        case _ => None
    }
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

func cmdCreate(nameArg: String, tpl: String): Int64 {
    let targetDir = stripTrailingSep(nameArg)
    if (targetDir.size == 0) {
        eprintln("用法: cj-tauri create <项目名>")
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
    var stdx = ""
    if (let Some(s) <- resolveStdx(fwRoot, None)) {
        stdx = s
    } else {
        eprintln("[cj-tauri] 错误: 找不到 stdx 目录")
        eprintln("          请设置环境变量 CANGJIE_STDX 指向 stdx 动态库目录（含 stdx.encoding.json）")
        return 1
    }
    var tplDir = ""
    if (let Some(d) <- resolveTemplateDir(fwRoot, tpl)) {
        tplDir = d
    } else {
        eprintln("[cj-tauri] 错误: 未知模板 '${tpl}'")
        eprintln("          可用模板: ${availableTemplates(fwRoot)}")
        eprintln("          别名: app（内联单文件，缺省）/ vue / react")
        return 1
    }
    warnIfSpacey("框架", fwRoot)

    let v = TemplateVars(projectName, pkg, fwRoot, stdx)
    ensureDir(targetDir)
    let count = copyTree(tplDir, targetDir, v)

    println("[cj-tauri] 已创建项目 ${targetDir}/（${count} 个文件）")
    println("")
    println("  项目名   : ${projectName}")
    println("  模板     : ${baseName(tplDir)}")
    println("  仓颉包名 : ${pkg}")
    println("  框架依赖 : ${fwRoot}")
    println("  stdx     : ${stdx}")
    println("")
    println("下一步:")
    println("  cd ${targetDir}")
    println("  cj-tauri dev          # 构建 C 桥 + 编译 + 启动窗口")
    println("  cj-tauri build        # 仅构建")
    println("")
    println("提示: cjpm.toml 里的路径是本机绝对路径；换机器需重新执行 create 或手改这两处。")
    if (exists(joinPath(joinPath(targetDir, "ui"), "package.json"))) {
        println("")
        println("提示: 该模板前端用 Vite；首次 cj-tauri dev 会自动 npm install 并起 dev server")
        println("      （页面走 CJ_TAURI_DEV_URL，改 ui/src 下的前端源码不重启应用就能看到效果）。")
    }
    return 0
}
