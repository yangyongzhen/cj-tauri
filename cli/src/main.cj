/**
 * cj-tauri CLI 入口：create / dev / build / run / info / help
 */
package cli

func usage(): Unit {
    println("cj-tauri ${cliVersion()} — 仓颉版 Tauri CLI（脚手架 + 构建 + 运行）")
    println("")
    println("用法:")
    println("  cj-tauri create <项目名>   创建新项目（src/ + ui/ + capabilities/ + cjpm.toml）")
    println("  cj-tauri dev               构建 C 桥 + cjpm build + 启动应用")
    println("  cj-tauri build             构建 C 桥 + cjpm build")
    println("  cj-tauri run               运行已构建产物")
    println("  cj-tauri info              环境自检（排障用）")
    println("  cj-tauri help              显示本帮助")
    println("")
    println("环境变量:")
    println("  CJ_TAURI_ROOT   框架仓库根目录（不在仓库内运行时必须设置）")
    println("  CANGJIE_HOME    仓颉 SDK 根目录（默认从 PATH 中的 cjc 反推）")
    println("  CANGJIE_STDX    stdx 动态库目录（默认从框架/项目 cjpm.toml 读取）")
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
        if (args.size < 2) {
            eprintln("用法: cj-tauri create <项目名>")
            return 1
        }
        return cmdCreate(args[1])
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
        return cmdInfo()
    }
    eprintln("未知子命令: ${sub}")
    println("")
    usage()
    return 1
}
