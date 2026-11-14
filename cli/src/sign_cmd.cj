/**
 * `cj-tauri sign` 子命令：鸿蒙真机签名（体检 / 写回 / 登录 AGC / 全自动现签）。
 *
 * 用法：
 *   cj-tauri sign                     签名体检：能不能装、缺什么、下一步是什么（离线，免账号）
 *   cj-tauri sign --apply             离线写回：把本机匹配 UDID+包名的现成材料写进
 *                                     targets/ohos/build-profile.json5（免账号）
 *   cj-tauri sign --login             浏览器登录 AGC 一次，令牌加密落盘（~/.cj-tauri/sign/）
 *   cj-tauri sign --auto [--newKeys]  全自动：注册设备 → 材料 → 证书 → profile → 写回
 *   cj-tauri sign --json              体检结果按 JSON 输出（机器可读）
 *
 * 在线部分仅 --login / --auto；--check / --apply 纯离线。
 */

package cli

import std.collection.*
import std.fs.*
import std.process.*
import stdx.encoding.json.*

/** 有损 UTF-8：非法序列按 U+FFFD 替换（子进程输出解码用） */
func lenientUtf8(bytes: Array<Byte>): String {
    let out = ArrayList<UInt8>()
    var i: Int64 = 0
    let n = Int64(bytes.size)
    while (i < n) {
        let b = Int64(bytes[i])
        var need: Int64 = 0
        var cp: Int64 = 0
        if (b < 0x80) {
            out.add(bytes[i])
            i += 1
            continue
        } else if ((b & 0xE0) == 0xC0) {
            need = 1
            cp = b & 0x1F
        } else if ((b & 0xF0) == 0xE0) {
            need = 2
            cp = b & 0x0F
        } else if ((b & 0xF8) == 0xF0) {
            need = 3
            cp = b & 0x07
        } else {
            out.add(all: [0xEF, 0xBF, 0xBD])
            i += 1
            continue
        }
        if (i + need >= n) {
            out.add(all: [0xEF, 0xBF, 0xBD])
            i += 1
            continue
        }
        var ok = true
        var k: Int64 = 1
        while (k <= need) {
            let c = Int64(bytes[i + k])
            if ((c & 0xC0) != 0x80) {
                ok = false
                break
            }
            cp = (cp << 6) | (c & 0x3F)
            k += 1
        }
        if (!ok) {
            out.add(all: [0xEF, 0xBF, 0xBD])
            i += 1
            continue
        }
        for (m in 0..(need + 1)) {
            out.add(bytes[i + m])
        }
        i = i + need + 1
    }
    return String.fromUtf8(out.toArray())
}

/** 从工程目录收集签名体检/写回需要的事实 */
public class SignProjectInfo {
    public var projectRoot: String = ""
    public var bundleName: String = ""
    public var product: String = "default"
    public var buildProfile: String = ""
    public var hdcPath: String = ""
    public var error: String = ""
}

/**
 * 定位鸿蒙工程的三要素：targets/ohos 目录、AppScope/app.json5 的 bundleName、
 * build-profile.json5、hdc 可执行文件。找不到时带原因返回。
 */
public func signCollectProject(projectRoot: String): SignProjectInfo {
    let info = SignProjectInfo()
    var root = projectRoot
    if (root == "") {
        root = "targets/ohos"
    }
    if (!exists(Path(root))) {
        info.error = "鸿蒙工程目录不存在：${root}（先跑 `cj-tauri sync ohos` 派生骨架）"
        return info
    }
    info.projectRoot = root
    // bundleName
    let appJson5 = "${root}/AppScope/app.json5"
    if (!exists(Path(appJson5))) {
        info.error = "找不到 ${appJson5}"
        return info
    }
    let appText = String.fromUtf8(File.readFrom(appJson5))
    info.bundleName = json5ValueAfter(appText, "bundleName")
    if (info.bundleName == "") {
        info.error = "${appJson5} 里读不到 bundleName"
        return info
    }
    // build-profile.json5
    let bp = "${root}/build-profile.json5"
    if (!exists(Path(bp))) {
        info.error = "找不到 ${bp}"
        return info
    }
    info.buildProfile = bp
    // product 名（读 products[].name，缺省 default）
    let bpText = String.fromUtf8(File.readFrom(bp))
    let prod = json5ValueAfter(bpText, "name")
    if (prod != "" && prod != "default") {
        info.product = prod
    }
    // hdc：环境变量 → PATH → DevEco 默认位置
    info.hdcPath = signFirstExistingEnv(["HDC_PATH", "OHOS_HDC"])
    if (info.hdcPath == "") {
        let deveco = signFirstExistingEnv(["DEVECO_SDK_HOME", "OHOS_HOME", "DEVECO_HOME"])
        var candidates = ArrayList<String>()
        if (deveco != "") {
            if (deveco.endsWith("openharmony") || deveco.contains("openharmony")) {
                candidates.add("${deveco}/toolchains/hdc.exe")
                candidates.add("${deveco}/toolchains/hdc")
            }
            candidates.add("${deveco}/default/openharmony/toolchains/hdc.exe")
            candidates.add("${deveco}/default/openharmony/toolchains/hdc")
        }
        for (c in candidates) {
            if (exists(Path(c))) {
                info.hdcPath = c
                break
            }
        }
    }
    if (info.hdcPath == "") {
        // 交给 PATH（报错时提示怎么修）
        info.hdcPath = "hdc"
    }
    return info
}

/** 签名体检：能不能装、缺什么、下一步（离线，免账号） */
public func cmdSignCheck(proj: SignProjectInfo, asJson: Bool): Int64 {
    let udid = deviceUdidViaHdc(proj.hdcPath)
    let configDir = ohosConfigDir()
    let cands = discoverProfiles(configDir)
    // 工程自己的配置
    var hasConfig = false
    var filesExist = false
    var allowsDevice = false
    var profileType = ""
    var projProfileText = ""
    if (proj.buildProfile != "" && exists(Path(proj.buildProfile))) {
        let text = String.fromUtf8(File.readFrom(proj.buildProfile))
        let s = parseProjSigning(text)
        hasConfig = s.hasSigningConfigs
        if (hasConfig) {
            let m = signingMaterialOf(text)
            filesExist = exists(Path(m.storeFile)) && exists(Path(m.profile)) &&
                exists(Path(m.certpath))
            if (exists(Path(m.profile))) {
                try {
                    projProfileText = extractProfileJson(
                        signLatin1Of(File.readFrom(m.profile)))
                } catch (e: Exception) {
                    let _ = e
                }
                let p = parseOhosProfile(projProfileText, m.profile)
                profileType = p.profileType
                allowsDevice = p.allows(udid)
            }
        }
    }
    let check = judgeSign(hasConfig, filesExist, allowsDevice, profileType, udid,
        pickProfile(cands, udid, proj.bundleName).isSome())
    // 包名门槛：仅在"需要走候选材料"的路径上叠判
    if (!check.ok && (hasConfig == false || filesExist == false)) {
        check.bundleMatch = false
        for (p in cands) {
            if (p.allows(udid) && bundleMatches(proj.bundleName, p.bundleName)) {
                check.bundleMatch = true
                break
            }
        }
        if (!check.bundleMatch) {
            let census = profileBundleCensus(cands, udid)
            check.reason = "${check.reason}；且本机没有「含本机 UDID 且包名为 ${proj.bundleName}」的材料"
            check.nextStep = "跑 `cj-tauri sign --login` + `sign --auto` 为这个包名现签一份；" +
                "本机现有材料：${census}"
        }
    }
    if (asJson) {
        var o = check.toJson()
        o.put("bundleName", JsonString(proj.bundleName))
        o.put("projectRoot", JsonString(proj.projectRoot))
        println(o.toJsonString())
        if (check.ok) {
            return 0
        }
        return 1
    }
    println("[sign] 工程根: ${proj.projectRoot}")
    println("[sign] 包名: ${proj.bundleName}")
    println("[sign] 设备 UDID: ${if (udid == "") { "（取不到）" } else { udid }}")
    println("[sign] 结论: ${if (check.ok) { "可直装" } else { "装不上" }}")
    if (!check.ok) {
        println("[sign] 原因: ${check.reason}")
    }
    println("[sign] 下一步: ${check.nextStep}")
    if (check.ok) {
        return 0
    }
    return 1
}

/** 离线写回：把本机匹配 UDID+包名的现成材料写进 build-profile.json5 */
public func cmdSignApply(proj: SignProjectInfo): Int64 {
    let udid = deviceUdidViaHdc(proj.hdcPath)
    let configDir = ohosConfigDir()
    let cands = discoverProfiles(configDir)
    match (pickProfile(cands, udid, proj.bundleName)) {
        case Some(p) =>
            let (p12, cer) = ("${p.p7bPath[0..(p.p7bPath.size - 4)]}.p12",
                "${p.p7bPath[0..(p.p7bPath.size - 4)]}.cer")
            if (!exists(Path(p12)) || !exists(Path(cer))) {
                eprintln("[sign] 候选材料缺文件：${p12} / ${cer}")
                return 1
            }
            // 口令密文优先取 donor 工程（同名 .p12 的工程）里现成的；没有就自己造
            var storePwd = ""
            var keyPwd = ""
            // 1) 找 ~/.ohos/config 同目录 json5？没有这个约定 → 从 material/ 自己造不出来
            //    （明文口令只存在于生成它的那一次），所以这里只能沿用「已有工程写回过的密文」：
            //    扫描本仓 examples/*/targets/ohos/build-profile.json5 找同一 .p12 的 donor。
            let (dp12, dkey) = signScavengeDonorCiphertexts(p12)
            if (dp12 != "" && dkey != "") {
                storePwd = dp12
                keyPwd = dkey
                println("[sign] 沿用 donor 工程的口令密文（同一 .p12）")
            } else {
                let (workKey, wkErr) = loadWorkKey(materialDirOfConfig(configDir))
                if (wkErr != "") {
                    eprintln("[sign] 读 material/ 失败：${wkErr}")
                    eprintln("[sign] 没有可沿用的口令密文，请跑 `cj-tauri sign --login` + `sign --auto` 生成一套新材料")
                    return 1
                }
                // 密文造不出来（明文口令不可知）→ 如实说明
                let _ = workKey
                eprintln("[sign] 候选材料的明文口令不可知（它只在生成那一次存在过），离线写回做不了")
                eprintln("[sign] 请跑 `cj-tauri sign --login` + `cj-tauri sign --auto` 生成一套自己掌口令的新材料")
                return 1
            }
            let m = SigningMaterial()
            m.storeFile = p12
            m.certpath = cer
            m.profile = p.p7bPath
            m.storePassword = storePwd
            m.keyPassword = keyPwd
            let origin = String.fromUtf8(File.readFrom(proj.buildProfile))
            let (newText, err) = if (parseProjSigning(origin).hasSigningConfigs) {
                replaceOwnSigningConfigs(origin, m)
            } else {
                applySigningConfig(origin, m)
            }
            if (err != "") {
                eprintln("[sign] 写回失败：${err}")
                return 1
            }
            let bak = "${proj.buildProfile}.cj-tauri-apply.bak"
            File.writeTo(bak, origin.toArray())
            File.writeTo(proj.buildProfile, newText.toArray())
            println("[sign] 已写回 ${proj.buildProfile}（备份：${bak}）")
            println("[sign] profile: ${p.p7bPath}")
            println("[sign] 下一步: hvigor assembleHap → hdc install -r → aa start")
            return 0
        case None =>
            eprintln("[sign] 本机没有「含本机 UDID 且包名为 ${proj.bundleName}」的材料")
            eprintln("[sign] 本机现有：${profileBundleCensus(cands, udid)}")
            eprintln("[sign] 请跑 `cj-tauri sign --login` + `cj-tauri sign --auto` 为这个包名现签一份")
            return 1
    }
}

/**
 * 扫描本仓 examples 下各工程 build-profile.json5，找与目标 .p12 **同名**的 donor，
 * 搬它的口令密文（同一套材料 → 密文通用，搬家安全）。
 */
func signScavengeDonorCiphertexts(targetP12: String): (String, String) {
    let roots = [".", "..", "../..", "../../..", "../../../.."]
    for (r in roots) {
        let base = "${r}/examples"
        if (!exists(Path(base))) {
            continue
        }
        var entries: Array<FileInfo>
        try {
            entries = Directory.readFrom(Path(base))
        } catch (e: Exception) {
            let _ = e
            continue
        }
        for (e in entries) {
            if (!e.isDirectory()) {
                continue
            }
            for (sub in ["targets/ohos", "."]) {
                let bp = "${base}/${e.name}/${sub}/build-profile.json5"
                if (!exists(Path(bp))) {
                    continue
                }
                try {
                    let text = String.fromUtf8(File.readFrom(bp))
                    let m = signingMaterialOf(text)
                    if (m.storePassword != "" && m.keyPassword != "" &&
                        sameMaterialFile(m.storeFile, targetP12)) {
                        return (m.storePassword, m.keyPassword)
                    }
                } catch (ex: Exception) {
                    let _ = ex
                }
            }
        }
    }
    return ("", "")
}

/** `sign` 子命令入口 */
public func cmdSign(args: Array<String>): Int64 {
    var doLogin = false
    var doAuto = false
    var doApply = false
    var asJson = false
    var forceNewKeys = false
    var projectRoot = ""
    var i = 1
    while (i < args.size) {
        let a = args[i]
        if (a == "--login") {
            doLogin = true
        } else if (a == "--auto") {
            doAuto = true
        } else if (a == "--apply") {
            doApply = true
        } else if (a == "--json") {
            asJson = true
        } else if (a == "--newKeys") {
            forceNewKeys = true
        } else if (a == "--path") {
            if (i + 1 >= args.size) {
                eprintln("用法: --path <ohos 工程目录>（缺省 targets/ohos）")
                return 1
            }
            projectRoot = args[i + 1]
            i = i + 2
            continue
        } else {
            eprintln("未知选项: ${a}")
            return 1
        }
        i += 1
    }
    let proj = signCollectProject(projectRoot)
    if (proj.error != "") {
        eprintln("[sign] ${proj.error}")
        return 1
    }
    if (doLogin) {
        let r = agcLogin(300, true)
        if (!r.ok) {
            eprintln("[sign] 登录失败：${r.error}")
            return 1
        }
        println("[sign] 登录成功：${r.userName}（团队 ${r.teamCount} 个，默认 ${r.teamName}）")
        println("[sign] 令牌已加密落盘 ~/.cj-tauri/sign/token.enc（约 4 小时后过期）")
        return 0
    }
    if (doAuto) {
        var token: AgcLoginOutcome
        match (loadAgcToken()) {
            case Some(t) => token = t
            case None =>
                eprintln("[sign] 没有可用令牌（或已过期）：先跑 `cj-tauri sign --login` 完成一次浏览器授权")
                return 1
        }
        let inp = AutoSignInput()
        inp.configDir = ohosConfigDir()
        inp.projectRoot = proj.projectRoot
        inp.bundleName = proj.bundleName
        inp.buildProfile = proj.buildProfile
        inp.product = proj.product
        inp.forceNewKeys = forceNewKeys
        // UDID 与设备类型
        let udid = deviceUdidViaHdc(proj.hdcPath)
        if (udid == "") {
            eprintln("[sign] 拿不到设备 UDID（设备没连？）")
            return 1
        }
        inp.udid = udid
        try {
            let (code, out, _) = executeWithOutput(proj.hdcPath,
                ["shell", "getprop", "hw_sc.build.os.deviceType"])
            if (code == 0) {
                inp.deviceType = signDeviceTypeOf(lenientUtf8(out))
            }
        } catch (e: Exception) {
            let _ = e
            inp.deviceType = "4"
        }
        let outcome = autoSign(inp, token)
        if (asJson) {
            println(outcome.toJson().toJsonString())
        } else {
            for (s in outcome.steps) {
                println("[sign] ${s}")
            }
            if (outcome.error != "") {
                eprintln("[sign] 失败：${outcome.error}")
            } else {
                println("[sign] 完成。下一步: hvigor assembleHap → hdc install -r → aa start")
            }
        }
        if (outcome.ok) {
            return 0
        }
        return 1
    }
    if (doApply) {
        return cmdSignApply(proj)
    }
    return cmdSignCheck(proj, asJson)
}
