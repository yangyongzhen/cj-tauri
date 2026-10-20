package aiChat

import std.collection.*
import std.env.*
import std.fs.*
import cjTauri.*
import stdx.encoding.json.*

/**
 * 出网白名单的**运行期加白**——「添加模型时自动加名单」的落地。
 *
 * 白名单读的是启动时扫描的静态能力清单，页面改不了它：这是出网防线，它挡的正是「页面脚本自己把
 * 数据发到任意主机」。所以放行必须由**人**点一下：本命令先弹原生确认框（页面点不了原生对话框，
 * 被注入的脚本也就无法自行加白），确认后
 *   ① 当场 `app.allowScopePattern("http", host)` 叠进注册中心（本次会话立刻可用）；
 *   ② 追加到 `<数据目录>/allowed-hosts.txt`，启动时在 `run()` 之前重放一遍（重启仍生效）。
 *
 * 页面能传的只有一个主机名，且**逐字节校验**：`*` `?` `/` `\` 空白一律拒——通配一旦被页面塞进来，
 * 「加白」就退化成「全放行」（一条 `*` 命中所有主机）。端口与路径不进白名单：判定按主机名。
 */

/** 白名单主机只收字母 / 数字 / `.` / `-`（IPv6 的 `[::1]` 本期不收，用不到就少一处口径） */
private func isHostByte(c: UInt8): Bool {
    if (c >= 48u8 && c <= 57u8) {
        return true // 0-9
    }
    if (c >= 97u8 && c <= 122u8) {
        return true // a-z
    }
    if (c >= 65u8 && c <= 90u8) {
        return true // A-Z（下面统一折成小写）
    }
    return c == 46u8 || c == 45u8 // .  -
}

private func isAlnumByte(c: UInt8): Bool {
    return (c >= 48u8 && c <= 57u8) || (c >= 97u8 && c <= 122u8) || (c >= 65u8 && c <= 90u8)
}

/**
 * 从「完整 Base URL 或裸主机名」里归一化出主机名；不合法一律回空串。
 * 大小写折成小写：白名单是逐字匹配，`API.Example.com` 与 `api.example.com` 必须算同一台。
 */
public func normalizeAllowHost(raw: String): String {
    let b = raw.toArray()
    var i = 0
    while (i < b.size && (b[i] == 32u8 || b[i] == 9u8)) {
        i = i + 1
    }
    // 有 `://` 就跳过 scheme；先遇到 `/` 说明没有 scheme
    var j = i
    while (j + 2 < b.size && b[j] != 47u8) {
        if (b[j] == 58u8 && b[j + 1] == 47u8 && b[j + 2] == 47u8) {
            i = j + 3
            break
        }
        j = j + 1
    }
    let out = ArrayList<UInt8>()
    var k = i
    while (k < b.size) {
        let c = b[k]
        if (c == 47u8 || c == 58u8) {
            break // 到路径 / 端口为止
        }
        if (c == 32u8 || c == 9u8) {
            break // 尾部空白（读文件时把注释尾巴也吃掉）
        }
        if (!isHostByte(c)) {
            return "" // 通配、反斜杠、`%`、`#` 之类一律拒
        }
        if (c >= 65u8 && c <= 90u8) {
            out.add(c + 32u8)
        } else {
            out.add(c)
        }
        k = k + 1
    }
    if (out.size == 0 || out.size > 253) {
        return ""
    }
    if (!isAlnumByte(out[0]) || !isAlnumByte(out[out.size - 1])) {
        return "" // 首尾不能是 `.` / `-`
    }
    return String.fromUtf8(out.toArray())
}

/** 本机 allow 清单的目录：放用户数据目录，**不写进仓库的 `capabilities/`**（那是清单，归 git 管） */
private func allowDataDir(): String {
    match (getVariable("HOME")) {
        case Some(h) => return "${h}/.local/share/cj-ai-chat"
        case None => return ""
    }
}

private func allowFilePath(): String {
    let d = allowDataDir()
    if (d.size == 0) {
        return ""
    }
    return "${d}/allowed-hosts.txt"
}

private func ensureDir(dir: String): Bool {
    try {
        if (exists(Path(dir))) {
            return true
        }
        Directory.create(Path(dir))
        return true
    } catch (e: Exception) {
        let _ = e
        return false
    }
}

/** 逐级建目录（`Directory.create` 不保证递归，父目录在就跳过） */
private func ensureAllowDir(): Bool {
    match (getVariable("HOME")) {
        case Some(h) =>
            if (!ensureDir("${h}/.local")) {
                return false
            }
            if (!ensureDir("${h}/.local/share")) {
                return false
            }
            return ensureDir(allowDataDir())
        case None => return false
    }
}

/** 读本机 allow 清单（一行一个主机名，`#` 开头的行与非法行天然被归一化过滤掉） */
private func readAllowedHosts(): ArrayList<String> {
    let out = ArrayList<String>()
    let p = allowFilePath()
    if (p.size == 0) {
        return out
    }
    try {
        if (!exists(Path(p))) {
            return out
        }
        let bytes = File.readFrom(p)
        let line = ArrayList<UInt8>()
        var idx = 0
        while (idx <= bytes.size) {
            // 末尾补一个换行，最后一行没有 \n 也能被收走
            let atEnd = idx == bytes.size
            let c = if (atEnd) { 10u8 } else { bytes[idx] }
            if (c == 10u8 || c == 13u8) {
                if (line.size > 0) {
                    let host = normalizeAllowHost(String.fromUtf8(line.toArray()))
                    if (host.size > 0 && !out.contains(host)) {
                        out.add(host)
                    }
                    line.clear()
                }
            } else {
                line.add(c)
            }
            idx = idx + 1
        }
    } catch (e: Exception) {
        eprintln("[cj-ai-chat] allow 清单读不到：${p}（${e}）")
    }
    return out
}

/** 追加一个主机名到本机清单；写不进去就如实回 false（由调用方告诉用户「重启还要再确认一次」） */
private func appendAllowedHost(host: String): Bool {
    let p = allowFilePath()
    if (p.size == 0 || !ensureAllowDir()) {
        return false
    }
    try {
        let f = File(Path(p), OpenMode.Append)
        f.write("${host}\n".toArray())
        f.close()
        return true
    } catch (e: Exception) {
        eprintln("[cj-ai-chat] allow 清单写不进去：${p}（${e}）")
        return false
    }
}

/**
 * 启动时把本机清单里记过的主机重放一遍（**必须在 `run()` 之前调**）。
 * 注册中心的运行期叠加是内存态、重启即空，所以每次启动都要叠回去；
 * 清单里没给该插件写 scope 时不叠加（那种情况本来就是全量放行）。
 */
public func applyPersistedAllowedHosts(app: TauriApp): Int64 {
    var n = 0
    for (h in readAllowedHosts()) {
        if (app.allowScopePattern("http", h)) {
            n = n + 1
        }
    }
    return n
}

private func argString(args: JsonObject, key: String): String {
    match (args.get(key)) {
        case Some(v) =>
            try {
                return v.asString().getValue()
            } catch (e: Exception) {
                let _ = e
                return ""
            }
        case None => return ""
    }
}

private func verdict(allowed: Bool, added: Bool, host: String, note: String): JsonValue {
    let obj = JsonObject()
    let _ = obj.put("allowed", JsonBool(allowed))
    let _ = obj.put("added", JsonBool(added))
    let _ = obj.put("host", JsonString(host))
    let _ = obj.put("note", JsonString(note))
    return obj
}

/** 原生确认框——**放行唯一的入口**；拿不到宿主句柄就宁可拒绝，也不静默放行 */
private func confirmHost(app: TauriApp, host: String): Bool {
    match (app.hostOf(DEFAULT_WINDOW_LABEL)) {
        case Some(h) =>
            let msg = "ai-chat 要访问 ${host}，它不在内置出网白名单里。\n\n" +
                "点「确定」后：本次会话立刻可用，并记进本机清单（重启仍生效）。\n" +
                "只在你确认这就是自己的服务端点时才确定。"
            return h.showMessageDialog("confirm", "允许这个地址出网？", msg)
        case None =>
            eprintln("[cj-ai-chat] 拿不到宿主句柄，无法弹确认框，拒绝加白：${host}")
            return false
    }
}

/**
 * `app:allowHost`：页面在保存服务商时调一次（参数 `url`，收完整 Base URL 或裸主机名）。
 * 回文 `{allowed, added, host, note}`——`added=false` 且 `allowed=true` 表示「本来就在名单里」。
 */
public class AllowHostCommand <: CommandHandler {
    private let app: TauriApp

    public init(app: TauriApp) {
        this.app = app
    }

    public func handle(cmd: String, args: JsonObject, ipc: IpcContext): JsonValue {
        let _ = cmd
        let _ = ipc
        let host = normalizeAllowHost(argString(args, "url"))
        if (host.size == 0) {
            return verdict(false, false, "", "服务商地址里读不出合法主机名（不接受端口、通配符与路径）")
        }
        if (this.app.isScopeAllowed("http", host)) {
            return verdict(true, false, host, "")
        }
        if (!confirmHost(this.app, host)) {
            return verdict(false, false, host, "你取消了放行，该地址的请求仍会被 scope 挡住")
        }
        if (!this.app.allowScopePattern("http", host)) {
            // 注册中心当场拒了这条模式（空串 / 带通配这类）——如实拒绝，别把「没加白」写成成功
            return verdict(false, false, host, "这条模式没有被采纳，该地址仍会被 scope 挡住")
        }
        let persisted = appendAllowedHost(host)
        let note = if (persisted) {
            ""
        } else {
            "已放行本次会话，但没能写入本机清单（重启后需再确认一次）"
        }
        eprintln("[cj-ai-chat] 已放行出网主机（用户确认）：${host}（落盘=${persisted}）")
        return verdict(true, true, host, note)
    }
}
