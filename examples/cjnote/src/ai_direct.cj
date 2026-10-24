// 聊天模式（「只聊天」）：页面 ↔ 大模型直连，不经过 cjh 的 agent 循环，也没有任何工具。
//
// 为什么直连放在**宿主侧**、而不是照 ai-chat 走 `http:postStream`：
// ai-chat 的直连把密钥放在页面自己的 store 里（那是它的选择）。cjnote 的既有不变量是
// 「密钥只存在于 cjh 的配置文件里，页面只拿得到脱敏串」（`cjh:config` 的 apiKey 恒为
// `sk-ab****cd12` 形状，页面自检断言它）。照抄那条路就得新增一条把**明文密钥交给页面**的
// 命令，等于亲手拆掉这条不变量——注入的脚本也就拿得到密钥。所以把 POST 留在宿主：
// 页面只发消息，宿主发请求、读流、把增量推回去（事件 `ai:chunk`）。
//
// 另两个顺带的好处：① 打的是用户在设置页里填的**任意**服务商地址，不受 capability 的
// host scope 限制（`http:*` 只能打清单里列过的域，用户换一个自建网关就得再加白）；
// ② base_url → 端点的归一化只有这一份实现，Agent / 聊天两种模式看到的是同一个地址。
//
// SSE 的读法与框架 http 插件同口径（`src/plugins/http/plugin_http.cj` 的 fetchStream）：
// 按块读、UTF-8 多字节被块边界切开时把不完整的那几字节留到下一块、只处理以换行结尾的完整行。
// 事件用 `emit` 而不是 `emitLatest`：后者按事件名「只保最新」，会把中间的 delta 覆盖掉，
// 页面拼出来的文本缺字（http 插件踩过同一个坑）。

package cjnote

import std.collection.*
import std.env.*
import std.fs.*
import std.io.*
import std.time.*
import cjTauri.*
import stdx.encoding.json.*
import stdx.net.http.*
import stdx.net.tls.*
import stdx.net.tls.common.*

/** 单轮预算：直连没有工具轮次，只受服务商与网络影响（长文生成给足两分钟） */
let AI_CHAT_TIMEOUT_SECONDS: Int64 = 120
/** 响应体上限（兜底）：正常一轮 SSE 远小于它，超过就截断并如实标注 */
let AI_CHAT_MAX_BYTES: Int64 = 4 * 1024 * 1024
/** 没配 max_tokens 时带上的缺省值：多数服务商不接受缺省，留空会被拒 */
let AI_CHAT_DEFAULT_MAX_TOKENS: Int64 = 4096
/** 缺省端点：与 cjh 自己「base_url 留空」时的默认值对齐 */
public let AI_DEFAULT_ENDPOINT: String = "https://api.openai.com/v1/chat/completions"

/**
 * 唯一能放宽证书校验的入口：**宿主侧**环境变量，逗号分隔主机名（如 `taotoken.net`）。
 *
 * 为什么不做成设置页里一个勾选框：设置项是页面写的，而页面能写的开关等于把「要不要校验
 * 证书」交给注入的脚本决定（一条 `store:set` 就能让中间人畅通）。环境变量只有用户自己
 * 能设，边界清楚。
 *
 * 为什么需要这条通道（2026-10-22 实测）：`taotoken.net` 的链是
 * `*.taotoken.net → Xcc Trust DV SSL CA（中间）→ Certum Trusted Network CA（自签根）`，
 * 中间证书**不在**本机 Windows 证书库里，而本机仓颉 stdx 不会拿服务端下发的中间证书去建链，
 * 于是报 `TlsException: ... certificate verify failed (134), TLS alert unknown CA(F)`；
 * 同一台机器上 curl / openssl 验证通过，baidu / deepseek 也通过——只有这条链过不去。
 * 探针还确认：`CertificateVerifyMode.CustomCA(...)`（不论只给 CA 级证书还是整条链）
 * 在本机 stdx 上**不起作用**，只有 `CustomVerify` / `TrustAll` 能连通。所以这里用
 * `CustomVerify` 且只对白名单主机放行——范围比 `TrustAll` 小，且由用户显式开启。
 */
let AI_TLS_INSECURE_HOSTS_ENV: String = "CJNOTE_TLS_INSECURE_HOSTS"

/** 从 URL 里取主机名（小写）；取不到回空串。只用于白名单比对，不做 URL 校验 */
func aiHostOf(url: String): String {
    var rest = url.trimAscii()
    match (rest.indexOf("://")) {
        case Some(i) => rest = rest[i + 3..rest.size]
        case None => ()
    }
    var end = rest.size
    match (rest.indexOf("/")) {
        case Some(i) =>
            if (i < end) {
                end = i
            }
        case None => ()
    }
    match (rest.indexOf(":")) {
        case Some(i) =>
            if (i < end) {
                end = i
            }
        case None => ()
    }
    return rest[0..end].trimAscii().toAsciiLower()
}

/** 白名单文件路径：`%LOCALAPPDATA%\cjnote\tls-allow.txt`（非 Windows 回落到 XDG 数据目录） */
func aiTlsAllowFilePath(): String {
    match (getVariable("LOCALAPPDATA")) {
        case Some(v) =>
            if (v.trimAscii().size > 0) {
                return v.trimAscii() + "/cjnote/tls-allow.txt"
            }
        case None => ()
    }
    match (getVariable("HOME")) {
        case Some(v) =>
            if (v.trimAscii().size > 0) {
                return v.trimAscii() + "/.local/share/cjnote/tls-allow.txt"
            }
        case None => ()
    }
    return ""
}

/**
 * 从白名单文件读主机名：一行一个，`#` 起为注释（也允许「host # 备注」）。
 *
 * 为什么文件优先、环境变量作补充：产物是 GUI 子系统的单文件 exe，双击启动的进程
 * **读不到交互式 shell 里 export 的变量**；而文件用户可以自己建、也能被系统管理员统一铺设。
 * 这个文件页面写不了（页面只有笔记库与 `store` 的权限），所以「要不要校验证书」的开关
 * 仍然只在用户手里。
 */
func aiAllowFileHosts(): ArrayList<String> {
    let out = ArrayList<String>()
    let path = aiTlsAllowFilePath()
    if (path.size == 0) {
        return out
    }
    var text = ""
    try {
        text = String.fromUtf8(File.readFrom(path))
    } catch (e: Exception) {
        // 没有这个文件就是「没白名单」，不是故障——别把正常情况打成错误
        return out
    }
    for (line in text.split("\n")) {
        var s = line.trimAscii()
        match (s.indexOf("#")) {
            case Some(i) => s = s[0..i].trimAscii()
            case None => ()
        }
        if (s.size > 0) {
            out.add(s.toAsciiLower())
        }
    }
    return out
}

/** 环境变量里列出的主机（小写、去空白）；与白名单文件合并后使用 */
func aiInsecureHosts(): ArrayList<String> {
    let out = aiAllowFileHosts()
    match (getVariable(AI_TLS_INSECURE_HOSTS_ENV)) {
        case Some(v) =>
            for (part in v.split(",")) {
                let h = part.trimAscii().toAsciiLower()
                if (h.size > 0) {
                    out.add(h)
                }
            }
        case None => ()
    }
    return out
}

/**
 * 按端点主机决定 TLS 配置：默认严格校验；只有列进 `CJNOTE_TLS_INSECURE_HOSTS` 的主机
 * 才走 `CustomVerify`（放行），并在 stderr 明写一行——放宽是可见的，不是悄悄发生。
 */
func aiTlsConfigFor(endpoint: String): TlsClientConfig {
    var cfg = TlsClientConfig()
    let host = aiHostOf(endpoint)
    // stdx.net.http 不把 URL 主机名填进 SNI（TlsClientConfig.serverName 默认 None = 不传该扩展），
    // 要求 SNI 的服务端（CDN 前端）直接回 alert 40 handshake failure——必须显式补上。
    // 已向仓颉官方提 issue，此处是该缺陷的 workaround，修好后可撤。
    cfg.serverName = host
    for (h in aiInsecureHosts()) {
        if (h == host) {
            cfg.verifyMode = CertificateVerifyMode.CustomVerify({ _ => true })
            eprintln("[cjnote] 注意：${host} 的证书链不做校验（由宿主侧白名单放行：${aiTlsAllowFilePath()} 或 ${AI_TLS_INSECURE_HOSTS_ENV}）")
            return cfg
        }
    }
    return cfg
}

/**
 * base_url → `/chat/completions` 端点（纯函数，页面自检经 `dryRun` 断言它）。
 *
 * 用户填的地址有三种常见形状，都要能吃下：完整端点（`https://api.deepseek.com/chat/completions`）、
 * 带版本段的基址（`https://api.openai.com/v1`，设置页的占位就是这个形状）、带尾斜杠的基址
 * （手抄最常见）。判定只看结尾，够用且不会把 `/v1` 再叠加一次。
 */
public func chatEndpointOf(baseUrl: String): String {
    var b = baseUrl.trimAscii()
    // 尾斜杠最多剥 8 个（防御：`https://x/v1//////` 这种手滑不至于死循环）
    var guard = 0
    while (guard < 8 && b.size > 1 && b.endsWith("/")) {
        b = b[0..b.size - 1]
        guard += 1
    }
    if (b.size == 0) {
        return AI_DEFAULT_ENDPOINT
    }
    if (b.endsWith("/chat/completions")) {
        return b
    }
    return "${b}/chat/completions"
}

/**
 * `ai:chat`：直连大模型跑一轮纯对话。
 *
 * 参数：`messages`（[{role, content}]，页面已把 system / 历史 / 本轮问题拼好）、
 *       `dryRun`（可选，true 时只回解析结果、不发请求——页面自检用它断言端点与「配没配密钥」）。
 *
 * 返回 `{ok, status, endpoint, model, chars, received, truncated}` 或 `{ok:false, error}`。
 * **失败不抛异常**：抛出去前端只剩一句 reject 文本，而这里的原因（没密钥 / 协议不支持 /
 * 服务商 4xx）都是要显示给人看的一行话。
 */
public class AiChatCommand <: CommandHandler {
    public init() {}

    public func handle(cmd: String, args: JsonObject, ipc: IpcContext): JsonValue {
        let _ = cmd
        // 配置一律读 cjh 的那份（设置页写的就是它）——聊天模式不另存一份，避免两处配置打架
        let settings = readJsonObjectOr("${cjhConfigDir()}/settings.json")
        let endpoint = chatEndpointOf(jsonStrOf(settings, "base_url"))
        var modelName = jsonStrOf(settings, "model")
        if (modelName.size == 0) {
            modelName = "gpt-4o-mini"
        }
        var protocol = jsonStrOf(settings, "provider_protocol")
        if (protocol.size == 0) {
            protocol = "openai"
        }
        let key = cjhApiKey()
        let messages = aiMessagesOf(args)
        if (boolArgOr(args, "dryRun", false)) {
            return aiDryRunJson(endpoint, modelName, protocol, key.size > 0, messages.size)
        }
        if (!protocol.toAsciiLower().startsWith("openai")) {
            // 如实拒绝而不是假装能用：Anthropic 的 messages 接口请求体与 SSE 形状都不一样，
            // 没在真机上验过的分支不往交付里塞（用户切回 Agent 模式照样能用）。
            return aiFail("聊天模式只支持 OpenAI 兼容协议（当前配置是 ${protocol}）：切回 Agent 模式可用")
        }
        if (key.size == 0) {
            return aiFail("还没配置服务商密钥：点右上角 ⚙ 填一次（聊天模式直接读 cjh 的配置文件，本应用不另存）")
        }
        if (messages.size == 0) {
            return aiFail("没有可发送的内容")
        }
        return this.streamDirect(messages, endpoint, modelName, key, settings, ipc)
    }

    /** 发请求 + 边读边推：每条 delta 立刻经 `ai:chunk` 到页面，命令本身只回汇总 */
    private func streamDirect(messages: ArrayList<JsonObject>, endpoint: String, modelName: String,
                              key: String, settings: JsonObject, ipc: IpcContext): JsonValue {
        let payload = JsonObject()
        payload.put("model", JsonString(modelName))
        payload.put("stream", JsonBool(true))
        let items = ArrayList<JsonValue>()
        for (m in messages) {
            items.add(m)
        }
        payload.put("messages", JsonArray(items))
        let temp = jsonFloatOf(settings, "temperature")
        if (temp > 0.0) {
            payload.put("temperature", JsonFloat(temp))
        }
        let maxTok = jsonIntOf(settings, "max_tokens")
        payload.put("max_tokens", JsonInt(if (maxTok > 0) { maxTok } else { AI_CHAT_DEFAULT_MAX_TOKENS }))

        var status: Int64 = 0
        var chars: Int64 = 0
        var received: Int64 = 0
        var truncated = false
        var failure = ""
        eprintln("[cjnote] ai:chat → ${endpoint} model=${modelName} msgs=${messages.size}")
        let client = ClientBuilder()
            .tlsConfig(aiTlsConfigFor(endpoint))
            .autoRedirect(false)
            .readTimeout(Duration.second * AI_CHAT_TIMEOUT_SECONDS)
            .writeTimeout(Duration.second * AI_CHAT_TIMEOUT_SECONDS)
            .build()
        try {
            let req = HttpRequestBuilder()
                .url(endpoint)
                .post()
                .body(payload.toJsonString())
                .header("Content-Type", "application/json")
                .header("Accept", "text/event-stream")
                // 密钥只出现在这一行内存里：不进日志、不回页面
                .header("Authorization", "Bearer ${key}")
                .build()
            let resp = client.send(req)
            status = Int64(resp.status)
            if (status != 200) {
                let why = aiReadHead(resp.body, 65536)
                resp.close()
                return aiFail("服务商回了 ${status}：${why}")
            }
            let chunk = Array<Byte>(8192, repeat: 0)
            let pending = ArrayList<Byte>()
            var lineBuf = ""
            let sent = ArrayList<String>()
            var n = resp.body.read(chunk)
            while (n > 0) {
                if (received + n > AI_CHAT_MAX_BYTES) {
                    truncated = true
                    break
                }
                for (i in 0..n) {
                    pending.add(chunk[i])
                }
                received += n
                let text = aiTakeCompleteUtf8(pending)
                if (text.size > 0) {
                    lineBuf += text
                    // 只处理以换行结尾的**完整行**：SSE 的一帧可能正好被块边界切成两半，
                    // 半行拿去 JSON 解析必然抛异常，整条流就断在这一块上。
                    while (true) {
                        match (lineBuf.indexOf("\n")) {
                            case Some(idx) =>
                                let line = lineBuf[0..idx]
                                lineBuf = lineBuf[idx + 1..lineBuf.size]
                                match (sseDeltaOf(line)) {
                                    case Some(d) =>
                                        let inc = aiIncrementOf(d, sent)
                                        if (inc.size > 0) {
                                            chars += inc.size
                                            ipc.emit("ai:chunk", aiChunkPayload(inc, false))
                                        }
                                    case None => ()
                                }
                            case None => break
                        }
                    }
                }
                n = resp.body.read(chunk)
            }
            // 收尾两件事：① 最后一行可能没有结尾换行（有的服务商就这么发）；② pending 里若
            // 剩下补不齐的不完整 UTF-8，只能丢——不能直接 fromUtf8，它对非法序列抛异常，
            // 一抛就把整轮已经收到的东西全判成失败（http 插件踩过），丢几个字节更诚实。
            if (lineBuf.size > 0) {
                match (sseDeltaOf(lineBuf)) {
                    case Some(d) =>
                        let inc = aiIncrementOf(d, sent)
                        if (inc.size > 0) {
                            chars += inc.size
                            ipc.emit("ai:chunk", aiChunkPayload(inc, false))
                        }
                    case None => ()
                }
            }
            if (pending.size > 0) {
                eprintln("[cjnote] ai:chat 尾部 ${pending.size} 字节不是完整 UTF-8（流被掐断），已丢弃")
            }
            resp.close()
        } catch (e: Exception) {
            failure = "${e}"
        } finally {
            client.close()
        }
        // 无论成败都发一条 done：页面靠它收尾（否则发送按钮永远是「…」、输入框永久禁用）
        ipc.emit("ai:chunk", aiChunkPayload("", true))
        if (failure != "") {
            return aiFail("直连失败：${failure}${aiTlsHintOf(failure, endpoint)}")
        }
        eprintln("[cjnote] ai:chat 完成 status=${status} chars=${chars} received=${received} truncated=${truncated}")
        let out = JsonObject()
        out.put("ok", JsonBool(true))
        out.put("status", JsonInt(status))
        out.put("endpoint", JsonString(endpoint))
        out.put("model", JsonString(modelName))
        out.put("chars", JsonInt(chars))
        out.put("received", JsonInt(received))
        out.put("truncated", JsonBool(truncated))
        return out
    }
}

/** 解析页面的 `messages` 参数：只认 role/content 都是非空字符串的对象，其余静默跳过 */
func aiMessagesOf(args: JsonObject): ArrayList<JsonObject> {
    let out = ArrayList<JsonObject>()
    match (args.get("messages")) {
        case Some(v) =>
            match (v.kind()) {
                case JsonKind.JsArray =>
                    for (item in v.asArray().getItems()) {
                        // JsonKind 没有 `==` / `!=`（AGENTS §4），只能用 match 判
                        if (!aiIsObject(item)) {
                            continue
                        }
                        let o = item.asObject()
                        let role = jsonStrOf(o, "role")
                        let content = jsonStrOf(o, "content")
                        if (role.size == 0 || content.size == 0) {
                            continue
                        }
                        let m = JsonObject()
                        m.put("role", JsonString(role))
                        m.put("content", JsonString(content))
                        out.add(m)
                    }
                case _ => ()
            }
        case None => ()
    }
    return out
}

/** 是不是 JSON 对象（`JsonKind` 没有 `==` / `!=`，判定收在这一处） */
func aiIsObject(v: JsonValue): Bool {
    match (v.kind()) {
        case JsonKind.JsObject => return true
        case _ => return false
    }
}

/** 事件 payload：`{delta, done}`（done=true 那条 delta 必为空串） */
func aiChunkPayload(delta: String, done: Bool): JsonValue {
    let o = JsonObject()
    o.put("delta", JsonString(delta))
    o.put("done", JsonBool(done))
    return o
}

func aiDryRunJson(endpoint: String, model: String, protocol: String, hasKey: Bool,
                  count: Int64): JsonValue {
    let o = JsonObject()
    o.put("ok", JsonBool(true))
    o.put("dryRun", JsonBool(true))
    o.put("endpoint", JsonString(endpoint))
    o.put("model", JsonString(model))
    o.put("protocol", JsonString(protocol))
    o.put("hasKey", JsonBool(hasKey))
    o.put("messages", JsonInt(count))
    return o
}

/**
 * 证书类失败时补一句「怎么办」：报错原文（`unknown CA` / `certificate verify failed`）
 * 对用户没有可操作性，而两条真实出路都必须由用户自己动手（改系统证书库 / 设宿主侧环境变量）。
 */
func aiTlsHintOf(failure: String, endpoint: String): String {
    let low = failure.toAsciiLower()
    let isTls = low.contains("tls") || low.contains("certificate") || low.contains("unknown ca")
    if (!isTls) {
        return ""
    }
    let host = aiHostOf(endpoint)
    return "（证书校验没过：服务端缺中间证书或根不在系统证书库。装好证书链即可；" +
        "确需放行该主机，把主机名写进 ${aiTlsAllowFilePath()}（一行一个），" +
        "或启动前设环境变量 ${AI_TLS_INSECURE_HOSTS_ENV}=${host}）"
}

/**
 * 宿主侧实网冒烟（`CJNOTE_SELFCHECK_AI=1`）：**不开窗口**，直接调一次 `ai:chat`，
 * 把结果与流式回推条数打到 stderr。
 *
 * 为什么专门留这条入口：TLS 这类问题定论在「宿主 → 服务商」这一段，而 UI 路径要等页面
 * 自检跑完（几分钟、还依赖窗口正常渲染）。顺带把 `aiHostOf` / 白名单判定也走一遍真值
 * ——那边没有网络，单测只能验字符串。
 */
/**
 * 冒烟用的能力注册表：先按**真实清单**加载（顺带验证 `capabilities/default.json` 确实放行了
 * `ai:chunk`），读不到就退化成只放行这一个事件。
 *
 * 为什么非要这一层：`IpcHub.emitToWindow` 在投递前过 `canEmit`，没装清单的 hub 会静默把事件
 * 丢掉（只打一行 `event not allowed`）——冒烟就会得到「请求成功但 chunks=0」这种假失败。
 */
func aiSmokeCapabilities(): CapabilityRegistry {
    let reg = CapabilityRegistry()
    // 回退清单先落定：addFromJson 只做累加，后面读不到真清单时这条仍然生效
    let fallback = "{\"identifier\":\"smoke\",\"windows\":[\"main\"],\"events\":[\"ai:chunk\"]}"
    let _ = reg.addFromJson(JsonValue.fromStr(fallback))
    try {
        let text = String.fromUtf8(File.readFrom("capabilities/default.json"))
        if (!reg.addFromJson(JsonValue.fromStr(text))) {
            eprintln("[cjnote] AI SMOKE capabilities/default.json 解析失败，只放行 ai:chunk")
        }
    } catch (e: Exception) {
        eprintln("[cjnote] AI SMOKE 读不到 capabilities/default.json（${e}），只放行 ai:chunk")
    }
    return reg
}

public func aiSmokeRun(): Int64 {
    let hub = IpcHub()
    hub.setCapabilities(aiSmokeCapabilities())
    // 闭包不能捕获可变局部变量（AGENTS §4），计数用容器装
    let chunkMsgs = ArrayList<String>()
    hub.jsSink = { msg, label =>
        let _ = label
        if (msg.contains("ai:chunk")) {
            chunkMsgs.add(msg)
        }
    }
    let list = ArrayList<JsonValue>()
    let one = JsonObject()
    one.put("role", JsonString("user"))
    one.put("content", JsonString("只回复两个字：收到"))
    list.add(one)
    let args = JsonObject()
    args.put("messages", JsonArray(list))

    let started = DateTime.now()
    let res = AiChatCommand().handle("ai:chat", args, IpcContext("main", hub))
    let costMs = (DateTime.now() - started).toMilliseconds()
    var out: JsonObject = JsonObject()
    match (res.kind()) {
        case JsonKind.JsObject => out = res.asObject()
        case _ => ()
    }
    let okFlag = boolArgOr(out, "ok", false)
    let status = jsonIntOf(out, "status")
    let chars = jsonIntOf(out, "chars")
    let received = jsonIntOf(out, "received")
    let endpoint = jsonStrOf(out, "endpoint")
    let err = jsonStrOf(out, "error")
    eprintln("[cjnote] AI SMOKE ok=${okFlag} status=${status} chars=${chars} received=${received} " +
        "chunks=${chunkMsgs.size} costMs=${costMs} endpoint=${endpoint}")
    if (!okFlag) {
        eprintln("[cjnote] AI SMOKE error=${err}")
        return 1
    }
    // 成功还得有流式证据：一条 delta 都没回推，说明「边读边推」没生效（页面会看到一次性刷出全篇）
    if (chunkMsgs.size == 0) {
        eprintln("[cjnote] AI SMOKE 没有收到 ai:chunk 事件（流式回推未生效）")
        return 2
    }
    return 0
}

func aiFail(msg: String): JsonValue {
    eprintln("[cjnote] ai:chat 失败：${msg}")
    let o = JsonObject()
    o.put("ok", JsonBool(false))
    o.put("error", JsonString(msg))
    return o
}

/**
 * 从一条 SSE 行里取文本增量；这条行没带增量就回 None。
 *
 * 认的行形状只有 `data: {...}`：`event:` / `id:` / `retry:` 与以冒号开头的注释/心跳一律忽略，
 * `[DONE]` 是流结束标记（OpenAI 兼容服务商都会发，取不到增量也不用报错）。
 */
func sseDeltaOf(line: String): Option<String> {
    let s = line.trimAscii()
    if (s.size == 0 || s.startsWith(":")) {
        return None
    }
    if (!s.startsWith("data:")) {
        return None
    }
    let payloadText = s[5..s.size].trimAscii()
    if (payloadText.size == 0 || payloadText == "[DONE]") {
        return None
    }
    try {
        let v = JsonValue.fromStr(payloadText)
        match (v.kind()) {
            case JsonKind.JsObject => return aiChoiceDeltaOf(v.asObject())
            case _ => return None
        }
    } catch (e: Exception) {
        // 非 JSON 的 data 行（少数网关会插 `data: ping`）不算错，跳过即可；
        // 但留一行 stderr——真出现「流通着却没有回复」时这是唯一的线索。
        eprintln("[cjnote] ai:chat 跳过无法解析的 SSE 行（${payloadText.size} 字节）：${e}")
        return None
    }
}

/** OpenAI 兼容流：`choices[0].delta.content`（reasoning_content 等其它字段一概不取） */
func aiChoiceDeltaOf(obj: JsonObject): Option<String> {
    match (obj.get("choices")) {
        case Some(c) =>
            match (c.kind()) {
                case JsonKind.JsArray =>
                    let arr = c.asArray().getItems()
                    if (arr.size == 0 || !aiIsObject(arr[0])) {
                        return None
                    }
                    match (arr[0].asObject().get("delta")) {
                        case Some(d) =>
                            match (d.kind()) {
                                case JsonKind.JsObject =>
                                    match (d.asObject().get("content")) {
                                        case Some(t) =>
                                            match (t.kind()) {
                                                case JsonKind.JsString => return Some(t.asString().getValue())
                                                case _ => return None
                                            }
                                        case None => return None
                                    }
                                case _ => return None
                            }
                        case None => return None
                    }
                case _ => return None
            }
        case None => return None
    }
}

/** delta 形态状态：`state[0]` = 已发出的累积文本，`state[1]` = 判定出的形态（""/"inc"/"cum"）。
 * 用容器装——仓颉的 lambda 不能捕获可变局部变量 */
func aiSentOf(state: ArrayList<String>): String {
    if (state.size > 0) {
        return state.get(0).getOrThrow()
    }
    return ""
}

func aiModeOf(state: ArrayList<String>): String {
    if (state.size > 1) {
        return state.get(1).getOrThrow()
    }
    return ""
}

func aiSetState(state: ArrayList<String>, sent: String, mode: String) {
    state.clear()
    state.add(sent)
    state.add(mode)
}

/**
 * 把一块 `delta.content` 折成页面该追加的**增量**（页面是 `acc += delta` 的累积拼接）。
 *
 * 形态**只判定一次**、随后锁定——不能每帧都猜：正常增量流里相邻两帧内容相同时（「哈」「哈」、
 * 连续两个句号），逐帧猜测会把它当成「重复帧」丢掉，宁可少重复也别吞正文。
 * 判定依据：第二块若以第一块为前缀且更长 ⇒ 累积式（网关照抄「从头到现在的全文」），
 * 否则锁定增量式（OpenAI 标准）。累积式实测来源：taotoken.net 的部分模型。
 */
func aiIncrementOf(full: String, state: ArrayList<String>): String {
    if (full.size == 0) {
        return ""
    }
    let sent = aiSentOf(state)
    if (sent.size == 0) {
        aiSetState(state, full, "")
        return full
    }
    let mode = aiModeOf(state)
    if (mode == "cum" || (mode.size == 0 && full.size > sent.size && full.startsWith(sent))) {
        // 累积式：真正的新内容在已发长度之后；长度没长（同文重发）就没有新内容
        let inc = if (full.size > sent.size) {
            full[sent.size..full.size]
        } else {
            ""
        }
        aiSetState(state, full, "cum")
        return inc
    }
    aiSetState(state, sent + full, "inc")
    return full
}

/**
 * 取走 `pending` 里**完整**的 UTF-8 序列并转文本，末尾不完整的那几字节留在原地。
 *
 * 与框架 http 插件的 `takeCompleteUtf8` 同一算法（应用侧不能用子包外的私有实现，故各留一份）：
 * 回扫最多 3 字节找 lead byte，按 `10xxxxxx` 续字节数判这串齐没齐。
 */
func aiTakeCompleteUtf8(pending: ArrayList<Byte>): String {
    if (pending.size == 0) {
        return ""
    }
    var keep: Int64 = 0
    let start = if (pending.size > 3) {
        pending.size - 3
    } else {
        0
    }
    var i = pending.size - 1
    while (i >= start) {
        let b = pending.get(i).getOrThrow()
        if (b < 0x80u8) {
            keep = 0
            break
        }
        if ((b & 0xC0u8) != 0x80u8) {
            let need: Int64 = if (b >= 0xF0u8) {
                3
            } else if (b >= 0xE0u8) {
                2
            } else {
                1
            }
            let have = pending.size - i
            keep = if (have < need + 1) {
                have
            } else {
                0
            }
            break
        }
        i--
    }
    if (keep >= Int64(pending.size)) {
        return ""
    }
    let cut = pending.size - keep
    if (cut <= 0) {
        return ""
    }
    let out = String.fromUtf8(pending.toArray()[0..cut])
    // 移除已发走的部分（ArrayList.remove 收 Range）。Range 在本机工具链上是**右开**的
    // （a[0..3] 取 3 个、remove(0..2) 移 2 个），所以这里必须写 0..cut。
    // 写成 0..(cut-1) 会少移 1 字节：上一个序列的末字节留在 pending 里，下一轮拼出来的
    // 字节序列非法，fromUtf8 当场抛 IllegalArgumentException；而**多移**或**移错**则会让同一批
    // 字节被下一轮再读一遍——现象是同一帧被解析两次、页面把回答叠成重复段落（2026-10-22 实测）。
    pending.remove(0..cut)
    return out
}

/** 读响应体开头若干字节转文本（错误体用：服务商的报错就是给人看的一句话，截断够用） */
func aiReadHead(body: InputStream, limit: Int64): String {
    let buf = ArrayList<Byte>()
    let chunk = Array<Byte>(4096, repeat: 0)
    var n = body.read(chunk)
    while (n > 0) {
        for (i in 0..n) {
            buf.add(chunk[i])
        }
        if (buf.size >= limit) {
            break
        }
        n = body.read(chunk)
    }
    if (buf.size == 0) {
        return "（响应体为空）"
    }
    try {
        return String.fromUtf8(buf.toArray())
    } catch (e: Exception) {
        let _ = e
        return "（响应体不是 UTF-8，${buf.size} 字节）"
    }
}

/** 取布尔参数：缺失或类型不符都回退默认值 */
func boolArgOr(args: JsonObject, key: String, fallback: Bool): Bool {
    match (args.get(key)) {
        case Some(v) =>
            match (v.kind()) {
                case JsonKind.JsBool => return v.asBool().getValue()
                case _ => return fallback
            }
        case None => return fallback
    }
}
