package cjTauri

/**
 * 内嵌资源释放（单文件包专用）。
 *
 * 背景：应用产物可以打成**单个 exe**（`scripts/pack-win-single.sh`），页面 / 能力清单 / vendor JS
 * 都编成字符串，但**随包的外部程序**（例如 cjnote 的 cjh 后端）没法静态链接进 exe，只能作为 PE
 * 资源（RT_RCDATA）跟着走；运行期由本函数取出写盘，应用再按得到的路径去起它。
 *
 * `dir` 由调用方给（框架不认识应用名），典型是 `%LOCALAPPDATA%\<应用名>\runtime`；
 * **调用方负责先把目录建好**（桥只建最后一级）。
 *
 * 返回值：> 0 = 就绪的文件数（本次释放的 + 本来就在的）；0 = 这个产物里没有内嵌资源
 * （普通构建就是这样，**不是错误**）；-1 = 参数为空或写盘失败（原因在 stderr）。
 * 幂等：目标已在且大小与资源一致时桥会跳过，所以每次启动都可以调。
 */
public func extractEmbeddedAssets(dir: String): Int64 {
    if (dir.isEmpty()) {
        eprintln("[cj-tauri] extractEmbeddedAssets: 目录为空")
        return -1
    }
    let n = extractAssetsBridge(dir)
    if (n < 0) {
        eprintln("[cj-tauri] 释放内嵌资源失败：${dir}")
    }
    return n
}

/**
 * 鸿蒙侧没有 C 桥产物（`native/platforms/harmonyos/` 目前只有契约），照桌面那份写声明会让模块
 * 加载期就 SIGSEGV（与 `log_bridge.cj` / `process_hidden.cj` 同一条坑，AGENTS §4）——按 `env` 分叉，
 * 如实降级。判据用 `env` 而不是 `arch`：桌面 aarch64 Linux 也有 C 桥。
 */
@When[env != "ohos"]
@C
foreign func cj_bridge_extract_assets(dir: CString): Int32

@When[env != "ohos"]
func extractAssetsBridge(dir: String): Int64 {
    var n: Int32 = 0
    unsafe {
        n = cj_bridge_extract_assets(LibC.mallocCString(dir))
    }
    return Int64(n)
}

@When[env == "ohos"]
func extractAssetsBridge(dir: String): Int64 {
    let _ = dir
    eprintln("[cj-tauri] 本平台没有 C 桥，无内嵌资源可释放")
    return 0
}

/**
 * 按**绝对路径**预加载一个随包释放出来的动态库（单文件包专用）。
 *
 * 为什么需要它（2026-10-21 实测，另一台机器）：仓颉运行时的随机数默认实现走 OpenSSL，而它按
 * **裸名**找 `libcrypto-3-x64.dll` / `libssl-3-x64.dll`——SDK 与 stdx 都不带这两个，开发机上只是
 * 恰好命中 PATH 里 Git 自带的那份。于是同一条 `ws://` 连接线，本机全通、别人双击就挂：
 * `ws: connect failed: Can not load openssl library or function RAND_bytes.`
 * （RFC6455 升级要算 `Sec-WebSocket-Key` 的随机 nonce，**明文 ws 也逃不掉**）。
 *
 * 只要进程内先按绝对路径加载一次，之后同类裸名加载就命中已加载模块：不必改 PATH，
 * 也不必把 DLL 摆到 exe 旁边（单文件承诺不破）。
 *
 * `path` 必须是释放后的真实路径；返回 true = 已在进程内（含本来就在的）。
 * 平台没有 C 桥时如实返回 false（`src/log_bridge.cj` 同款门禁）。
 */
public func preloadEmbeddedLibrary(path: String): Bool {
    if (path.isEmpty()) {
        eprintln("[cj-tauri] preloadEmbeddedLibrary: 路径为空")
        return false
    }
    let ok = preloadLibraryBridge(path)
    if (!ok) {
        eprintln("[cj-tauri] 预加载动态库失败：${path}")
    }
    return ok
}

@When[env != "ohos"]
@C
foreign func cj_bridge_preload_library(path: CString): Int32

@When[env != "ohos"]
func preloadLibraryBridge(path: String): Bool {
    var ok: Int32 = 0
    unsafe {
        ok = cj_bridge_preload_library(LibC.mallocCString(path))
    }
    return ok == 1
}

@When[env == "ohos"]
func preloadLibraryBridge(path: String): Bool {
    let _ = path
    return false
}
