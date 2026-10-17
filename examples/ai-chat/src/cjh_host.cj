package aiChat

import std.convert.*   // Int64.parse（parsable 扩展）——漏了报 undeclared identifier 'parse'
import std.env.*
import std.fs.*
import std.process.*
import cjTauri.*
import stdx.encoding.json.*
import stdx.net.http.*

/**
 * cjh web 托管：只管**生命周期**（发现 → 健康检查 → 按需 spawn → 退出收尾），
 * 数据面零参与——聊天走 ws 插件（ws://127.0.0.1:8765/ws），REST（会话/技能/MCP/
 * 工具区文件）走 http 插件（http://127.0.0.1:8765/api/…）。
 *
 * 为什么不做命令代理：cjh 的 API 已经是「命令 + 事件」的形状，ai-chat 再包一层
 * 只是转发的转发；页面直连（经白名单 127.0.0.1）少一层协议翻译，工具事件
 * （tool_start/tool_result）的形状也原样到前端。
 *
 * 环境变量：
 *   CJ_AICHAT_CJH      —— cjh 可执行文件绝对路径（必配才 spawn；没配且 8765 没有活的
 *                          cjh 时，应用照常启动，页面显示「未连接」——不假装连上了）
 *   CJ_AICHAT_CJH_PORT —— 覆写端口（默认 8765，与 cjh web 的默认一致）
 *
 * 路径有**两条来源**：环境变量（启动期就绪的那条快路）与页面在**运行期选的**路径
 * （`cjh:start` 命令的参数——用户在引导卡里点「选择 cjh 可执行文件…」）。后者服务的是
 * 「应用起来时 cjh 还没装」：装完不必重启应用，也不必去设环境变量——Windows 下双击
 * GUI 产物没有控制台，设变量这件事对普通用户根本不可达。
 * 页面侧配套两条应用命令：`cjh:status`（纯读三态，见 cjhStatusJson）与 `cjh:start`（按路径拉起）。
 *
 * 注释里不写「/api 星号」这种通配（块注释嵌套坑，AGENTS §4 第一条）：REST 前缀
 * 统一记作 `/api/…`。
 */

public let CJH_DEFAULT_PORT: Int64 = 8765

/** 全局持有 spawn 出来的子进程：只有 main() 装配期写一次、quit 收尾读一次，
    不做并发保护（AGENTS §2：不给「不会发生的并发」上锁） */
public var gCjhProc: Option<SubProcess> = None
/** true = cjh 是本应用拉起的（退出时要收尾）；false = 本来就在跑（别动人家的） */
public var gCjhOwned: Bool = false

func cjhPort(): Int64 {
    return intEnvOr("CJ_AICHAT_CJH_PORT", CJH_DEFAULT_PORT)
}

func intEnvOr(name: String, fallback: Int64): Int64 {
    // 分支体保持单语句（match 分支写块体会被解析器当 lambda——AGENTS §4，本文件实测又踩一次）
    match (getVariable(name)) {
        case Some(v) => parsePortEnv(v, fallback)
        case None => fallback
    }
}

func parsePortEnv(v: String, fallback: Int64): Int64 {
    try {
        let n = Int64.parse(v)
        if (n > 0 && n <= 65535) {
            return n
        }
    } catch (e: Exception) {
        let _ = e
    }
    return fallback
}

/** cjh web 是否已在目标端口活着：GET /api/health 收到 200 即认为就绪 */
public func cjhHealthy(port: Int64): Bool {
    let client = ClientBuilder()
        .readTimeout(Duration.second * 1)
        .writeTimeout(Duration.second * 1)
        .build()
    var ok = false
    try {
        let req = HttpRequestBuilder().get().url("http://127.0.0.1:${port}/api/health").build()
        let resp = client.send(req)
        ok = Int64(resp.status) == 200
        resp.close()
    } catch (e: Exception) {
        let _ = e
    }
    client.close()
    return ok
}

/** 读环境变量里的 cjh 路径；路径打不开（不存在/没权限）按没配处理并留一行 stderr */
func cjhBinFromEnv(): Option<String> {
    match (getVariable("CJ_AICHAT_CJH")) {
        case Some(p) => checkCjhBin(p)
        case None => None
    }
}

func checkCjhBin(p: String): Option<String> {
    if (p.size == 0) {
        eprintln("[cj-ai-chat] CJ_AICHAT_CJH 是空串——按未配置处理")
        return None
    }
    if (fileReadable(p)) {
        return Some(p)
    }
    eprintln("[cj-ai-chat] CJ_AICHAT_CJH=${p} 打不开（不存在 / 没权限）——按未配置处理")
    return None
}

/** 这个路径能不能打开（不存在 / 没权限都算不行）。只回布尔、不留 stderr：
    两条路径来源（环境变量、页面选的）各自给得出更准的提示，复述一遍只会让人以为出了两次错 */
func fileReadable(p: String): Bool {
    try {
        let f = File(Path(p), OpenMode.Read)
        f.close()
        return true
    } catch (e: Exception) {
        let _ = e
        return false
    }
}

/** 可用端点的统一形状：页面拿到就能自己接上（不再只有「启动期注入」那一条路） */
func putEndpoints(obj: JsonObject, port: Int64): Unit {
    obj.put("port", JsonInt(port))
    obj.put("apiUrl", JsonString("http://127.0.0.1:${port}"))
    obj.put("wsUrl", JsonString("ws://127.0.0.1:${port}/ws"))
}

/**
 * cjh 当前状态（`cjh:status` 命令的正文）：三态 + 可用时的端点。**纯读、无副作用**
 * （不 spawn、不 kill），页面可以随便轮询。
 *
 * 为什么需要它：端点原先只在启动期经 addInitScript 注入一次——应用起来那一刻 cjh 不在，
 * 页面**此后永远拿不到端点**，装好 cjh 也只能重启应用。而页面自己也分不清「没装」与
 * 「装了没起」：两种都只是「连不上」，于是给不出正确的下一步。三态就是补这一刀：
 *   running    —— 端口上有活的 cjh（本应用拉起的或用户自己的），直接可用
 *   configured —— 配了路径但健康检查不通：可原地拉起（引导该给「启动」而不是「去下载」）
 *   missing    —— 没有可用路径且端口没活：给下载与安装引导
 */
public func cjhStatusJson(): JsonValue {
    let port = cjhPort()
    let obj = JsonObject()
    obj.put("port", JsonInt(port))
    if (cjhHealthy(port)) {
        obj.put("state", JsonString("running"))
        putEndpoints(obj, port)
        obj.put("owned", JsonBool(gCjhOwned))
        return obj
    }
    match (cjhBinFromEnv()) {
        case Some(p) =>
            obj.put("state", JsonString("configured"))
            obj.put("binPath", JsonString(p))
        case None => obj.put("state", JsonString("missing"))
    }
    return obj
}

/**
 * 确保 cjh web 就绪（启动路径）：端口上已有活的就复用（gCjhOwned=false，退出不收）；
 * 没有且**环境变量**配了路径就交给 spawnCjhWeb 拉起。失败不致命——页面拿「未连接」状态，
 * 聊天/工具区如实显示不可用，并由引导卡给出下一步（见 cjhStatusJson）。
 */
public func ensureCjhWeb(): Bool {
    let port = cjhPort()
    if (cjhHealthy(port)) {
        eprintln("[cj-ai-chat] cjh web 已在运行（port=${port}），直接复用")
        gCjhOwned = false
        return true
    }
    // 二进制配置了吗？没配就如实退出（页面显示未连接，不假装连上了）
    let bin = match (cjhBinFromEnv()) {
        case Some(p) => p
        case None => ""
    }
    if (bin.size == 0) {
        eprintln("[cj-ai-chat] cjh web 未运行且未配置 CJ_AICHAT_CJH——" +
            "聊天/工具区不可用（设 CJ_AICHAT_CJH=<cjh 可执行文件路径> 后重启，" +
            "或在 Agent 模式的引导卡里选中 cjh 可执行文件）")
        return false
    }
    return spawnCjhWeb(bin)
}

/**
 * 按指定路径拉起 cjh web 并等健康检查（100ms 一步，最多 10 秒——cjh web 启动要装 Agent 栈，
 * 秒级是正常量级）。**这里的阻塞只落在命令 worker 线程上**：命令分发本来就是异步的
 * （AGENTS §2），所以页面点「选择 cjh 可执行文件…」之后这 10 秒不会冻住窗口。
 *
 * 拉起前先把上一只**我们拉起的**收掉：换路径重试时旧进程若还占着 8765，新的那只绑定就
 * 会失败，而表象只是「10 秒后仍不通」——同一个端口上不留两个自有实例。用户自己的实例
 * （复用那条路，gCjhOwned=false）永远不动。
 *
 * 为什么显式 `--bind 127.0.0.1`：cjh web 的默认绑定是 0.0.0.0，而默认又不带鉴权 token
 * （cjh 自己会打一行安全警告）。跟着默认走等于把「能读写工作区、能跑 shell、能发消息给
 * LLM」的整套 API 摆在局域网上——本应用的消费面全在本机（页面、ws、REST 都是 127.0.0.1），
 * 所以这里收到回环。**注意只对本应用 spawn 的实例生效**：用户自己起的 cjh（被复用那条路）
 * 绑定仍由用户决定，框架不去改别人的进程。
 */
func spawnCjhWeb(bin: String): Bool {
    if (let Some(old) <- gCjhProc) {
        terminateCjhProc(old)
        gCjhProc = None
    }
    var proc: SubProcess
    try {
        proc = launch(bin, ["web", "--port", cjhPort().toString(), "--bind", "127.0.0.1"])
    } catch (e: Exception) {
        eprintln("[cj-ai-chat] 启动 cjh web 失败：${e}")
        return false
    }
    gCjhProc = Some(proc)
    let port = cjhPort()
    var waited: Int64 = 0
    while (waited < 10000) {
        if (cjhHealthy(port)) {
            gCjhOwned = true
            eprintln("[cj-ai-chat] cjh web 已就绪（port=${port}，等了 ${waited}ms）")
            return true
        }
        if (!proc.isAlive()) {
            eprintln("[cj-ai-chat] cjh web 进程退出（exit=${proc.wait()}）——检查这个可执行文件与 cjh 配置")
            gCjhProc = None
            return false
        }
        sleep(Duration.millisecond * 100)
        waited += 100
    }
    eprintln("[cj-ai-chat] cjh web 启动后 10s 健康检查仍不通——按不可用处理（进程留着，页面可重试）")
    gCjhOwned = true
    return false
}

/** 应用退出时收尾：只终止**自己拉起的** cjh（复用的不动——那是用户自己的实例） */
public func shutdownCjh(): Unit {
    if (!gCjhOwned) {
        return
    }
    // 分支体保持单语句（match 分支写块体会被解析器当 lambda——AGENTS §4）
    if (let Some(p) <- gCjhProc) {
        terminateCjhProc(p)
    }
}

func terminateCjhProc(p: SubProcess): Unit {
    if (p.isAlive()) {
        eprintln("[cj-ai-chat] 收尾：终止 cjh web")
        p.terminate()
        // 给 200ms 走完收尾再 wait，避免僵尸
        sleep(Duration.millisecond * 200)
        let _ = p.wait()
    }
}

/**
 * `cjh:status` / `cjh:start` 两条应用命令：把「cjh 在不在、能不能起」交给页面问。
 *
 * 为什么不放插件里：这两条管的是**本应用自己 spawn 的进程**（句柄就在本文件的两个全局里），
 * 没有任何跨应用复用价值；插件包是要给别的应用当依赖的，把 ai-chat 的进程策略塞进去
 * 等于把示例的应用逻辑倒灌进框架（AGENTS §2 的依赖方向）。
 * 页面侧联动见 ui/index.html 的引导卡（缺 cjh 时给的不是一句「未配置」，而是一条能走完的路）。
 */
public class CjhCommands <: CommandHandler {
    public init() {}

    public func handle(cmd: String, args: JsonObject, ipc: IpcContext): JsonValue {
        let _ = ipc
        match (cmd) {
            case "cjh:status" => cjhStatusJson()
            case "cjh:start" => this.startByPath(args)
            case _ => throw CommandException("unknown cjh command: ${cmd}")
        }
    }

    /**
     * 按页面选中的可执行文件拉起 cjh，回 `{ok, port, apiUrl, wsUrl}`；失败回 `{ok:false, error}`
     * ——失败原因是要显示给人看的一行话，**不抛异常**（抛出去前端只剩一句 reject 文本，
     * 引导卡就没有落点了）。参数缺失/类型不对才抛（那是契约错，不是业务条件）。
     */
    private func startByPath(args: JsonObject): JsonValue {
        let path = stringArgOr(args, "path", "")
        if (path.size == 0) {
            throw CommandException("cjh:start 需要非空参数 \"path\"（cjh 可执行文件的绝对路径）")
        }
        let port = cjhPort()
        let obj = JsonObject()
        // 端口上已经活着就直接复用：用户自己起的实例不许被顶掉（gCjhOwned 保持 false）。
        // 这条也覆盖「用户手快连点两次选择」——第二次不会去起第三个进程。
        if (cjhHealthy(port)) {
            obj.put("ok", JsonBool(true))
            obj.put("reused", JsonBool(true))
            putEndpoints(obj, port)
            return obj
        }
        if (!fileReadable(path)) {
            obj.put("ok", JsonBool(false))
            obj.put("error", JsonString("打不开这个文件：${path}（不存在或没有读权限）"))
            return obj
        }
        if (spawnCjhWeb(path)) {
            obj.put("ok", JsonBool(true))
            obj.put("reused", JsonBool(false))
            putEndpoints(obj, port)
            return obj
        }
        obj.put("ok", JsonBool(false))
        obj.put("error", JsonString("cjh 没在 10 秒内就绪：确认选的是 cjh 的可执行文件（Windows 是 cjh.exe），" +
            "启动错误见应用日志"))
        return obj
    }

    /** 取字符串参数：缺失或类型不符都退回默认值（调用方自己判空，给出更贴业务的话） */
    private func stringArgOr(args: JsonObject, key: String, fallback: String): String {
        match (args.get(key)) {
            case Some(v) => match (v.kind()) {
                case JsonKind.JsString => return v.asString().getValue()
                case _ => return fallback
            }
            case None => return fallback
        }
    }
}
