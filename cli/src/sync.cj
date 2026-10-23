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
    if (failed) {
        eprintln("[cj-tauri] check 未通过：${m.appId}@${m.version}")
        return 1
    }
    println("[cj-tauri] check 通过：${m.appId}@${m.version}（${m.name}）")
    return 0
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
