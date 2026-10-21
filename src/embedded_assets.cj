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
