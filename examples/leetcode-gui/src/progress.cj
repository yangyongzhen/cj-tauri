package leetcode_gui

import cjTauri.*
import std.collection.*
import std.fs.*
import stdx.encoding.json.*

/**
 * 做题进度统计与参考答案命令
 *
 * 统计口径（lc-stats.local.json，*.local.json 已在 .gitignore，本机数据不入库）：
 *   { "<题号>": { "attempts": 提交次数, "solved": 是否全部通过 } }
 *   - 跑完判题（phase=done）才算一次有效提交，编译失败不计；
 *   - solved 只涨不降：已经全过过的题，后面再提交失败也不丢「已解决」标记；
 *   - 文件损坏按没有处理（与草稿/题包缓存同一口径），下次判题重写。
 *
 * 参考答案：solutionFor(id) 在 src/solutions.cj（raw 字符串存代码，零转义），
 * 27 题答案已逐题过「答案 + harness」cjc 编译与逐用例运行验证。
 */

/** 统计落盘位置（工作目录 = 项目根） */
let STATS_PATH = "lc-stats.local.json"

/** 读统计文件（不存在/损坏返回空对象） */
func readStats(): JsonObject {
    var obj = JsonObject()
    try {
        let text = String.fromUtf8(File.readFrom(STATS_PATH))
        let root = JsonValue.fromStr(text)
        match (root.kind()) {
            case JsonKind.JsObject => obj = root.asObject()
            case _ => eprintln("[lc] 统计文件不是 JSON 对象，本轮从空开始：${STATS_PATH}")
        }
    } catch (e: Exception) {
        // 首次运行没有统计文件，属正常
    }
    return obj
}

/** 读统计记录里的整数字段（缺/型不对给 fallback） */
func statInt(rec: JsonObject, key: String, fallback: Int64): Int64 {
    match (rec.get(key)) {
        case Some(v) =>
            match (v.kind()) {
                case JsonKind.JsInt => return v.asInt().getValue()
                case _ => return fallback
            }
        case None => return fallback
    }
}

/** 读统计记录里的布尔字段（缺/型不对给 fallback） */
func statBool(rec: JsonObject, key: String, fallback: Bool): Bool {
    match (rec.get(key)) {
        case Some(v) =>
            match (v.kind()) {
                case JsonKind.JsBool => return v.asBool().getValue()
                case _ => return fallback
            }
        case None => return fallback
    }
}

/**
 * 记录一次判题结果：attempts +1；allPassed 时置 solved。
 * 由 RunCommand 在 parseVerdict 之后调用（worker 线程，与草稿落盘同线程模型）。
 */
func recordJudgeResult(id: Int64, allPassed: Bool): Unit {
    let stats = readStats()
    var attempts: Int64 = 1
    var solved = allPassed
    match (stats.get(id.toString())) {
        case Some(v) =>
            match (v.kind()) {
                case JsonKind.JsObject =>
                    let rec = v.asObject()
                    attempts = statInt(rec, "attempts", 0) + 1
                    if (!allPassed) {
                        // 只涨不降：以前全过过的题，这次失败不丢标记
                        solved = statBool(rec, "solved", false)
                    }
                case _ => ()
            }
        case None => ()
    }
    var rec = JsonObject()
    rec.put("attempts", JsonInt(attempts))
    rec.put("solved", JsonBool(solved))
    stats.put(id.toString(), rec)
    try {
        File.writeTo(STATS_PATH, stats.toJsonString().toArray())
        eprintln("[lc] stats recorded id=${id} attempts=${attempts} solved=${solved}")
    } catch (e: Exception) {
        // 统计写盘失败不影响判题结果本身，stderr 留痕即可
        eprintln("[lc] 统计写盘失败：${e}")
    }
}

/** 参考答案：按题号取（前端载入前自行确认，避免误触剧透） */
public class SolutionCommand <: CommandHandler {
    public init() {}
    public func handle(cmd: String, args: JsonObject, ipc: IpcContext): JsonValue {
        let _ = cmd
        let _ = ipc
        let id = intArg(args, "id", 0)
        let code = solutionFor(id)
        if (code.size == 0) {
            throw CommandException("题 ${id} 暂无参考答案")
        }
        var obj = JsonObject()
        obj.put("code", JsonString(code))
        return obj
    }
}

/** 进度统计：总进度（total/attempted/solved）+ 分类进度 + 已解决题号列表 */
public class StatsCommand <: CommandHandler {
    public init() {}
    public func handle(cmd: String, args: JsonObject, ipc: IpcContext): JsonValue {
        let _ = cmd
        let _ = args
        let _ = ipc
        let stats = readStats()
        // 分类聚合按 PROBLEMS 给出的顺序（与前端分组一致）
        let catOrder = ArrayList<String>()
        let catTotal = HashMap<String, Int64>()
        let catSolved = HashMap<String, Int64>()
        var total: Int64 = 0
        var attempted: Int64 = 0
        var solved: Int64 = 0
        let solvedIds = JsonArray(ArrayList<JsonValue>())
        for (p in PROBLEMS) {
            let cat = strField(p, "category")
            let pid = problemId(p)
            match (catTotal.get(cat)) {
                case Some(_) => ()
                case None => catOrder.add(cat)
            }
            var t: Int64 = 0
            match (catTotal.get(cat)) {
                case Some(v) => t = v
                case None => ()
            }
            catTotal.add(cat, t + 1)
            total = total + 1
            match (stats.get(pid.toString())) {
                case Some(v) =>
                    match (v.kind()) {
                        case JsonKind.JsObject =>
                            let rec = v.asObject()
                            attempted = attempted + 1
                            if (statBool(rec, "solved", false)) {
                                solved = solved + 1
                                var s: Int64 = 0
                                match (catSolved.get(cat)) {
                                    case Some(x) => s = x
                                    case None => ()
                                }
                                catSolved.add(cat, s + 1)
                                solvedIds.add(JsonInt(pid))
                            }
                        case _ => ()
                    }
                case None => ()
            }
        }
        let cats = JsonArray(ArrayList<JsonValue>())
        for (cat in catOrder) {
            var t: Int64 = 0
            match (catTotal.get(cat)) {
                case Some(v) => t = v
                case None => ()
            }
            var s: Int64 = 0
            match (catSolved.get(cat)) {
                case Some(v) => s = v
                case None => ()
            }
            var c = JsonObject()
            c.put("category", JsonString(cat))
            c.put("total", JsonInt(t))
            c.put("solved", JsonInt(s))
            cats.add(c)
        }
        var obj = JsonObject()
        obj.put("total", JsonInt(total))
        obj.put("attempted", JsonInt(attempted))
        obj.put("solved", JsonInt(solved))
        obj.put("solvedIds", solvedIds)
        obj.put("categories", cats)
        return obj
    }
}
