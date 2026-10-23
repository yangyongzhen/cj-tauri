/**
 * cj-tauri.toml 清单（RFC-002 §3）：解析 + 校验 + 桌面骨架派生
 *
 * 批次 2 用受控 TOML 子集并手写解析（stdx 无 toml 模块，实测）；子集约定：
 *   - 段：[app] / [[windows]] / [assets] / [capabilities]，无嵌套表；
 *   - 值：带引号字符串、整数、true/false；引号值后不写行内注释（整行 # 注释不受限）；
 *   - 未知键直接报错：清单由本 CLI 生态生成与消费，拼错键要在 check 期暴露。
 */
package cli

import std.collection.*
import std.convert.*

/** [[windows]] 的一条声明（RFC §3） */
public class ManifestWindow {
    public var label: String = "main"
    public var title: String = ""
    public var width: Int64 = 1100
    public var height: Int64 = 720
    public var resizable: Bool = true
}

/** 清单内存模型；字段默认值即「最小清单」的缺省（RFC §3 约定值） */
public class Manifest {
    public var appId: String = ""
    public var name: String = ""
    public var version: String = ""
    public var icon: String = ""
    public var entry: String = "src/main.cj"
    public var pkg: String = ""      // 业务 cjpm 包名：sync 生成 launcher 的 import 用
    public var windows: ArrayList<ManifestWindow> = ArrayList<ManifestWindow>()
    public var assetsRoot: String = "assets"
    public var page: String = "ui/index.html"
    public var capabilitiesDir: String = "assets/capabilities"

    /** 可执行名：appId 最后一段 */
    public func exeName(): String {
        let parts = appId.split(".")
        if (parts.size == 0) {
            return "app"
        }
        return parts[parts.size - 1]
    }

    /** 主窗口：无 [[windows]] 时按 name 给默认窗 */
    public func mainWindow(): ManifestWindow {
        if (windows.size == 0) {
            let w = ManifestWindow()
            w.title = name
            return w
        }
        return windows.get(0).getOrThrow()
    }

    // ---------- 解析 ----------

    public static func fromToml(text: String, source: String): Manifest {
        let m = Manifest()
        var section = ""
        var lineNo: Int64 = 0
        for (raw in text.split("\n")) {
            lineNo += 1
            let trimmed = raw.trimAscii()
            if (trimmed.size == 0 || trimmed.startsWith("#")) {
                continue
            }
            if (trimmed.startsWith("[")) {
                section = trimmed.replace("[", "").replace("]", "").trimAscii()
                if (section == "windows") {
                    m.windows.add(ManifestWindow())
                }
                continue
            }
            let kv = trimmed.split("=")
            if (kv.size != 2) {
                throw IllegalArgumentException("${source}:${lineNo} 无法解析的行（应为 key = value）：${trimmed}")
            }
            try {
                m.apply(section, kv[0].trimAscii(), kv[1].trimAscii(), "${source}:${lineNo}")
            } catch (e: Exception) {
                throw IllegalArgumentException("${e.message}")
            }
        }
        return m
    }

    private func apply(section: String, key: String, value: String, at: String): Unit {
        if (section.size == 0) {
            throw IllegalArgumentException("${at}: 键出现在任何段之前：${key}")
        }
        if (section == "app") {
            match (key) {
                case "id" => this.appId = strValue(value, at)
                case "name" => this.name = strValue(value, at)
                case "version" => this.version = strValue(value, at)
                case "icon" => this.icon = strValue(value, at)
                case "entry" => this.entry = strValue(value, at)
                case "package" => this.pkg = strValue(value, at)
                case _ => throw IllegalArgumentException("${at}: 未知的 [app] 键：${key}")
            }
            return
        }
        if (section == "windows") {
            if (this.windows.size == 0) {
                this.windows.add(ManifestWindow())
            }
            let w = this.windows.get(this.windows.size - 1).getOrThrow()
            match (key) {
                case "label" => w.label = strValue(value, at)
                case "title" => w.title = strValue(value, at)
                case "width" => w.width = intValue(value, at)
                case "height" => w.height = intValue(value, at)
                case "resizable" => w.resizable = boolValue(value, at)
                case _ => throw IllegalArgumentException("${at}: 未知的 [[windows]] 键：${key}")
            }
            return
        }
        if (section == "assets") {
            match (key) {
                case "root" => this.assetsRoot = strValue(value, at)
                case "page" => this.page = strValue(value, at)
                case _ => throw IllegalArgumentException("${at}: 未知的 [assets] 键：${key}")
            }
            return
        }
        if (section == "capabilities") {
            match (key) {
                case "dir" => this.capabilitiesDir = strValue(value, at)
                case _ => throw IllegalArgumentException("${at}: 未知的 [capabilities] 键：${key}")
            }
            return
        }
        throw IllegalArgumentException("${at}: 未知段：[${section}]")
    }

    /** 引号值：取首个引号内内容（引号后的行内注释一并忽略）；裸值原样 */
    private static func strValue(raw: String, at: String): String {
        let v = raw.trimAscii()
        if (v.startsWith("\"")) {
            let parts = v.split("\"")
            if (parts.size < 3) {
                throw IllegalArgumentException("${at}: 引号值缺右引号：${v}")
            }
            return parts[1]
        }
        return v
    }

    private static func intValue(raw: String, at: String): Int64 {
        let v = raw.trimAscii()
        if (v.startsWith("\"")) {
            throw IllegalArgumentException("${at}: 应为整数，却是字符串：${v}")
        }
        let body = v.split("#")[0].trimAscii()
        try {
            return Int64.parse(body)
        } catch (e: Exception) {
            throw IllegalArgumentException("${at}: 不是整数：${body}")
        }
    }

    private static func boolValue(raw: String, at: String): Bool {
        let v = raw.trimAscii().split("#")[0].trimAscii()
        if (v == "true") {
            return true
        }
        if (v == "false") {
            return false
        }
        throw IllegalArgumentException("${at}: 应为 true/false：${v}")
    }

    // ---------- 校验 ----------

    /** 纯静态校验（不碰文件系统）；返回错误列表，空 = 通过。文件系统检查在 check 命令里 */
    public func validate(): ArrayList<String> {
        let errs = ArrayList<String>()
        if (this.appId.size == 0) {
            errs.add("[app] id 不能为空")
        } else {
            let segs = this.appId.split(".")
            if (segs.size < 2) {
                errs.add("[app] id 至少两段反向域名（如 com.example.music）：${this.appId}")
            }
            for (seg in segs) {
                if (seg.size == 0) {
                    errs.add("[app] id 的段不能为空：${this.appId}")
                    continue
                }
                var bad = false
                for (b in seg) {
                    let c = Int64(b)
                    if (!((c >= 48 && c <= 57) || (c >= 97 && c <= 122))) {
                        bad = true
                        break
                    }
                }
                if (bad) {
                    errs.add("[app] id 只允许小写字母与数字（段=${seg}）")
                }
            }
        }
        if (this.name.size == 0) {
            errs.add("[app] name 不能为空")
        }
        if (this.version.size == 0) {
            errs.add("[app] version 不能为空")
        }
        if (this.pkg.size == 0) {
            errs.add("[app] package 不能为空（sync 生成 launcher 的 import 需要）")
        }
        let labels = ArrayList<String>()
        for (w in this.windows) {
            if (w.label.size == 0) {
                errs.add("[[windows]] label 不能为空")
                continue
            }
            var dup = false
            for (seen in labels) {
                if (seen == w.label) {
                    dup = true
                    break
                }
            }
            if (dup) {
                errs.add("[[windows]] label 重复：${w.label}")
            } else {
                labels.add(w.label)
            }
            if (w.width <= 0 || w.height <= 0) {
                errs.add("[[windows]] ${w.label} 尺寸必须为正")
            }
        }
        if (this.page.size == 0) {
            errs.add("[assets] page 不能为空")
        }
        return errs
    }

    // ---------- 桌面骨架派生（RFC §7.1/§7.2；批次 2 仅 desktop） ----------

    /** targets/desktop/cjpm.toml；链接段照抄 examples/music 的既有配置（AGENTS：产物口径不变） */
    public func renderDesktopToml(fwRoot: String, cliVer: String): String {
        let native = fwRoot + "/native"
        return "// generated by cj-tauri sync (v" + cliVer + ") — 不要手改；改动会被 check 判为漂移\n" +
            "// 派生自 cj-tauri.toml：" + this.appId + "@" + this.version + "\n" +
            "[package]\n" +
            "  cjc-version = \"1.0.5\"\n" +
            "  name = \"" + this.exeName() + "\"\n" +
            "  description = \"generated desktop skeleton for " + this.appId + "\"\n" +
            "  version = \"" + this.version + "\"\n" +
            "  target-dir = \"\"\n" +
            "  output-type = \"executable\"\n" +
            "  compile-option = \"\"\n" +
            "  override-compile-option = \"\"\n" +
            "  link-option = \"\"\n" +
            "  package-configuration = {}\n" +
            "\n[dependencies]\n" +
            "  cjTauri = { path = \"" + fwRoot + "\" }\n" +
            "  " + this.pkg + " = { path = \"../..\" }\n" +
            "\n[target.x86_64-unknown-linux-gnu]\n" +
            "  link-option = \"-L" + native + " -lcjtbridge -lwebkit2gtk-4.1 -lgtk-3 -lgdk-3 -lglib-2.0 -lgio-2.0 -lsoup-3.0 -ljavascriptcoregtk-4.1 -lgobject-2.0\"\n" +
            "\n[target.x86_64-unknown-linux-gnu.bin-dependencies]\n" +
            "    path-option = [\"" + "$" + "{CANGJIE_STDX}\"]\n" +
            "\n[target.x86_64-w64-mingw32]\n" +
            "  link-option = \"-L" + native + " -lcjtbridge --subsystem=windows\"\n" +
            "\n[target.x86_64-w64-mingw32.bin-dependencies]\n" +
            "    path-option = [\"" + "$" + "{CANGJIE_STDX}\"]\n"
    }

    /** targets/desktop/src/main.cj：launcher 调业务装配点 build()（过渡契约，见 RFC §4.1 批次 2 说明） */
    public func renderDesktopMain(cliVer: String): String {
        let w = this.mainWindow()
        return "// generated by cj-tauri sync (v" + cliVer + ") — 不要手改；改动会被 check 判为漂移\n" +
            "// 桌面 launcher：调用业务装配点 " + this.pkg + ".build()（AppSpec/launch 随批次 3 落地后由 sync 重新生成）\n" +
            "import cjTauri.*\n" +
            "import " + this.pkg + ".*\n" +
            "\n" +
            "main(): Int64 {\n" +
            "    let app = build()\n" +
            "    app.assets(DirectoryAssetResolver(\"" + this.assetsRoot + "\"))\n" +
            "    app.window(WindowConfig(\"${w.title}\", ${w.width}, ${w.height}))\n" +
            "    app.run(PageSource.Asset(\"" + this.page + "\"))\n" +
            "    return 0\n" +
            "}\n"
    }
}
