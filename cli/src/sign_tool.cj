/**
 * hap-sign-tool.jar 的定位与调用。
 *
 * 私钥永远不上云：本地生成密钥对与 CSR，再拿 CSR 去 AGC 换证书——这是 DevEco/ark-cli/flutter
 * 共同的做法。三个"照抄才不会跑偏"的点：
 *   ① jar 与 java 的位置有多档候选（SDK 的 toolchains/lib、数字版本目录、DevEco 自带 JBR）；
 *   ② generate-keypair 没有 -outFile（写进 keystore），generate-csr 才有；
 *   ③ 口令是随机的字母数字（8 随机字节 → base64url → 去掉 -_=），才能安全当命令行参数，
 *      而且日志里必须打码——口令进了日志就等于泄漏。
 */

package cli

import std.collection.*
import std.fs.*
import std.process.*

/** 默认的密钥参数（与 DevEco 一致，别改） */
public let SIGN_KEY_ALIAS: String = "debugKey"
public let SIGN_KEY_ALG: String = "ECC"
public let SIGN_KEY_SIZE: String = "NIST-P-256"
public let SIGN_CSR_SUBJECT: String = "CN=DebugKey"
public let SIGN_ALG: String = "SHA256withECDSA"

/** 8 随机字节 → base64url（去 -_=）→ 纯字母数字口令（7~10 位，与 flutter 的 generateRandomPwd 同规则） */
public func randomPasswordAlnum(): String {
    let raw = b64UrlNoPad(signRandomBytes(8))
    let out = ArrayList<Byte>()
    for (b in raw.toArray()) {
        if (b == 45 || b == 95 || b == 61) {     // - _ =
            continue
        }
        out.add(b)
    }
    return String.fromUtf8(out.toArray())
}

/** java 可执行文件的候选路径（JAVA_HOME → DevEco JBR → PATH 里的裸名） */
public func signJavaCandidates(javaHome: String, devecoHome: String): ArrayList<String> {
    let out = ArrayList<String>()
    if (javaHome.trimAscii() != "") {
        out.add(signHostPathOf("${javaHome.trimAscii()}/bin/java.exe"))
        out.add(signHostPathOf("${javaHome.trimAscii()}/bin/java"))
    }
    if (devecoHome.trimAscii() != "") {
        // DevEco 自带 JetBrains Runtime（JBR）；两个常见目录都试
        out.add(signHostPathOf("${devecoHome.trimAscii()}/jbr/bin/java.exe"))
        out.add(signHostPathOf("${devecoHome.trimAscii()}/jre/bin/java.exe"))
    }
    out.add("java")          // 走 PATH（找不到会执行失败，错误会如实回传）
    return out
}

/**
 * hap-sign-tool.jar 的候选路径（按 flutter 的三档顺序）：
 *   ① {sdk}/default/openharmony/toolchains/lib/hap-sign-tool.jar
 *   ② {sdk}/openharmony/toolchains/lib/hap-sign-tool.jar
 *   ③ 带版本号的 SDK 目录（{sdk}/{数字版本}/openharmony/toolchains/lib/...），版本降序
 */
public func signHapSignToolCandidates(sdkHome: String): ArrayList<String> {
    let out = ArrayList<String>()
    let sdk = sdkHome.trimAscii()
    if (sdk == "") {
        return out
    }
    out.add(signHostPathOf("${sdk}/default/openharmony/toolchains/lib/hap-sign-tool.jar"))
    out.add(signHostPathOf("${sdk}/openharmony/toolchains/lib/hap-sign-tool.jar"))
    // 数字版本目录：挑形如 6.1.1(24) / 5.0.0 的名字，按字符串降序（够用）
    let versions = ArrayList<String>()
    try {
        for (info in Directory.readFrom(Path(sdk))) {
            if (!info.isDirectory()) {
                continue
            }
            let n = info.name
            if (n.size > 0 && n.toArray()[0] >= 48 && n.toArray()[0] <= 57) {
                versions.add(n)
            }
        }
    } catch (e: Exception) {
        let _ = e
    }
    var list = versions.toArray()
    // 简单降序（版本目录个数很少，插入排序足够）
    var i: Int64 = 1
    while (i < Int64(list.size)) {
        let cur = list[i]
        var j = i - 1
        while (j >= 0 && list[j] < cur) {
            list[j + 1] = list[j]
            j -= 1
        }
        list[j + 1] = cur
        i += 1
    }
    for (v in list) {
        out.add(signHostPathOf("${sdk}/${v}/openharmony/toolchains/lib/hap-sign-tool.jar"))
        out.add(signHostPathOf("${sdk}/${v}/default/openharmony/toolchains/lib/hap-sign-tool.jar"))
    }
    return out
}

/** 返回第一个真实存在的候选（裸名 "java" 跳过存在性判断） */
public func signFirstExisting(candidates: ArrayList<String>): String {
    for (c in candidates) {
        if (c == "java") {
            continue
        }
        if (exists(Path(c))) {
            return c
        }
    }
    return ""
}

/** generate-keypair 的完整参数（不含 java -jar 前缀；没有 -outFile，写进 keystore） */
public func signKeypairArgs(keyAlias: String, p12Path: String, password: String): ArrayList<String> {
    let a = ArrayList<String>()
    a.add("generate-keypair")
    a.add("-keyAlias")
    a.add(keyAlias)
    a.add("-keyAlg")
    a.add(SIGN_KEY_ALG)
    a.add("-keySize")
    a.add(SIGN_KEY_SIZE)
    a.add("-keystoreFile")
    a.add(p12Path)
    a.add("-keystorePwd")
    a.add(password)
    a.add("-keyPwd")
    a.add(password)
    return a
}

/** generate-csr 的完整参数（这个有 -outFile） */
public func signCsrArgs(keyAlias: String, p12Path: String, password: String,
    csrPath: String): ArrayList<String> {
    let a = ArrayList<String>()
    a.add("generate-csr")
    a.add("-keyAlias")
    a.add(keyAlias)
    a.add("-subject")
    a.add(SIGN_CSR_SUBJECT)
    a.add("-signAlg")
    a.add(SIGN_ALG)
    a.add("-keystoreFile")
    a.add(p12Path)
    a.add("-keystorePwd")
    a.add(password)
    a.add("-keyPwd")
    a.add(password)
    a.add("-outFile")
    a.add(csrPath)
    return a
}

/** 命令行打码：紧跟 -keystorePwd / -keyPwd 的那个值换成 ****** */
public func signMaskSecrets(args: ArrayList<String>): String {
    var text = ""
    var maskNext = false
    for (a in args) {
        let shown = if (maskNext) { "******" } else { a }
        if (text != "") {
            text += " "
        }
        text += shown
        maskNext = (a == "-keystorePwd" || a == "-keyPwd")
    }
    return text
}

/** 一次 hap-sign-tool 调用的结果 */
public class SignToolResult {
    public var ok: Bool = false
    public var error: String = ""
    /** 打码后的命令行（排障用，绝不含口令） */
    public var command: String = ""
}

/** 跑一次 hap-sign-tool：java -jar <jar> <args...> */
public func signRunSignTool(javaPath: String, jarPath: String, args: ArrayList<String>,
    workingDir: String): SignToolResult {
    let r = SignToolResult()
    r.command = signMaskSecrets(args)
    if (javaPath == "") {
        r.error = "找不到 java（设 JAVA_HOME，或用 DEVECO_HOME 指向 DevEco，或把 java 放进 PATH）"
        return r
    }
    if (jarPath == "") {
        r.error = "找不到 hap-sign-tool.jar（设 DEVECO_SDK_HOME 指向 SDK 根）"
        return r
    }
    let argv = ArrayList<String>()
    argv.add("-jar")
    argv.add(jarPath)
    for (a in args) {
        argv.add(a)
    }
    try {
        let (code, out, errOut) = executeWithOutput(javaPath, argv.toArray(),
            workingDirectory: Path(workingDir))
        let log = lenientUtf8(out) + "\n" + lenientUtf8(errOut)
        if (code != 0) {
            r.error = "hap-sign-tool 失败（exit=${code}）：${signTailOf(log, 400)}"
            return r
        }
        r.ok = true
        return r
    } catch (e: Exception) {
        r.error = "起 java 失败：${e}"
        return r
    }
}

/** 取文本尾部（错误信息只要最后几句就够定位） */
public func signTailOf(s: String, n: Int64): String {
    if (s.size <= n) {
        return s
    }
    return "…${s[(s.size - n)..s.size]}"
}

/** 生成密钥对（p12） */
public func signGenKeypair(javaPath: String, jarPath: String, p12Path: String, password: String,
    workingDir: String): SignToolResult {
    return signRunSignTool(javaPath, jarPath, signKeypairArgs(SIGN_KEY_ALIAS, p12Path, password),
        workingDir)
}

/** 生成 CSR */
public func signGenCsr(javaPath: String, jarPath: String, p12Path: String, password: String,
    csrPath: String, workingDir: String): SignToolResult {
    return signRunSignTool(javaPath, jarPath, signCsrArgs(SIGN_KEY_ALIAS, p12Path, password, csrPath),
        workingDir)
}
