package leetcode_gui

import cjTauri.*
import std.collection.*
import std.env.*
import std.fs.*
import std.process.*
import stdx.encoding.json.*
// DateTime：std.time 里（独立于 std.env）
import std.time.*

/**
 * 仓颉版力扣 · 后端命令
 *
 * 五道命令（三处联动：注册 + 能力清单 + 前端 invoke）：
 *   leetcode:list       题库列表（id / 标题 / 难度）
 *   leetcode:get        单题详情（描述 / 仓颉模板 / 测试用例）
 *   leetcode:run        cjc 编译「用户代码 + 判题 harness」并运行，逐条判定
 *   leetcode:saveDraft  代码草稿存盘（按题号，重启可恢复）
 *   leetcode:loadDraft  取回某题已存草稿（没有返回空串，前端落回模板）
 *
 * 运行链路（用户裁定的 cjc 方案）：
 *   1. 拼一份完整 main.cj：用户代码 + harness（main 里逐条调用目标函数、与期望字面量
 *      比较、打印 RESULT PASS/FAIL 行）；
 *   2. 写进工作目录 target/leetcode/<题号>-<序号>/（每次判题一个独立子目录，互不覆盖）；
 *   3. `cjc main.cj -o judge`（cjc 优先取 CANGJIE_HOME/bin/cjc，找不到退回 PATH）；
 *   4. 运行 ./judge，stdout 里的 RESULT 行就是判定结果。编译错误原样回给前端。
 *
 * 命令跑在 worker 线程（框架异步分发），编译再慢也不占宿主 UI 线程。
 */

/** 判题临时目录根（工作目录 = 项目根，与 capabilities/ 同规则） */
let JUDGE_DIR = "target/leetcode"

/** 单次运行超时（毫秒）：死循环不能把 worker 线程钉死——到点杀进程如实报超时 */
let JUDGE_TIMEOUT_MS: Int64 = 10000

/** 判题子目录序号（时间戳到秒不够区分连续两次判题，叠一个进程内自增号） */
var judgeSeq: Int64 = 0

/** 无 cjc 时给用户的安装引导（判题被拒的原因 + 官网下载入口 + 配置步骤） */
let CJC_GUIDE = "本机没有找到仓颉编译器 cjc，判题功能需要它。\n" +
    "安装引导：\n" +
    "  1. 前往仓颉官网下载并安装 SDK：https://cangjie-lang.cn/download\n" +
    "  2. 设置环境变量 CANGJIE_HOME 指向 SDK 根目录（或把 SDK 的 bin 目录加入 PATH）\n" +
    "  3. 重启本应用，再点「运行」即可判题\n" +
    "你的代码已自动保存在草稿里，装好环境回来就能继续。"


/** 从内嵌 JSON 解析出的题目数组（启动时解析一次） */
let PROBLEMS: ArrayList<JsonObject> = parseProblems()

// ---------------------------------------------------------------- 参数读取

/** 取整型参数；缺了给 0（题号 0 会被「题目不存在」自然拦下） */
func intArg(args: JsonObject, key: String, fallback: Int64): Int64 {
    match (args.get(key)) {
        case Some(v) =>
            match (v.kind()) {
                case JsonKind.JsInt => return v.asInt().getValue()
                case JsonKind.JsFloat => return Int64(v.asFloat().getValue())
                case _ => return fallback
            }
        case None => return fallback
    }
}

/** 取字符串参数；缺了给空串 */
func stringArg(args: JsonObject, key: String, fallback: String): String {
    match (args.get(key)) {
        case Some(v) =>
            match (v.kind()) {
                case JsonKind.JsString => return v.asString().getValue()
                case _ => return fallback
            }
        case None => return fallback
    }
}

// ---------------------------------------------------------------- 题库

/** 从内嵌 JSON 解析出题目数组（启动时解析一次） */
func parseProblems(): ArrayList<JsonObject> {
    let list = ArrayList<JsonObject>()
    let root = JsonValue.fromStr(LC_PROBLEMS_JSON)
    match (root.kind()) {
        case JsonKind.JsObject =>
            match (root.asObject().get("problems")) {
                case Some(arr) =>
                    match (arr.kind()) {
                        case JsonKind.JsArray =>
                            let items = arr.asArray()
                            for (i in 0..items.size()) {
                                if (let Some(p) <- items.get(i)) {
                                    match (p.kind()) {
                                        case JsonKind.JsObject => list.add(p.asObject())
                                        case _ => ()
                                    }
                                }
                            }
                        case _ => ()
                    }
                case None => ()
            }
        case _ => ()
    }
    return list
}

/** 按 id 找题 */
func problemById(id: Int64): Option<JsonObject> {
    for (p in PROBLEMS) {
        match (p.get("id")) {
            case Some(v) =>
                match (v.kind()) {
                    case JsonKind.JsInt =>
                        if (v.asInt().getValue() == id) {
                            return Some(p)
                        }
                    case _ => ()
                }
            case None => ()
        }
    }
    return None
}

/** 取题目的字符串字段；缺字段/类型不对给空串（题库是自有数据，允许这个宽松度） */
func strField(p: JsonObject, key: String): String {
    match (p.get(key)) {
        case Some(v) =>
            match (v.kind()) {
                case JsonKind.JsString => return v.asString().getValue()
                case _ => return ""
            }
        case None => return ""
    }
}

// ---------------------------------------------------------------- 命令

/** 题库列表 */
public class ListProblemsCommand <: CommandHandler {
    public init() {}
    public func handle(cmd: String, args: JsonObject, ipc: IpcContext): JsonValue {
        let _ = cmd
        let _ = args
        let arr = JsonArray(ArrayList<JsonValue>())
        for (p in PROBLEMS) {
            var obj = JsonObject()
            match (p.get("id")) {
                case Some(v) =>
                    match (v.kind()) {
                        case JsonKind.JsInt => obj.put("id", JsonInt(v.asInt().getValue()))
                        case _ => ()
                    }
                case None => ()
            }
            obj.put("title", JsonString(strField(p, "title")))
            obj.put("difficulty", JsonString(strField(p, "difficulty")))
            obj.put("category", JsonString(strField(p, "category")))
            arr.add(obj)
        }
        var obj = JsonObject()
        obj.put("problems", arr)
        eprintln("[lc] leetcode:list -> ${PROBLEMS.size} 题（window=${ipc.window}）")
        return obj
    }
}

/** 单题详情 */
public class GetProblemCommand <: CommandHandler {
    public init() {}
    public func handle(cmd: String, args: JsonObject, ipc: IpcContext): JsonValue {
        let _ = cmd
        let _ = ipc
        let id = intArg(args, "id", 0)
        match (problemById(id)) {
            case Some(p) => return p
            case None => throw CommandException("题目 ${id} 不存在")
        }
    }
}

/** 读草稿文件（不存在/损坏返回空对象） */
func readDrafts(): JsonObject {
    var obj = JsonObject()
    try {
        let text = String.fromUtf8(File.readFrom("ui/.draft.json"))
        let root = JsonValue.fromStr(text)
        match (root.kind()) {
            case JsonKind.JsObject => obj = root.asObject()
            case _ => eprintln("[lc] 草稿文件不是 JSON 对象，本轮从空开始")
        }
    } catch (e: Exception) {
        // 首次运行没有草稿文件，属正常
    }
    return obj
}

/** 保存草稿：{ "<题号>": code }，覆盖写 ui/.draft.json */
public class SaveDraftCommand <: CommandHandler {
    public init() {}
    public func handle(cmd: String, args: JsonObject, ipc: IpcContext): JsonValue {
        let _ = cmd
        let _ = ipc
        let id = intArg(args, "id", 0)
        let code = stringArg(args, "code", "")
        let drafts = readDrafts()
        drafts.put(id.toString(), JsonString(code))
        // File.writeTo 是覆盖写：文件已存在会截断，不需要先删（typing-poem 同款）
        File.writeTo("ui/.draft.json", drafts.toJsonString().toArray())
        eprintln("[lc] draft saved id=${id} bytes=${code.size}")
        return JsonBool(true)
    }
}

/** 取回某题草稿（没有返回空串，前端落回模板） */
public class LoadDraftCommand <: CommandHandler {
    public init() {}
    public func handle(cmd: String, args: JsonObject, ipc: IpcContext): JsonValue {
        let _ = cmd
        let _ = ipc
        let id = intArg(args, "id", 0)
        let drafts = readDrafts()
        var code = ""
        match (drafts.get(id.toString())) {
            case Some(v) =>
                match (v.kind()) {
                    case JsonKind.JsString => code = v.asString().getValue()
                    case _ => ()
                }
            case None => ()
        }
        var obj = JsonObject()
        obj.put("code", JsonString(code))
        return obj
    }
}

// ---------------------------------------------------------------- 判题核心

/**
 * 运行命令：cjc 编译 + 运行 + stdout 判定。
 */
public class RunCommand <: CommandHandler {
    public init() {}
    public func handle(cmd: String, args: JsonObject, ipc: IpcContext): JsonValue {
        let _ = cmd
        let _ = ipc
        let id = intArg(args, "id", 0)
        let code = stringArg(args, "code", "")
        match (problemById(id)) {
            case None => throw CommandException("题目 ${id} 不存在")
            case Some(p) =>
                if (code.size == 0) {
                    throw CommandException("代码为空：先把模板里的算法补上再运行")
                }
                match (p.get("tests")) {
                    case Some(tests) =>
                        return judge(id, code, strField(p, "funcName"), tests)
                    case None => throw CommandException("题目 ${id} 缺少测试用例数据")
                }
        }
    }

    /**
     * 判题主流程：拼源码 → 写盘 → cjc 编译 → 运行 → 解析 RESULT 行。
     * harness 的期望值/调用式都来自题库自有数据（非用户输入），用户代码只进一个槽位——
     * 它是仓颉源码文本，本来就以编译器为边界：编不过 = 编译错误反馈给用户，
     * 不存在注入进 harness 结构的可能。
     */
    private func judge(id: Int64, code: String, funcName: String, tests: JsonValue): JsonObject {
        // 判题源码 = import + 用户代码 + harness。
        // import 必须在文件头（仓颉 import 不在包顶就编译不过），模板/答案里用的
        // ArrayList/HashMap 都在 std.collection——统一补上；用户自己写了 import 就不重复
        var prefix = ""
        if (!code.contains("import ")) {
            prefix = "import std.collection.*\n"
        }
        let source = prefix + code + "\n" + buildHarness(funcName, tests)

        // 每次判题一个独立子目录：秒级时间戳 + 进程内自增号，连续两次也不会互覆
        judgeSeq = judgeSeq + 1
        let workDir = JUDGE_DIR + "/" + id.toString() + "-" + nowMs().toString() + "-" + judgeSeq.toString()
        // 逐级建目录：Directory.create 不递归（std.fs 语义），先 target 再 target/leetcode；
        // 已存在会抛异常，判题流程不在乎「目录本来就在」，统一吞掉
        try { Directory.create(Path(JUDGE_DIR)) } catch (e: Exception) { }
        try { Directory.create(Path(workDir)) } catch (e: Exception) {
            throw CommandException("建判题目录失败：${e}")
        }
        File.writeTo(Path(workDir + "/main.cj"), source.toArray())

        // 编译缓存：按源码哈希键控——同一份源码（反复提交/换题号同代码）直接跳过编译。
        // 缓存只是「源码 → 产物」映射，哈希碰撞最坏跑一次旧二进制（判定不 PASS），
        // 下一次判题即按现源码重编修正，不破坏「同源码同结果」语义
        let cacheDir = JUDGE_DIR + "/cache/" + sourceHash(source)
        let cachedBin = cacheDir + "/judge"
        if (!exists(Path(workDir + "/judge"))) {
            if (exists(Path(cachedBin)) && copyFile(cachedBin, workDir + "/judge")) {
                eprintln("[lc] compile cache hit: ${cacheDir}")
            } else {
                // 编译：先定位 cjc，没有就给安装引导（含官网链接），不吐一行含糊的启动失败
                let cjc = match (findCjc()) {
                    case Some(p) => p
                    case None =>
                        eprintln("[lc] cjc not found: ${CJC_GUIDE}")
                        throw CommandException(CJC_GUIDE)
                }
                let comp = tryRun(cjc, ["main.cj", "-o", "judge"], workDir)
                if (comp[0] != 0) {
                    eprintln("[lc] compile failed id=${id}: ${comp[2]}")
                    var obj = JsonObject()
                    obj.put("ok", JsonBool(false))
                    obj.put("phase", JsonString("compile"))
                    obj.put("compileError", JsonString(comp[2] + comp[1]))
                    return obj
                }
                // 回存缓存（失败只影响下次提速，不影响本次结果）。
                // Directory.create 不递归（std.fs 语义）：cache 的两级父目录都要先建
                try { Directory.create(Path(JUDGE_DIR + "/cache")) } catch (e: Exception) { }
                try { Directory.create(Path(cacheDir)) } catch (e: Exception) { }
                if (!copyFile(workDir + "/judge", cachedBin)) {
                    eprintln("[lc] cache store failed: ${cacheDir}")
                }
            }
        }

        // 运行（编译已在同目录产出 ./judge），带超时：死循环到点即杀
        let run = runJudgeWithTimeout(workDir, JUDGE_TIMEOUT_MS)
        if (run[3]) {
            eprintln("[lc] judge id=${id} TIMEOUT after ${JUDGE_TIMEOUT_MS}ms")
            var obj = JsonObject()
            obj.put("ok", JsonBool(false))
            obj.put("phase", JsonString("timeout"))
            obj.put("message", JsonString("运行超过 10 秒被强制终止——检查是否有死循环或输入未就绪"))
            // 超时也记一次提交（allPassed=false，solved 只涨不降不受影响）
            recordJudgeResult(id, false)
            return obj
        }
        eprintln("[lc] judge id=${id} exit=${run[0]} stdoutBytes=${run[1].size}")
        let verdict = parseVerdict(run[1], run[0])
        // 判完记录进度（attempts +1 / 全过置 solved）；统计失败不影响判题结果。
        // Option 不能链 .get() 取值（enum 无该成员）：match 拆 passed/total
        var allPassed = false
        match (verdict.get("passed")) {
            case Some(pv) =>
                match (verdict.get("total")) {
                    case Some(tv) =>
                        let p = pv.asInt().getValue()
                        let t = tv.asInt().getValue()
                        allPassed = t > 0 && p == t
                    case None => ()
                }
            case None => ()
        }
        recordJudgeResult(id, allPassed)
        return verdict
    }

    /**
     * 判题 harness：main 里逐条调用、比较、打印 RESULT 行。
     * expect 是仓颉字面量（题库自有数据），直接嵌入比较表达式——
     * 不依赖 toString 的格式（字符串引号、数组空格都不会误判）。
     */
    private func buildHarness(funcName: String, tests: JsonValue): String {
        // funcName 暂未用上（call 表达式自带函数名）；留着是为以后按函数名校验用例归属
        let _ = funcName
        let buf = StringBuilder()
        buf.append("\n// ---- judge harness（框架生成，与用户代码同文件编译）----\n")
        buf.append("main(): Int64 {\n")
        match (tests.kind()) {
            case JsonKind.JsArray =>
                let items = tests.asArray()
                var k: Int64 = 0
                while (k < items.size()) {
                    if (let Some(t) <- items.get(k)) {
                        match (t.kind()) {
                            case JsonKind.JsObject =>
                                let call = strField(t.asObject(), "call")
                                let expect = strField(t.asObject(), "expect")
                                // 一条用例一组语句：变量名带序号天然不冲突。
                                // 不用 { } 块包装——语句位置的行首 { 会被 cjc 当 lambda 表达式
                                // 解析（实机报 expected '=>' in lambda expression）
                                buf.append("    let r${k} = ${call}\n")
                                buf.append("    if (r${k} == ${expect}) {\n")
                                buf.append("        println(\"RESULT ${k} PASS\")\n")
                                buf.append("    } else {\n")
                                // FAIL 行只打 got=：期望值不能嵌进字符串字面量——
                                // expect 本身可能是带引号的字符串（如 "olleh"），嵌进去会把
                                // println 的字符串劈断（实机：unclosed delimiter '('）。
                                // 期望值由前端从题库用例里展示（tests[i].expect）
                                buf.append("        println(\"RESULT ${k} FAIL: got=\" + r${k}.toString())\n")
                                buf.append("    }\n")
                            case _ => ()
                        }
                    }
                    k = k + 1
                }
            case _ => ()
        }
        buf.append("    return 0\n")
        buf.append("}\n")
        return buf.toString()
    }

    /** 解析运行输出：RESULT 行 → 逐条判定 + 汇总 */
    private func parseVerdict(stdout: String, exitCode: Int64): JsonObject {
        let results = JsonArray(ArrayList<JsonValue>())
        var total: Int64 = 0
        var passed: Int64 = 0
        for (line in stdout.split("\n")) {
            if (line.startsWith("RESULT ")) {
                total = total + 1
                if (line.contains(" PASS")) {
                    passed = passed + 1
                    var r = JsonObject()
                    r.put("pass", JsonBool(true))
                    results.add(r)
                } else {
                    var r = JsonObject()
                    r.put("pass", JsonBool(false))
                    r.put("detail", JsonString(line))
                    results.add(r)
                }
            }
        }
        var obj = JsonObject()
        obj.put("ok", JsonBool(true))
        obj.put("phase", JsonString("done"))
        obj.put("total", JsonInt(total))
        obj.put("passed", JsonInt(passed))
        obj.put("results", results)
        obj.put("stdout", JsonString(stdout))
        obj.put("exitCode", JsonInt(exitCode))
        if (total == 0 && stdout.size > 0) {
            // 没解析到 RESULT 行：用户代码自己 println 了别的——原样交出，也是证据
            obj.put("raw", JsonBool(true))
        }
        return obj
    }
}

// ---------------------------------------------------------------- 工具函数

/** 程序纪元（时间戳用：DateTime 直接吐秒数没有先例，用「与纪元的差值」取毫秒，modbus-poll 同款） */
let EPOCH = DateTime.now()

/** 毫秒时间戳（判题子目录名用） */
func nowMs(): Int64 {
    return (DateTime.now() - EPOCH).toMilliseconds()
}

/**
 * 判题源码的滚动哈希（缓存键）：左移 7 + 右移 57 + 异或字节。
 * 不用乘法基哈希（FNV 之类）：仓颉整数乘法溢出**抛 OverflowException**（实测），
 * 不是 C 那样静默回绕；移位丢弃高位与异或都没有溢出语义，天然安全。
 */
func sourceHash(s: String): String {
    var h: UInt64 = 0xcbf29ce484222325
    for (b in s) {
        h = (h << 7) ^ (h >> 57) ^ UInt64(b)
    }
    return h.toString()
}

/** 二进制拷贝（缓存命中把 judge 拷进运行目录）：std.fs 没有跨目录 copy，读写即可 */
func copyFile(from: String, to: String): Bool {
    try {
        File.writeTo(Path(to), File.readFrom(from))
        return true
    } catch (e: Exception) {
        return false
    }
}
/** cjc 可执行文件名（Windows 带 .exe 后缀） */
@When[os == "Linux"]
func cjcExeName(): String {
    return "cjc"
}

@When[os == "Windows"]
func cjcExeName(): String {
    return "cjc.exe"
}

/** 在 PATH 各目录里扫 cjc（Linux 分隔符是冒号） */
@When[os == "Linux"]
func cjcFromPath(): Option<String> {
    match (getVariable("PATH")) {
        case Some(p) =>
            for (dir in p.split(":")) {
                let cand = dir + "/cjc"
                if (exists(Path(cand))) {
                    return Some(cand)
                }
            }
            return None
        case None => return None
    }
}

/** 在 PATH 各目录里扫 cjc.exe（Windows 分隔符是分号） */
@When[os == "Windows"]
func cjcFromPath(): Option<String> {
    match (getVariable("PATH")) {
        case Some(p) =>
            for (dir in p.split(";")) {
                let cand = dir + "\\cjc.exe"
                if (exists(Path(cand))) {
                    return Some(cand)
                }
            }
            return None
        case None => return None
    }
}

/**
 * 定位 cjc：CANGJIE_HOME/bin 优先（做存在性校验，不是盲拼路径），其次扫 PATH。
 * 都找不到返回 None——调用方给 CJC_GUIDE 引导，而不是一行含糊的「启动失败」。
 */
func findCjc(): Option<String> {
    match (getVariable("CANGJIE_HOME")) {
        case Some(home) =>
            let cand = home + "/bin/" + cjcExeName()
            if (exists(Path(cand))) {
                return Some(cand)
            }
        case None => ()
    }
    return cjcFromPath()
}

/**
 * 在指定目录里跑一条命令，收 (退出码, stdout, stderr)。
 * 程序不存在等异常转成 exitCode=-1 + stderr 说明，不向上抛（判题流程要继续走）。
 */
func tryRun(program: String, argv: Array<String>, cwd: String): (Int64, String, String) {
    try {
        // executeWithOutput 返回 (退出码, stdout, stderr) 三元组（shell 插件同款），解构取用
        let (code, outBytes, errBytes) = executeWithOutput(program, argv, workingDirectory: Path(cwd))
        return (code, String.fromUtf8(outBytes), String.fromUtf8(errBytes))
    } catch (e: Exception) {
        return (-1, "", "启动失败：${e}")
    }
}

// ---------------------------------------------------------------- 带超时的判题运行

/** judge 运行的 shell 与参数：输出重定向进工作目录的文件（平台差异只在这一处，@When 分平台） */
@When[os == "Linux"]
func judgeShellArgs(): (String, Array<String>) {
    return ("sh", ["-c", "./judge > stdout.txt 2> stderr.txt"])
}

@When[os == "Windows"]
func judgeShellArgs(): (String, Array<String>) {
    return ("cmd.exe", ["/c", "judge > stdout.txt 2> stderr.txt"])
}

/**
 * 运行 judge 并带超时（毫秒），返回 (退出码, stdout, stderr, 是否超时)。
 *
 * 为什么不直接 executeWithOutput：它同步阻塞到进程自然退出，没有超时参数——用户代码里
 * 一个 while(true) 就把 worker 线程永久钉死（判题永远回不来）。SubProcess 又不暴露
 * stdout/stderr 流（实测编译报 'stdout' is not a member），所以经 shell 把输出重定向进
 * 工作目录的文件：轮询 isAlive() 到期限还活着就 terminate，事后从文件读回输出。
 */
func runJudgeWithTimeout(workDir: String, timeoutMs: Int64): (Int64, String, String, Bool) {
    let (shell, argv) = judgeShellArgs()
    var p: SubProcess
    try {
        p = launch(shell, argv, workingDirectory: Path(workDir))
    } catch (e: Exception) {
        return (-1, "", "启动失败：${e}", false)
    }
    // 轮询 100ms 一步；到 deadline 还活着就杀
    var waited: Int64 = 0
    while (p.isAlive() && waited < timeoutMs) {
        sleep(Duration.millisecond * 100)
        waited = waited + 100
    }
    var timedOut = false
    if (p.isAlive()) {
        timedOut = true
        p.terminate()
        sleep(Duration.millisecond * 200)
    }
    let code = p.wait()
    var out = ""
    var err = ""
    try { out = String.fromUtf8(File.readFrom(workDir + "/stdout.txt")) } catch (e: Exception) { }
    try { err = String.fromUtf8(File.readFrom(workDir + "/stderr.txt")) } catch (e: Exception) { }
    if (timedOut) {
        return (code, out, err, true)
    }
    return (code, out, err, false)
}
