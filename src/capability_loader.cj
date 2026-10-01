package cjTauri

import std.fs.*
import stdx.encoding.json.*

/**
 * capabilities 目录加载（对标 Tauri：自动扫描 capabilities 目录下的 json 清单）
 *
 * 约定：
 *   - 目录下所有 *.json 逐个解析为 Capability 并注册进 registry；
 *   - 单个文件损坏只告警，不影响其它文件；
 *   - 与 addCapabilityJson / addCapability 并存：显式挂载优先，注册表非空时不走自动扫描。
 */

/** 扫描目录下所有 *.json 清单，返回成功加载的条数（目录不存在返回 0） */
func loadCapabilitiesFromDir(dir: String, reg: CapabilityRegistry): Int64 {
    var loaded: Int64 = 0
    if (!exists(dir)) {
        return loaded
    }
    var entries: Array<FileInfo>
    try {
        entries = Directory.readFrom(dir)
    } catch (e: Exception) {
        eprintln("[cj-tauri] 读取 capability 目录失败 ${dir}: ${e}")
        return loaded
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
            eprintln("[cj-tauri] 读取 capability 失败 ${path}: ${e}")
            continue
        }
        try {
            if (reg.addFromJson(JsonValue.fromStr(text))) {
                loaded += 1
            } else {
                eprintln("[cj-tauri] capability 缺少 identifier，已跳过: ${path}")
            }
        } catch (e: Exception) {
            eprintln("[cj-tauri] capability JSON 解析失败 ${path}: ${e}")
        }
    }
    return loaded
}

/**
 * run() 时的自动加载：注册表为空且存在 capabilities/ 目录时扫描它。
 * 让 create 出来的工程不必自己读 JSON（对标 Tauri 的默认行为）。
 */
func autoLoadCapabilities(reg: CapabilityRegistry): Unit {
    if (reg.size() > 0) {
        return
    }
    let dir = "capabilities"
    if (!exists(dir)) {
        eprintln("[cj-tauri] 未挂载任何 capability，且没有 capabilities/ 目录")
        eprintln("[cj-tauri] 默认最小权限：未声明的命令与事件一律拒绝（见 docs/使用文档.md）")
        return
    }
    let n = loadCapabilitiesFromDir(dir, reg)
    if (n > 0) {
        eprintln("[cj-tauri] 已自动加载 capabilities/：${n} 个清单")
    } else {
        eprintln("[cj-tauri] capabilities/ 目录下没有可用的 *.json 清单")
    }
}
