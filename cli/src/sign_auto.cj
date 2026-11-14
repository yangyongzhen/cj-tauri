/**
 * `cj-tauri sign --auto` 编排：登录令牌 → 团队 → 设备 → 本地密钥/CSR → 云端证书 →
 * profile → 口令加密 → 写回 build-profile.json5。
 *
 * 七步每步失败都带步骤号与人话原因（跑完了但不知道哪步没做，比失败更糟）。
 * 私钥永不上云：本地生成密钥对与 CSR，再拿 CSR 去 AGC 换证书。
 */

package cli

import std.collection.*
import std.crypto.digest.*
import std.fs.*
import std.process.*
import stdx.crypto.digest.*
import stdx.encoding.json.*

/** 编排结果 */
public class AutoSignOutcome {
    public var ok: Bool = false
    /** 逐步日志（一行一步） */
    public var steps: ArrayList<String> = ArrayList<String>()
    public var error: String = ""
    public var teamId: String = ""
    public var certName: String = ""
    public var certId: String = ""
    public var p12Path: String = ""
    public var csrPath: String = ""
    public var cerPath: String = ""
    public var p7bPath: String = ""
    public var buildProfile: String = ""
    public var backup: String = ""
    /** 是否本次新生成了密钥（false = 复用本地已有 p12） */
    public var generatedKeys: Bool = false
    /** 口令长度（只回长度，绝不回明文） */
    public var passwordLen: Int64 = 0

    public func add(s: String): Unit {
        this.steps.add(s)
    }

    public func toJson(): JsonObject {
        var o = JsonObject()
        o.put("ok", JsonBool(this.ok))
        o.put("error", JsonString(this.error))
        var arr = JsonArray()
        for (s in this.steps) {
            arr.add(JsonString(s))
        }
        o.put("steps", arr)
        o.put("teamId", JsonString(this.teamId))
        o.put("certName", JsonString(this.certName))
        o.put("certId", JsonString(this.certId))
        o.put("p12", JsonString(this.p12Path))
        o.put("csr", JsonString(this.csrPath))
        o.put("cer", JsonString(this.cerPath))
        o.put("p7b", JsonString(this.p7bPath))
        o.put("buildProfile", JsonString(this.buildProfile))
        o.put("backup", JsonString(this.backup))
        o.put("generatedKeys", JsonBool(this.generatedKeys))
        o.put("passwordLen", JsonInt(this.passwordLen))
        return o
    }
}

/** 一次自动签名的输入 */
public class AutoSignInput {
    /** ~/.ohos/config */
    public var configDir: String = ""
    /** product 名（通常是 default） */
    public var product: String = "default"
    /** DevEco 眼中的"工程根"（前向斜杠由内部归一） */
    public var projectRoot: String = ""
    /** 工程的 bundleName（AppScope/app.json5） */
    public var bundleName: String = ""
    /** 工程 build-profile.json5 路径 */
    public var buildProfile: String = ""
    /** 本机 UDID（大写） */
    public var udid: String = ""
    /** hw_sc.build.os.deviceType 解析出的设备类型码 */
    public var deviceType: String = "4"
    /** 云端 profile 是否保留（默认 false：下载完就删，省配额） */
    public var keepProvision: Bool = false
    /**
     * 丢弃本地旧材料、重新生成密钥对（并把云端那张同名证书换成绑新公钥的）。
     * 材料是拷来的 / material/ 重建过时，.p12 的口令没人知道（密文解不开）→
     * hvigor 报 00303242，这时唯一干净的路是换一套自己能掌握口令的材料。
     */
    public var forceNewKeys: Bool = false
}

/** 读现有 build-profile 里的两段口令密文（复用旧 p12 时沿用） */
func signExistingCiphertexts(buildProfile: String): (String, String) {
    if (buildProfile == "" || !exists(Path(buildProfile))) {
        return ("", "")
    }
    try {
        let m = signingMaterialOf(String.fromUtf8(File.readFrom(buildProfile)))
        return (m.storePassword, m.keyPassword)
    } catch (e: Exception) {
        let _ = e
        return ("", "")
    }
}

/** 把材料写回 build-profile.json5（先留 .bak） */
func signWriteBack(out: AutoSignOutcome, inp: AutoSignInput, m: SigningMaterial): AutoSignOutcome {
    if (inp.buildProfile == "" || !exists(Path(inp.buildProfile))) {
        out.error = "⑦ 找不到 build-profile.json5（${inp.buildProfile}）"
        return out
    }
    out.buildProfile = inp.buildProfile
    try {
        let origin = String.fromUtf8(File.readFrom(inp.buildProfile))
        // 已有配置：同一套材料（同一个 .p12）就地更新（.p7b/.cer 会因证书换发而变）；
        // 别的材料一律不动，报错让人决定
        let (newText, err) = if (parseProjSigning(origin).hasSigningConfigs) {
            replaceOwnSigningConfigs(origin, m)
        } else {
            applySigningConfig(origin, m)
        }
        if (err != "") {
            out.error = "⑦ 写回失败：${err}"
            return out
        }
        let bak = "${inp.buildProfile}.cj-tauri-autosign.bak"
        File.writeTo(bak, origin.toArray())
        File.writeTo(inp.buildProfile, newText.toArray())
        out.backup = bak
        out.add("⑦ 已写回 signingConfigs（备份：${bak}）")
        out.ok = true
        return out
    } catch (e: Exception) {
        out.error = "⑦ 写盘失败：${e}"
        return out
    }
}

/**
 * 让本地 .cer 与刚下载的 profile 里的开发证书是同一张（证书以云端为准，本地 .cer 只是缓存）。
 * 不一致时按 certObjectId 重下一次（旧文件改名留底），再核一次；重下仍不一致说明
 * 云端那张证书不是当前 .p12 这把钥匙签的，只能 --newKeys。
 */
func signEnsureCerMatchesProfile(out: AutoSignOutcome, token: AgcLoginOutcome, teamId: String,
    cert: AgcCert): (Bool, String) {
    var cerText = ""
    try {
        if (exists(Path(out.cerPath))) {
            cerText = String.fromUtf8(File.readFrom(out.cerPath))
        }
    } catch (e: Exception) {
        return (false, "读本地证书失败：${e}")
    }
    if (cerText == "") {
        return (false, "本地没有证书文件（${out.cerPath}）")
    }
    var devPem = ""
    try {
        if (exists(Path(out.p7bPath))) {
            devPem = signProfileDevCertPemOf(extractProfileJson(String.fromUtf8(File.readFrom(out.p7bPath))))
        }
    } catch (e: Exception) {
        let _ = e
        devPem = ""
    }
    if (devPem == "") {
        // 读不出就不拦：证书格式一变更不该让整条链全红（宁可真机那一步再说话）
        return (true, "profile 里读不出开发证书，跳过证书一致性自检")
    }
    if (signCerHasCertOf(cerText, devPem)) {
        return (true, "本地 .cer 与 profile 是同一张开发证书")
    }
    let bak = "${out.cerPath}.cj-tauri-stale-${signNowMs()}"
    try {
        File.writeTo(bak, cerText.toArray())
    } catch (e: Exception) {
        return (false, "备份旧证书失败：${e}")
    }
    let objectRef = if (cert.certObjectId != "") { cert.certObjectId } else { cert.id }
    let (saved, dlErr) = agcDownloadObject(token.accessToken, token.userId, teamId, objectRef,
        out.cerPath)
    if (dlErr != "") {
        return (false, "本地 .cer 是旧证书且重下失败（${dlErr}）——装到真机会被 9568322 拒")
    }
    var fresh = ""
    try {
        fresh = String.fromUtf8(File.readFrom(out.cerPath))
    } catch (e: Exception) {
        return (false, "重下后读不出证书：${e}")
    }
    if (!signCerHasCertOf(fresh, devPem)) {
        return (false, "本地 .cer 与 profile 不是同一张证书，重下后仍不一致（旧文件已备份到 ${bak}）——" +
            "云端那张证书不是当前 .p12 这把钥匙签的，用 `sign --auto --newKeys` 重生成密钥对再签")
    }
    return (true, "本地 .cer 是旧证书，已按云端重下：${saved}")
}

/**
 * 抽出 PEM 文本里所有证书块并规范化（去掉换行与行内空白）。
 * 同一张证书在不同文件里换行位置可能不同，直接字符串比较会假红；
 * 而 .cer 是一条链（顺序是 根 → 中间 → 开发者），只谈"链里有没有这张"。
 */
public func signPemCertBlocksOf(text: String): ArrayList<String> {
    let blocks = ArrayList<String>()
    let begin = "-----BEGIN CERTIFICATE-----"
    let endMark = "-----END CERTIFICATE-----"
    var from: Int64 = 0
    var go = true
    while (go) {
        match (text.indexOf(begin, from)) {
            case Some(s) =>
                match (text.indexOf(endMark, s + begin.size)) {
                    case Some(e) =>
                        let norm = signSquashWhitespaceOf(text[(s + begin.size)..e])
                        if (norm != "") {
                            blocks.add(norm)
                        }
                        from = e + endMark.size
                    case None => go = false
                }
            case None => go = false
        }
    }
    return blocks
}

/** 去掉所有空白字节，用于证书正文比较 */
func signSquashWhitespaceOf(s: String): String {
    let bytes = s.toArray()
    let acc = ArrayList<Byte>()
    for (b in bytes) {
        if (b == 32 || b == 9 || b == 10 || b == 13) {
            continue
        }
        acc.add(b)
    }
    return String.fromUtf8(acc.toArray())
}

/**
 * 取 profile JSON 里 bundle-info.development-certificate 的证书正文（已规范化）。
 * profile 里的证书是一行带 \n 转义的长 base64；取值后必须交回 signPemCertBlocksOf
 * 再解析一次，否则一边是链里的块体、一边是带 BEGIN/END 标记的整段，比较口径不一致。
 */
public func signProfileDevCertPemOf(profileJson: String): String {
    let key = "\"development-certificate\""
    match (profileJson.indexOf(key)) {
        case Some(k) =>
            match (profileJson.indexOf("\"", k + key.size)) {
                case Some(q) =>
                    let bytes = profileJson.toArray()
                    let acc = ArrayList<Byte>()
                    var i = q + 1
                    var esc = false
                    while (i < bytes.size) {
                        let c = bytes[i]
                        if (esc) {
                            esc = false
                            // \n / \r / \t 还原成真空白；其余转义保留字符本身
                            if (c == 110) {
                                acc.add(10)
                            } else if (c == 114) {
                                acc.add(13)
                            } else if (c == 116) {
                                acc.add(9)
                            } else {
                                acc.add(c)
                            }
                        } else if (c == 92) {
                            esc = true
                        } else if (c == 34) {
                            break
                        } else {
                            acc.add(c)
                        }
                        i++
                    }
                    let blocks = signPemCertBlocksOf(String.fromUtf8(acc.toArray()))
                    if (blocks.size == 0) {
                        return ""
                    }
                    return blocks[0]
                case None => return ""
            }
        case None => return ""
    }
}

/** 本地 .cer（证书链）里是否含这张证书（纯函数） */
public func signCerHasCertOf(cerText: String, pem: String): Bool {
    if (pem == "") {
        return false
    }
    for (b in signPemCertBlocksOf(cerText)) {
        if (b == pem) {
            return true
        }
    }
    return false
}

/**
 * 跑完整条编排（需要已登录的令牌）。
 * token 里必须带 accessToken / userId（teamId 缺时这里会重新拉）。
 */
public func autoSign(inp: AutoSignInput, token: AgcLoginOutcome): AutoSignOutcome {
    let out = AutoSignOutcome()
    // ---------------- ① 令牌 ----------------
    if (token.accessToken == "" || token.userId == "") {
        out.error = "没有可用的登录令牌：先跑 `cj-tauri sign --login` 完成一次浏览器授权"
        return out
    }
    var teamId = token.teamId
    if (teamId == "") {
        // UDID 可能注册在非默认团队里：profile 按团队签发，必须选对团队。
        // 先逐团队查设备列表，挑含本机 UDID 的；都不含再用第一个团队去注册。
        let (teams, tErr) = agcTeamListAll(token.accessToken, token.userId)
        if (tErr != "") {
            out.error = "拉团队列表失败（token 可能已失效，重跑 `cj-tauri sign --login`）：${tErr}"
            return out
        }
        if (teams.size == 0) {
            out.error = "账号下没有团队"
            return out
        }
        var picked: Option<AgcTeam> = None
        for (t in teams) {
            let (devices, _) = agcDeviceList(token.accessToken, token.userId, t.id)
            if (deviceRegistered(devices, inp.udid)) {
                picked = Some(t)
                out.add("② 团队：设备已注册在 ${t.name}（${t.id}），用它签")
                break
            }
        }
        match (picked) {
            case Some(t) =>
                teamId = t.id
            case None =>
                teamId = teams[0].id
                out.add("② 团队：没有任何团队含本机设备，用第一个 ${teams[0].name}（${teamId}）去注册")
        }
    } else {
        out.add("② 团队：用令牌里的 ${token.teamName}（${teamId}）")
    }
    out.teamId = teamId
    // ---------------- ③ 设备 ----------------
    let (devOK, devMsg) = agcEnsureDevice(token.accessToken, token.userId, teamId, inp.udid,
        inp.deviceType)
    out.add("③ 设备：${devMsg}")
    if (!devOK) {
        out.error = devMsg
        return out
    }
    // ---------------- ④ 材料命名与本地密钥 ----------------
    let base = signingFileBaseName(inp.product, inp.projectRoot)
    // 四种材料同一个前缀（<base>=）：后面凡是拼路径都必须走它，
    // 手抄模板漏掉那个 = 就会得到"看着像、其实不存在"的路径。
    let matPrefix = "${inp.configDir}/${base}="
    out.p12Path = "${matPrefix}.p12"
    out.csrPath = "${matPrefix}.csr"
    out.cerPath = "${matPrefix}.cer"
    out.p7bPath = "${matPrefix}.p7b"
    out.add("④ 材料路径（DevEco 同名规则）：${base}=.{p12,csr,cer,p7b}")
    // java / hap-sign-tool 位置（只在需要生成/申请证书时用）
    let javaHome = signEnvOf("JAVA_HOME")
    let devecoHome = signFirstExistingEnv(["DEVECO_HOME", "DEVECO_SDK_HOME"])
    let sdkHome = signFirstExistingEnv(["DEVECO_SDK_HOME", "OHOS_HOME"])
    // DEVECO_SDK_HOME 没设时按 DEVECO_HOME/sdk 推导（DevEco 6.x 的实际布局）
    var jarHome = sdkHome
    if (jarHome == "" && devecoHome != "") {
        let guess = signHostPathOf("${devecoHome}/sdk")
        if (exists(Path(guess))) {
            jarHome = guess
        }
    }
    let javaPath = signJavaCandidates(javaHome, devecoHome)
    var javaExe = signFirstExisting(javaPath)
    if (javaExe == "") {
        javaExe = "java"        // 交给 PATH，失败会在 signRunSignTool 里带回错误
    }
    let jar = signFirstExisting(signHapSignToolCandidates(jarHome))
    var password = ""
    // 先把旧材料挪开（改名不删：私钥不可再生，留一份可回退）
    if (inp.forceNewKeys) {
        for (suffix in [".p12", ".csr", ".cer", ".p7b"]) {
            let p = matPrefix + suffix
            if (!exists(Path(p))) {
                continue
            }
            let dst = "${p}.cj-tauri-bak-${signNowMs()}"
            try {
                File.writeTo(dst, File.readFrom(p))
                remove(Path(p))
                out.add("④ 旧材料已改名留底：${signFileNameOf(dst)}")
            } catch (e: Exception) {
                out.error = "④ 挪开旧材料失败（${p}）：${e}"
                return out
            }
        }
    }
    if (!exists(Path(out.p12Path))) {
        if (jar == "") {
            out.error = "本地没有 ${out.p12Path}，且找不到 hap-sign-tool.jar（设 DEVECO_SDK_HOME）"
            return out
        }
        password = randomPasswordAlnum()
        let kp = signGenKeypair(javaExe, jar, out.p12Path, password, signTempDir())
        if (!kp.ok) {
            out.error = "④ 生成密钥对失败：${kp.error}"
            return out
        }
        out.generatedKeys = true
        out.passwordLen = Int64(password.size)
        out.add("④ 生成密钥对：${out.p12Path}（口令 ${password.size} 位，未落日志）")
        let csr = signGenCsr(javaExe, jar, out.p12Path, password, out.csrPath, signTempDir())
        if (!csr.ok) {
            out.error = "④ 生成 CSR 失败：${csr.error}"
            return out
        }
        out.add("④ 生成 CSR：${out.csrPath}")
    } else {
        out.add("④ 复用本地已有密钥：${out.p12Path}")
    }
    // ---------------- ⑤ 证书 ----------------
    let certName = certNameFor(teamId)
    out.certName = certName
    let (certs, certErr) = agcCertList(token.accessToken, token.userId, teamId)
    if (certErr != "") {
        out.error = "⑤ ${certErr}"
        return out
    }
    out.add("⑤ 云端已有证书 ${certs.size} 张，按名字找 ${certName}")
    var cert = AgcCert()
    // 新建证书时必须重下本地 .cer：本地那份对应的是旧证书（多半已过期）
    var freshCert = false
    // 刚生成了新密钥对 → 云端那张同名证书绑的是旧公钥，必须换一张
    if (out.generatedKeys) {
        match (findCertByName(certs, certName)) {
            case Some(old) =>
                let oldIds = ArrayList<String>()
                oldIds.add(old.id)
                let (delOK, delNote) = agcCertDelete(token.accessToken, token.userId, teamId, oldIds)
                out.add("⑤ 旧证书绑的是旧密钥，先换掉：${delNote}")
                if (!delOK) {
                    out.error = "⑤ ${delNote}"
                    return out
                }
            case None => ()
        }
    }
    var reusable: Option<AgcCert> = None
    if (!out.generatedKeys) {
        reusable = findUsableCert(certs, certName)
    }
    match (reusable) {
        case Some(c) =>
            cert = c
            out.add("⑤ 复用证书：${certName}（id=${cert.id}）")
        case None =>
            if (!exists(Path(out.csrPath))) {
                out.error = "⑤ 云端没有可用的 ${certName}，本地也没有 CSR 可用来新建（删掉 p12 让它重生）"
                return out
            }
            var csrText = ""
            try {
                csrText = String.fromUtf8(File.readFrom(out.csrPath))
            } catch (e: Exception) {
                out.error = "⑤ 读 CSR 失败：${e}"
                return out
            }
            // AGC 证书数量有上限，过期的照样占位 → 先把自己的过期自动签名证书删掉腾位置
            let stale = staleCertsOf(certs)
            if (stale.size > 0) {
                let ids = ArrayList<String>()
                for (s in stale) {
                    ids.add(s.id)
                    out.add("⑤ 过期证书占位：${s.certName}（id=${s.id}，到期 ${s.expireMs}）")
                }
                let (ok, note) = agcCertDelete(token.accessToken, token.userId, teamId, ids)
                out.add("⑤ ${note}")
                if (!ok) {
                    out.error = "⑤ ${note}（可以登录 AGC 控制台手动删除过期证书后重试）"
                    return out
                }
            }
            let (newCert, addErr) = agcCertAdd(token.accessToken, token.userId, teamId, csrText,
                certName, "1")       // 1 = debug 证书
            if (addErr != "") {
                out.error = "⑤ ${addErr}"
                return out
            }
            cert = newCert
            freshCert = true
            out.add("⑤ 新建证书：${certName}（id=${cert.id}）")
    }
    out.certId = cert.id
    out.add("⑤ 证书对象：id=${cert.id} objectId=${cert.certObjectId}")
    if (cert.id == "") {
        out.error = "⑤ 证书没有 id，无法申请 profile"
        return out
    }
    // 本地 .cer：没有（或刚换了新证书）就按 certObjectId 下载
    if (freshCert || !exists(Path(out.cerPath))) {
        let objectRef = if (cert.certObjectId != "") { cert.certObjectId } else { cert.id }
        let (saved, dlErr) = agcDownloadObject(token.accessToken, token.userId, teamId, objectRef,
            out.cerPath)
        if (dlErr != "") {
            out.error = "⑤ 下载证书失败：${dlErr}"
            return out
        }
        out.add("⑤ 下载证书：${saved}")
    } else {
        out.add("⑤ 复用本地证书文件：${out.cerPath}")
    }
    // ---------------- ⑥ profile ----------------
    // deviceList 要的是云端设备 id（不是 UDID）：UDID 是 64 位十六进制，
    // AGC 对元素长度有限制（≤32），直接传 UDID 会被拒（实测踩到）
    let (cloudDevices, devErr) = agcDeviceList(token.accessToken, token.userId, teamId)
    if (devErr != "") {
        out.error = "⑥ 拉设备列表失败：${devErr}"
        return out
    }
    let deviceIds = ArrayList<String>()
    for (d in cloudDevices) {
        if (d.id != "") {
            deviceIds.add(d.id)
        }
    }
    if (deviceIds.size == 0) {
        out.error = "⑥ 云端没有已注册设备（先跑设备注册，或检查 UDID 是否在团队里）"
        return out
    }
    out.add("⑥ 云端设备 id ${deviceIds.size} 个（用它申请 profile，不是 UDID）")
    let (p7b, provNote) = agcProvisionDebug(token.accessToken, token.userId, teamId, cert.id,
        inp.bundleName, inp.product, deviceIds, ArrayList<String>(), out.p7bPath)
    if (p7b == "") {
        out.error = "⑥ ${provNote}"
        return out
    }
    out.add("⑥ profile：${provNote}")
    out.add("⑥ 落盘：${out.p7bPath}")
    // 证书-配置一致性自检：profile 里绑定的开发证书，必须是本地 .cer 里那张
    let (cerOK, cerNote) = signEnsureCerMatchesProfile(out, token, teamId, cert)
    out.add("⑥ ${cerNote}")
    if (!cerOK) {
        out.error = "⑥ ${cerNote}"
        return out
    }
    // ---------------- ⑦ 写 build-profile ----------------
    let (workKey, wkErr) = loadWorkKey(materialDirOfConfig(inp.configDir))
    if (wkErr != "") {
        out.error = "⑦ 读 material/ 失败：${wkErr}"
        return out
    }
    if (password == "") {
        // 复用旧 p12 时拿不到明文口令 → 只能沿用现有密文；没有现有密文就报错
        let (storePwd, keyPwd) = signExistingCiphertexts(inp.buildProfile)
        if (storePwd == "" || keyPwd == "") {
            out.error = "⑦ 复用现有 p12 但工程里没有可沿用的口令密文（删掉 p12 让它重新生成）"
            return out
        }
        let m = SigningMaterial()
        m.storeFile = out.p12Path
        m.certpath = out.cerPath
        m.profile = out.p7bPath
        m.storePassword = storePwd
        m.keyPassword = keyPwd
        return signWriteBack(out, inp, m)
    }
    let (storePwd, e1) = encryptPasswordHex(workKey, password)
    if (e1 != "") {
        out.error = "⑦ 加密 storePassword 失败：${e1}"
        return out
    }
    let (keyPwd, e2) = encryptPasswordHex(workKey, password)
    if (e2 != "") {
        out.error = "⑦ 加密 keyPassword 失败：${e2}"
        return out
    }
    let m = SigningMaterial()
    m.storeFile = out.p12Path
    m.certpath = out.cerPath
    m.profile = out.p7bPath
    m.storePassword = storePwd
    m.keyPassword = keyPwd
    return signWriteBack(out, inp, m)
}
