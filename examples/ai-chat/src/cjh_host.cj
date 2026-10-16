package aiChat

import std.convert.*   // Int64.parse（parsable 扩展）——漏了报 undeclared identifier 'parse'
import std.env.*
import std.fs.*
import std.process.*
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
    try {
        let f = File(Path(p), OpenMode.Read)
        f.close()
        return Some(p)
    } catch (e: Exception) {
        eprintln("[cj-ai-chat] CJ_AICHAT_CJH=${p} 打不开（${e}）——按未配置处理")
        return None
    }
}

/**
 * 确保 cjh web 就绪：端口上已有活的就复用（gCjhOwned=false，退出不收）；
 * 没有且配了 CJ_AICHAT_CJH 就 spawn（cjh web --port <port>）并轮询健康检查
 * 最多 10 秒。失败不致命——页面拿「未连接」状态，聊天/工具区如实显示不可用。
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
            "聊天/工具区不可用（设 CJ_AICHAT_CJH=<cjh 可执行文件路径> 后重启）")
        return false
    }
    var proc: SubProcess
    try {
        proc = launch(bin, ["web", "--port", port.toString()])
    } catch (e: Exception) {
        eprintln("[cj-ai-chat] 启动 cjh web 失败：${e}")
        return false
    }
    gCjhProc = Some(proc)
    // 健康轮询：100ms 一步，最多 10 秒（cjh web 启动要装 Agent 栈，秒级是正常量级）
    var waited: Int64 = 0
    while (waited < 10000) {
        if (cjhHealthy(port)) {
            gCjhOwned = true
            eprintln("[cj-ai-chat] cjh web 已就绪（port=${port}，等了 ${waited}ms）")
            return true
        }
        if (!proc.isAlive()) {
            eprintln("[cj-ai-chat] cjh web 进程退出（exit=${proc.wait()}）——检查 CJ_AICHAT_CJH 指向与 cjh 配置")
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
