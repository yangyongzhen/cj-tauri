/**
 * cj-tauri CLI 入口：create / dev / build / run / info / help
 */
package cli

func usage(): Unit {
    println("cj-tauri ${cliVersion()} — 仓颉版 Tauri CLI（脚手架 + 构建 + 运行）")
    println("")
    println("用法:")
    println("  cj-tauri create <项目名> [--template <t>] [--bundle <bundleName>] [--label <应用名>]")
    println("                             创建新项目（src/ + ui/ + capabilities/ + cjpm.toml）")
    println("                             模板: app（内联单文件，缺省）/ vue / react")
    println("                                   ohos（鸿蒙 PC / 2in1：ArkWeb 宿主 + build-hap.sh）")
    println("                             --bundle / --label 只对 ohos 模板有意义（缺省由项目名推导）")
    println("  cj-tauri dev               构建 C 桥 + cjpm build + 启动应用（鸿蒙工程改走 build-hap.sh）")
    println("  cj-tauri build             构建 C 桥 + cjpm build（鸿蒙工程 = 编 hap）")
    println("  cj-tauri run               运行已构建产物（鸿蒙工程 = 装到设备并拉起）")
    println("  cj-tauri info [--json]     环境自检（排障用）；--json 只输出插件清单（机器可读）")
    println("  cj-tauri doctor            环境自检逐行给结论（每条自带「缺了就怎么办」）")
    println("  cj-tauri check             校验 cj-tauri.toml（id/窗口/资产存在）+ targets 骨架漂移")
    println("  cj-tauri sync [desktop|ohos]  按清单派生 targets 骨架（缺省两端都派生）")
    println("  cj-tauri help              显示本帮助")
    println("")
    println("环境变量:")
    println("  CJ_TAURI_ROOT   框架仓库根目录（不在仓库内运行时必须设置）")
    println("  CANGJIE_HOME    仓颉 SDK 根目录（默认从 PATH 中的 cjc 反推）")
    println("  CANGJIE_STDX    stdx 动态库目录（默认从框架/项目 cjpm.toml 读取）")
    println("  CJ_TAURI_MANIFEST")
    println("                  仅由 cj-tauri info 设置（json / text）：应用装配完就打印清单并退出，")
    println("                  不创建窗口——无显示环境也能取到真实的插件装配结果")
    println("")
    println("示例:")
    println("  cd /tmp && cj-tauri create myapp && cd myapp && cj-tauri dev")
}

main(args: Array<String>): Int64 {
    if (args.size == 0) {
        usage()
        return 1
    }
    let sub = args[0]
    if (sub == "help" || sub == "-h" || sub == "--help") {
        usage()
        return 0
    }
    if (sub == "--version" || sub == "-V" || sub == "-v") {
        println("cj-tauri ${cliVersion()}")
        return 0
    }
    if (sub == "create") {
        var name = ""
        var tpl = "app"
        var bundle = ""
        var label = ""
        var i = 1
        while (i < args.size) {
            let a = args[i]
            if (a == "--template" || a == "-t") {
                if (i + 1 >= args.size) {
                    eprintln("用法: cj-tauri create <项目名> [--template app|vue|react|ohos]")
                    return 1
                }
                tpl = args[i + 1]
                i = i + 2
                continue
            }
            if (a == "--bundle") {
                if (i + 1 >= args.size) {
                    eprintln("用法: cj-tauri create <项目名> --template ohos [--bundle <bundleName>]")
                    return 1
                }
                bundle = args[i + 1]
                i = i + 2
                continue
            }
            if (a == "--label") {
                if (i + 1 >= args.size) {
                    eprintln("用法: cj-tauri create <项目名> --template ohos [--label <应用名>]")
                    return 1
                }
                label = args[i + 1]
                i = i + 2
                continue
            }
            if (name.size == 0) {
                name = a
            }
            i = i + 1
        }
        if (name.size == 0) {
            eprintln("用法: cj-tauri create <项目名> [--template app|vue|react|ohos]")
            return 1
        }
        return cmdCreate(name, tpl, bundle, label)
    }
    if (sub == "dev") {
        return cmdDev()
    }
    if (sub == "build") {
        return cmdBuild()
    }
    if (sub == "run") {
        return cmdRun()
    }
    if (sub == "info") {
        var asJson = false
        var i = 1
        while (i < args.size) {
            if (args[i] == "--json") {
                asJson = true
            }
            i = i + 1
        }
        return cmdInfo(asJson)
    }
    if (sub == "doctor") {
        return cmdDoctor()
    }
    if (sub == "check") {
        return cmdCheck()
    }
    if (sub == "sync") {
        return cmdSync(args)
    }
    eprintln("未知子命令: ${sub}")
    println("")
    usage()
    return 1
}
