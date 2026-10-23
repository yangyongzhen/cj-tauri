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

    /**
     * 骨架模块名（cjpm [package] name）：默认 exeName（appId 最后一段）；与业务包名
     * （清单 package = 仓颉包名）撞名时加 _app 后缀。cjpm 强制两条约束（批次 3-PR2 实测）：
     * ① 每个工程的 toml 模块名 == 其源文件包名（music：toml `music_app` ↔ `package music_app`）；
     * ② 依赖树内模块名唯一。业务包名被 ① 钉死为 package，最常见的命名
     * com.example.<pkg> + package = <pkg> 必然撞 ②，撞时骨架模块名为 <pkg>_app。
     * 二进制名与模块名无关：cjpm 可执行工程恒输出 target/release/bin/main。
     */
    public func skeletonName(): String {
        if (this.exeName() == this.pkg) {
            return this.exeName() + "_app"
        }
        return this.exeName()
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
                // 段须字母开头、只含小写字母/数字/下划线——同时满足 Tauri identifier 习惯与
                // 鸿蒙 bundleName 规范（bundleNameFrom 会给 my-app 这类名字生成 pr4_app 段，
                // 下划线是鸿蒙侧的合法字符，不能禁）
                var bad = false
                for (i in 0..seg.size) {
                    let c = Int64(seg.toArray()[i])
                    if (i == 0) {
                        if (c < 97 || c > 122) {
                            bad = true
                            break
                        }
                    } else if (!((c >= 48 && c <= 57) || (c >= 97 && c <= 122) || c == 95)) {
                        bad = true
                        break
                    }
                }
                if (bad) {
                    errs.add("[app] id 的段须字母开头、只含小写字母/数字/下划线（段=${seg}）")
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
        let native = toTomlPath(fwRoot) + "/native"
        // TOML 注释只认 '#'（'//' 是仓颉/C 风格，cjpm 的解析器会当场拒绝），指纹头与 .cj 生成物同款但换字符
        return "# generated by cj-tauri sync (v" + cliVer + ") — 不要手改；改动会被 check 判为漂移\n" +
            "# 派生自 cj-tauri.toml：" + this.appId + "@" + this.version + "\n" +
            "[package]\n" +
            "  cjc-version = \"1.0.5\"\n" +
            "  name = \"" + this.skeletonName() + "\"\n" +
            "  description = \"generated desktop skeleton for " + this.appId + "\"\n" +
            "  version = \"" + this.version + "\"\n" +
            "  target-dir = \"\"\n" +
            "  output-type = \"executable\"\n" +
            "  compile-option = \"\"\n" +
            "  override-compile-option = \"\"\n" +
            "  link-option = \"\"\n" +
            "  package-configuration = {}\n" +
            "\n[dependencies]\n" +
            "  cjTauri = { path = \"" + toTomlPath(fwRoot) + "\" }\n" +
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

    /** targets/desktop/src/main.cj：launcher 调业务装配点 build()（批次 3，RFC §4.1/§4.2） */
    public func renderDesktopMain(cliVer: String): String {
        let w = this.mainWindow()
        return "// generated by cj-tauri sync (v" + cliVer + ") — 不要手改；改动会被 check 判为漂移\n" +
            "// 桌面 launcher：页面/窗口/资产/能力目录由清单派生；业务装配点 " + this.pkg + ".build()（RFC §4.1/§4.2）\n" +
            "package " + this.skeletonName() + "\n" +
            "\n" +
            "import cjTauri.*\n" +
            "import cjTauri.platform.*\n" +
            "import " + this.pkg + ".*\n" +
            "\n" +
            "main(): Int64 {\n" +
            "    let spec = build()\n" +
            "        .page(PageSource.Asset(\"" + this.page + "\"))\n" +
            "        .window(WindowConfig(\"${w.title}\", ${w.width}, ${w.height}))\n" +
            "        .assets(DirectoryAssetResolver(\"" + this.assetsRoot + "\"))\n" +
            "        .capabilities(\"" + this.capabilitiesDir + "\")\n" +
            "    launch(spec)\n" +
            "    return 0\n" +
            "}\n"
    }

    // ---------- ohos 骨架派生（RFC §7.1/§7.3；批次 3-PR3） ----------
    // 生成策略：ohos-skeleton 模板 copyTree 整体拷渲染（静态物 + 图标），4 个清单派生文件用下列
    // 渲染器覆盖——check 的漂移检测复用同一批渲染器，生成与校验天然一致。

    /** 生成物里要写字面 `${X}`：仓颉源码中 ${} 是插值，只能拼接出来 */
    private static func interp(name: String): String {
        return "$" + "{" + name + "}"
    }

    /** targets/ohos/AppScope/app.json5：bundleName=id、vendor=name、versionName=version 全部清单派生 */
    public func renderOhosAppJson(cliVer: String): String {
        return "// generated by cj-tauri sync (v" + cliVer + ") — 不要手改；改动会被 check 判为漂移\n" +
            "{\n" +
            "  \"app\": {\n" +
            "    /* bundleName 是应用在设备上的唯一 ID：两个应用写同一个 bundleName 会互相覆盖安装。\n" +
            "       改它必须重新签名——DevEco 的「自动签名」会按新包名重新申请 profile。\n" +
            "       取值来自清单 [app] id（sync 保证与清单一致）。 */\n" +
            "    \"bundleName\": \"" + this.appId + "\",\n" +
            "    \"vendor\": \"" + this.name + "\",\n" +
            "    \"versionCode\": 1000000,\n" +
            "    \"versionName\": \"" + this.version + "\",\n" +
            "    \"buildVersion\": \"1\",\n" +
            "    \"icon\": \"$media:layered_image\",\n" +
            "    \"label\": \"$string:app_name\"\n" +
            "  }\n" +
            "}\n"
    }

    /**
     * targets/ohos/entry/cjpm.toml：dynamic 入口模块
     *
     * 与模板的差异：① 业务包路径依赖（../../.. = 工程根，业务代码只有一份——RFC §7.3）；
     * ② version 随清单；③ 框架路径绝对化（本机口径，与 create 同规矩）。
     * 模块名恒为 ohos_app_cangjie_entry（module.json5 的 srcEntry 钉死，不参与清单命名）。
     */
    public func renderOhosEntryToml(fwRoot: String, cliVer: String): String {
        let dc = Manifest.interp("DEVECO_CANGJIE_HOME")
        let dn = Manifest.interp("DEVECO_OH_NATIVE_HOME")
        let ce = Manifest.interp("COMPILE_CONDITION_ENTRY")
        let a1 = Manifest.interp("AARCH64_LIBS")
        let a2 = Manifest.interp("AARCH64_MACRO_LIBS")
        let a3 = Manifest.interp("AARCH64_KIT_LIBS")
        let x1 = Manifest.interp("X86_64_OHOS_LIBS")
        let x2 = Manifest.interp("X86_64_OHOS_MACRO_LIBS")
        let x3 = Manifest.interp("X86_64_OHOS_KIT_LIBS")
        return "# generated by cj-tauri sync (v" + cliVer + ") — 不要手改；改动会被 check 判为漂移\n" +
            "[package]\n" +
            "  cjc-version = \"1.1.3\"\n" +
            "  compile-option = \"--dy-std --cfg=\\\"" + ce + "\\\"\"\n" +
            "  description = \"" + this.name + " - cj-tauri 鸿蒙入口 module\"\n" +
            "  name = \"ohos_app_cangjie_entry\"\n" +
            "  output-type = \"dynamic\"\n" +
            "  src-dir = \"./src/main/cangjie\"\n" +
            "  target-dir = \"\"\n" +
            "  version = \"" + this.version + "\"\n" +
            "\n[dependencies]\n" +
            "  # 源码依赖：hvigor 的 CompileCangjie 会把框架各包按本模块（dynamic）需要的形态编进来。\n" +
            "  # 路径是本机绝对路径；换机器 / 挪仓库后重跑 cj-tauri sync ohos（与 create 同一条规矩）。\n" +
            "  cjTauri = { path = \"" + toTomlPath(fwRoot) + "\" }\n" +
            "  # 业务包：业务代码的唯一真相在工程根（RFC §7.3——骨架永不复制业务代码、不改包名）\n" +
            "  " + this.pkg + " = { path = \"../../..\" }\n" +
            "\n[profile]\n" +
            "  [profile.build]\n" +
            "    incremental = true\n" +
            "    lto = \"\"\n" +
            "  [profile.customized-option]\n" +
            "    debug = \"-g -Woff all -Won apilevel-check\"\n" +
            "    release = \"--fast-math -O2 -s -Woff all -Won apilevel-check\"\n" +
            "  [profile.test]\n" +
            "\n[target.aarch64-linux-ohos]\n" +
            "  compile-option = \"-B \\\"" + dc + "/build-tools/third_party/llvm/bin\\\" -B \\\"" + dn + "/sysroot/usr/lib/aarch64-linux-ohos\\\" -L \\\"" + dn + "/sysroot/usr/lib/aarch64-linux-ohos\\\" -L \\\"" + dn + "/llvm/lib/clang/15.0.4/lib/aarch64-linux-ohos\\\" -L \\\"" + dn + "/llvm/lib/aarch64-linux-ohos\\\" --sysroot \\\"" + dn + "/sysroot\\\"\"\n" +
            "[target.aarch64-linux-ohos.bin-dependencies]\n" +
            "  # 鸿蒙版 stdx：相对路径指向骨架根上的 `stdx` 联接（build-hap.sh 用 CANGJIE_STDX_OHOS\n" +
            "  # 建，不入库）。hvigor 只替换它自己的模板变量，写别的 " + "$" + "{...}" + " 会变空串、整条\n" +
            "  # path-option 失效（模板里的实测教训，原样保留）。\n" +
            "  path-option = [\"" + a1 + "\", \"" + a2 + "\", \"" + a3 + "\", \"../stdx\"]\n" +
            "  package-option = {}\n" +
            "\n[target.x86_64-linux-ohos]\n" +
            "  compile-option = \"-B \\\"" + dc + "/build-tools/third_party/llvm/bin\\\" -B \\\"" + dn + "/sysroot/usr/lib/x86_64-linux-ohos\\\" -L \\\"" + dn + "/sysroot/usr/lib/x86_64-linux-ohos\\\" -L \\\"" + dn + "/llvm/lib/clang/15.0.4/lib/x86_64-linux-ohos\\\" -L \\\"" + dn + "/llvm/lib/x86_64-linux-ohos\\\" --sysroot \\\"" + dn + "/sysroot\\\"\"\n" +
            "[target.x86_64-linux-ohos.bin-dependencies]\n" +
            "  path-option = [\"" + x1 + "\", \"" + x2 + "\", \"" + x3 + "\", \"../stdx\"]\n" +
            "  package-option = {}\n"
    }

    /**
     * targets/ohos/entry/src/main/cangjie/app_host.cj：鸿蒙侧框架装配（L0 胶水）
     *
     * 业务装配点 build() 三端共用（零平台知识，RFC §4.1）；胶水层职责：
     * ① 沙箱目录（ArkWebRuntime.configure）② rawfile 资产解析器 ③ 能力清单挂载 ④ launchWith(mobile)。
     * 能力文件名单来自清单 [capabilities] 目录（sync 枚举后逐个渲染）。
     */
    public func renderOhosAppHost(cliVer: String, capsFiles: ArrayList<String>): String {
        var capsBlock = ""
        if (capsFiles.size == 0) {
            capsBlock = "    Hilog.info(1, \"CjTauri\", \"清单没有 [capabilities] 目录：未挂载能力清单（命令会如实被拒）\")\n"
        } else {
            var k: Int64 = 0
            for (f in capsFiles) {
                let varName = "caps" + k.toString()
                capsBlock = capsBlock +
                    "    let " + varName + " = readRawText(rm, \"capabilities/" + f + "\")\n" +
                    "    if (" + varName + ".size > 0) {\n" +
                    "        spec.capabilityJson(" + varName + ")\n" +
                    "    } else {\n" +
                    "        Hilog.info(1, \"CjTauri\", \"rawfile/capabilities/" + f + " 读不到（构建时打进 hap 了吗？）：命令会被全部拒绝\")\n" +
                    "    }\n"
                k += 1
            }
        }
        return "// generated by cj-tauri sync (v" + cliVer + ") — 不要手改；改动会被 check 判为漂移\n" +
            "// 鸿蒙侧框架装配（批次 3-PR3，RFC §4.2/§4.6.5）：业务装配点 " + this.pkg + ".build() 三端共用\n" +
            "package ohos_app_cangjie_entry\n" +
            "\n" +
            "import kit.PerformanceAnalysisKit.Hilog\n" +
            "import cjTauri.*\n" +
            "import cjTauri.platform.*\n" +
            "import " + this.pkg + ".*\n" +
            "import ohos.resource_manager.*\n" +
            "\n" +
            "/**\n" +
            " * rawfile 资产解析器（L0，RFC §6.2）：hap 里没有工程目录，Asset 只能从 rawfile 解析。\n" +
            " * 与桌面 DirectoryAssetResolver 同形：以「能否读到」为准，失败 = None（host_arkweb 在其上如实报错）。\n" +
            " */\n" +
            "class RawfileAssetResolver <: AssetResolver {\n" +
            "    private let rm: ResourceManager\n" +
            "\n" +
            "    public init(rm: ResourceManager) {\n" +
            "        this.rm = rm\n" +
            "    }\n" +
            "\n" +
            "    public func readText(name: String): Option<String> {\n" +
            "        try {\n" +
            "            return Some(String.fromUtf8(this.rm.getRawFileContent(name)))\n" +
            "        } catch (e: Exception) {\n" +
            "            return None\n" +
            "        }\n" +
            "    }\n" +
            "\n" +
            "    public func exists(name: String): Bool {\n" +
            "        return readText(name).isSome()\n" +
            "    }\n" +
            "}\n" +
            "\n" +
            "/** 读 hap 里的 rawfile（失败返回空串并打一行 hilog；调用方按「空 = 没有」降级，不让异常冒到生命周期） */\n" +
            "func readRawText(rm: ResourceManager, path: String): String {\n" +
            "    try {\n" +
            "        return String.fromUtf8(rm.getRawFileContent(path))\n" +
            "    } catch (e: Exception) {\n" +
            "        Hilog.info(1, \"CjTauri\", \"rawfile " + "$" + "{path} 读取失败: " + "$" + "{e}\")\n" +
            "        return \"\"\n" +
            "    }\n" +
            "}\n" +
            "\n" +
            "/**\n" +
            " * 装配并运行框架应用（非 UI 线程调用；run() 阻塞到 quit()）\n" +
            " *\n" +
            " * 页面取清单 [assets] page（sync 生成时已校验存在）；能力清单是构建期拷进 hap 的\n" +
            " * rawfile/capabilities 下的各份 json——文件名单是清单侧的真相，由生成器逐个渲染。\n" +
            " */\n" +
            "public func startApp(filesDir: String, rm: ResourceManager): Unit {\n" +
            "    Hilog.info(1, \"CjTauri\", \"startApp begin (ohos skeleton, business = " + this.pkg + ".build())\")\n" +
            "    // 沙箱目录要在 load 之前给定：宿主把页面落沙箱再以 file:// 加载（与桌面 load(source) 同一契约）\n" +
            "    ArkWebRuntime.configure(filesDir)\n" +
            "    let spec = build()\n" +
            "        .page(PageSource.Asset(\"" + this.page + "\"))\n" +
            "        .assets(RawfileAssetResolver(rm))\n" +
            capsBlock +
            "    launchWith(spec, Platform.mobile(filesDir, \"unknown\"))\n" +
            "    Hilog.info(1, \"CjTauri\", \"after run\")\n" +
            "}\n"
    }

    /**
     * targets/ohos/entry/src/main/cangjie/main_ability.cj：UIAbility（只管生命周期，装配在 app_host.cj）
     *
     * registerSelf / waitAndLogHost / 不碰窗口尺寸 这些段落原样取自 ohos-skeleton 模板——模板已真机验证。
     */
    public func renderOhosMainAbility(cliVer: String): String {
        return "// generated by cj-tauri sync (v" + cliVer + ") — 不要手改；改动会被 check 判为漂移\n" +
            "// 鸿蒙 UIAbility（批次 3-PR3，RFC §4.2）：本类只管生命周期；装配在非 UI 线程的 startApp（见 app_host.cj）\n" +
            "package ohos_app_cangjie_entry\n" +
            "\n" +
            "import kit.PerformanceAnalysisKit.Hilog\n" +
            "import kit.AbilityKit.Want\n" +
            "import kit.AbilityKit.UIAbility\n" +
            "import kit.AbilityKit.LaunchParam\n" +
            "import kit.ArkUI.WindowStage\n" +
            "import cjTauri.*\n" +
            "\n" +
            "class MainAbility <: UIAbility {\n" +
            "    public init() {\n" +
            "        super()\n" +
            "        registerSelf()\n" +
            "    }\n" +
            "\n" +
            "    public override func onCreate(want: Want, launchParam: LaunchParam): Unit {\n" +
            "        Hilog.info(1, \"CjTauri\", \"MainAbility OnCreated." + "$" + "{want.abilityName}\")\n" +
            "        // run() 会阻塞到 quit()，只能在非 UI 线程上跑——UI 线程要留给 ArkUI 建树。\n" +
            "        // 沙箱准备、rawfile 材化、框架装配都在 startApp 里完成（L0 胶水，见 app_host.cj）。\n" +
            "        let filesDir = \"" + "$" + "{this.context.filesDir}\"\n" +
            "        let rm = this.context.resourceManager\n" +
            "        let _ = spawn { startApp(filesDir, rm) }\n" +
            "    }\n" +
            "\n" +
            "    public override func onWindowStageCreate(windowStage: WindowStage): Unit {\n" +
            "        Hilog.info(1, \"CjTauri\", \"MainAbility onWindowStageCreate.\")\n" +
            "        // 等框架把宿主登记上再建树：组件的 build() 只有在该 label 有宿主、页面地址非空时\n" +
            "        // 才渲染 `Web`。等不到也照常 loadContent——页面会自己报桥缺失，比静默白屏好排查。\n" +
            "        this.waitAndLogHost(DEFAULT_WINDOW_LABEL)\n" +
            "        windowStage.loadContent(\"EntryView\")\n" +
            "    }\n" +
            "\n" +
            "    /**\n" +
            "     * 有界等待（3s）默认窗口的宿主登记完成，并把页面地址 / 预执行脚本条数打进 hilog\n" +
            "     *\n" +
            "     * 白屏定位用：宿主把页面落盘后的 file:// 地址必须非空，否则组件拿不到 src。\n" +
            "     */\n" +
            "    private func waitAndLogHost(label: String): Unit {\n" +
            "        var polls = 0\n" +
            "        while (polls < 300) {\n" +
            "            match (ArkWebRuntime.hostFor(label)) {\n" +
            "                case Some(_) => break\n" +
            "                case None => ()\n" +
            "            }\n" +
            "            sleep(Duration.millisecond * 10)\n" +
            "            polls += 1\n" +
            "        }\n" +
            "        if (polls >= 300) {\n" +
            "            Hilog.info(1, \"CjTauri\", \"host not registered in 3s: label=" + "$" + "{label}\")\n" +
            "            return\n" +
            "        }\n" +
            "        Hilog.info(1, \"CjTauri\", \"host registered after " + "$" + "{polls} polls label=" + "$" + "{label}\")\n" +
            "        match (ArkWebRuntime.hostFor(label)) {\n" +
            "            case Some(h) =>\n" +
            "                Hilog.info(1, \"CjTauri\", \"host pageUrl label=" + "$" + "{label} url=\\\"" + "$" + "{h.currentUrl()}\\\"\")\n" +
            "                Hilog.info(1, \"CjTauri\", \"host initScripts label=" + "$" + "{label} count=" + "$" + "{h.initScriptsSnapshot().size}\")\n" +
            "            case None => Hilog.info(1, \"CjTauri\", \"host missing at loadContent label=" + "$" + "{label}\")\n" +
            "        }\n" +
            "    }\n" +
            "}\n"
    }
}
