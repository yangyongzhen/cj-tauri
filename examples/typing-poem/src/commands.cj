package typing_poem

import std.env.*
import std.fs.*
import std.collection.*
import stdx.encoding.json.*
import cjTauri.*

/**
 * 打字练习的命令层：素材、成绩、自检开关、退出
 *
 * 分工是刻意的——**素材与成绩都在仓颉侧**，页面只经 invoke 取用：
 *   · `poem:list`  诗库（含逐字拼音）由宿主持有，页面不自带一份，两处不会漂移；
 *   · `score:save` 最好成绩写本机文件（页面刷不丢），并回投「是否破纪录」；
 *   · `typing:config` 让页面知道这次是不是自检跑（自检跑就自己打一首诗，见 ui/index.html）；
 *   · `report` 页面把验证结果写回 stderr —— 与仓内其他示例同一套端到端取证通道。
 */

/** 最好成绩落盘位置（相对运行目录 = 项目根）。`.local` 后缀已加进根 .gitignore：本机数据不进仓 */
let SCORES_PATH = "typing-scores.local.json"

// ---------------------------------------------------------------- 参数读取

func argString(args: JsonObject, key: String, fallback: String): String {
    match (args.get(key)) {
        case Some(v) =>
            match (v.kind()) {
                case JsonKind.JsString => return v.asString().getValue()
                case _ => return fallback
            }
        case None => return fallback
    }
}

/** 读整数：浮点也收（JS 侧算出来的速度是小数，页面可能不带取整就传过来） */
func argInt(args: JsonObject, key: String, fallback: Int64): Int64 {
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

func argFloat(args: JsonObject, key: String, fallback: Float64): Float64 {
    match (args.get(key)) {
        case Some(v) =>
            match (v.kind()) {
                case JsonKind.JsFloat => return v.asFloat().getValue()
                case JsonKind.JsInt => return Float64(v.asInt().getValue())
                case _ => return fallback
            }
        case None => return fallback
    }
}

/** 保留一位小数：JSON 里不吐 66.66666666666667 这种数（页面直接显示） */
func round1(x: Float64): Float64 {
    return Float64(Int64(x * 10.0 + 0.5)) / 10.0
}

// ---------------------------------------------------------------- 成绩存储

/**
 * 最好成绩：一个「诗 id → 记录」的 JSON 对象，整体读写文件
 *
 * 为什么整份读写而不是逐条追加：这份数据的体量是「二十一首诗各一行」，读写都只在
 * 进入 / 打完一首时发生；整份读写换来的是**格式自愈**——文件被人改坏也只是本轮从空开始，
 * 不会把解析错误带进游戏。
 *
 * public 是必须的：它作为命令构造参数出现在 `public init` 上（换成 internal 就编译不过）。
 */
public class ScoreStore {
    private let path: String
    private var root: JsonObject

    init(path: String) {
        this.path = path
        this.root = JsonObject()
        this.load()
    }

    private func load(): Unit {
        try {
            let text = String.fromUtf8(File.readFrom(this.path))
            let parsed = JsonValue.fromStr(text)
            match (parsed.kind()) {
                case JsonKind.JsObject => this.root = parsed.asObject()
                case _ => eprintln("[typing] 成绩文件不是 JSON 对象，本轮从空开始：${this.path}")
            }
        } catch (e: Exception) {
            // 第一次跑就是这条路径——没有成绩文件是正常状态，不是错误，不打日志
        }
    }

    func recordOf(id: String): Option<JsonObject> {
        match (this.root.get(id)) {
            case Some(v) =>
                match (v.kind()) {
                    case JsonKind.JsObject => return Some(v.asObject())
                    case _ => return None
                }
            case None => return None
        }
    }

    func put(id: String, record: JsonObject): Unit {
        this.root.put(id, record)
    }

    /** 整份成绩原样交出（页面按诗 id 取用，主机侧不做筛选） */
    func raw(): JsonValue {
        return this.root
    }

    func save(): Bool {
        try {
            // File.writeTo 是覆盖写：文件已存在会截断，不需要先删
            File.writeTo(this.path, this.root.toJsonString().toArray())
            return true
        } catch (e: Exception) {
            eprintln("[typing] 成绩写盘失败：${e}（路径 ${this.path}，本轮成绩只在内存里）")
            return false
        }
    }
}

/**
 * 星级：正确率与速度双门槛，先保正确再谈快
 *
 * 小学生练习的取舍：打字练习最容易变成「乱敲求快」，所以三星要求
 * 正确率 ≥95% **且** 速度 ≥60 键/分；二星放宽到 85% / 30 键/分。
 */
func starsFor(accuracy: Float64, kpm: Float64): Int64 {
    if (accuracy >= 0.95 && kpm >= 60.0) {
        return 3
    }
    if (accuracy >= 0.85 && kpm >= 30.0) {
        return 2
    }
    return 1
}

// ---------------------------------------------------------------- 命令

/** `poem:list`：诗库交给页面（含星级，难度分档由仓颉侧定） */
public class PoemListCommand <: CommandHandler {
    public init() {}

    public func handle(cmd: String, args: JsonObject, ipc: IpcContext): JsonValue {
        let arr = ArrayList<JsonValue>()
        for (p in poems()) {
            arr.add(p.toJson())
        }
        eprintln("[typing] poem:list -> ${arr.size} 首（window=${ipc.window}）")
        return JsonArray(arr)
    }
}

/** `score:list`：全部最好成绩（页面首页显示「我的纪录」） */
public class ScoreListCommand <: CommandHandler {
    private let store: ScoreStore

    public init(store: ScoreStore) {
        this.store = store
    }

    public func handle(cmd: String, args: JsonObject, ipc: IpcContext): JsonValue {
        eprintln("[typing] score:list（window=${ipc.window}）")
        return store.raw()
    }
}

/** `score:save`：结算时调一次——写最好成绩，回投「有没有破纪录」 */
public class ScoreSaveCommand <: CommandHandler {
    private let store: ScoreStore

    public init(store: ScoreStore) {
        this.store = store
    }

    public func handle(cmd: String, args: JsonObject, ipc: IpcContext): JsonValue {
        let id = argString(args, "id", "")
        if (id.size == 0) {
            throw Exception("score:save 需要 id（哪一首诗）")
        }
        let title = argString(args, "title", id)
        // 用时必须是浮点：Int64 会把「一秒内打完」（无人值守自检就是）截成 0，
        // 速度随之变 0、星级被拖到最低——实机自检第一轮就是这么暴露的。
        let seconds = argFloat(args, "seconds", 0.0)
        let correct = argInt(args, "correct", 0)
        let errors = argInt(args, "errors", 0)
        let syllables = argInt(args, "syllables", 0)
        if (correct <= 0) {
            throw Exception("score:save 的 correct 必须是正整数（打对了几个音节）")
        }

        let total = correct + errors
        let accuracy = Float64(correct) / Float64(total)
        let kpm = if (seconds > 0.0) { Float64(correct) * 60.0 / seconds } else { 0.0 }
        let stars = starsFor(accuracy, kpm)

        let previous = store.recordOf(id)
        var attempts: Int64 = 1
        var bestStars: Int64 = 0
        var bestKpm: Float64 = 0.0
        var bestAccuracy: Float64 = 0.0
        var bestSeconds: Float64 = 0.0
        match (previous) {
            case Some(old) =>
                attempts = argInt(old, "attempts", 0) + 1
                bestStars = argInt(old, "bestStars", 0)
                bestKpm = argFloat(old, "bestKpm", 0.0)
                bestAccuracy = argFloat(old, "bestAccuracy", 0.0)
                bestSeconds = argFloat(old, "bestSeconds", 0.0)
            case None => ()
        }
        // 破纪录的判据：星级优先，同级看速度——正确率已经含在星级门槛里
        var updated = false
        if (stars > bestStars || (stars == bestStars && kpm > bestKpm)) {
            updated = true
            bestStars = stars
            bestKpm = kpm
            bestAccuracy = accuracy
            bestSeconds = seconds
        }

        let rec = JsonObject()
        rec.put("id", JsonString(id))
        rec.put("title", JsonString(title))
        rec.put("attempts", JsonInt(attempts))
        rec.put("bestStars", JsonInt(bestStars))
        rec.put("bestKpm", JsonFloat(round1(bestKpm)))
        rec.put("bestAccuracy", JsonFloat(round1(bestAccuracy * 100.0)))
        rec.put("bestSeconds", JsonFloat(round1(bestSeconds)))
        rec.put("lastStars", JsonInt(stars))
        rec.put("lastKpm", JsonFloat(round1(kpm)))
        rec.put("lastAccuracy", JsonFloat(round1(accuracy * 100.0)))
        rec.put("lastErrors", JsonInt(errors))
        rec.put("syllables", JsonInt(syllables))
        store.put(id, rec)
        let written = store.save()

        eprintln("[typing] score:save 《${title}》 用时 ${round1(seconds)}s 正确率 "
            + "${round1(accuracy * 100.0)}% 速度 ${round1(kpm)} 键/分 星级 ${stars} 破纪录=${updated}"
            + " 第 ${attempts} 次 落盘=${written}")

        let out = JsonObject()
        out.put("updated", JsonBool(updated))
        out.put("attempts", JsonInt(attempts))
        out.put("stars", JsonInt(stars))
        out.put("kpm", JsonFloat(round1(kpm)))
        out.put("accuracy", JsonFloat(round1(accuracy * 100.0)))
        out.put("bestStars", JsonInt(bestStars))
        out.put("bestKpm", JsonFloat(round1(bestKpm)))
        out.put("persisted", JsonBool(written))
        return out
    }
}

/** 自检模式：跑 run.bat 时设 CJ_TYPING_SELFCHECK=1，页面就自己把一首诗打完 */
func selfCheckEnabled(): Bool {
    match (getVariable("CJ_TYPING_SELFCHECK")) {
        case Some(v) => return v == "1"
        case None => return false
    }
}

/** `typing:config`：把宿主侧的运行模式交给页面（自检 / 成绩文件位置 / three.js 版本） */
public class TypingConfigCommand <: CommandHandler {
    public init() {}

    public func handle(cmd: String, args: JsonObject, ipc: IpcContext): JsonValue {
        let obj = JsonObject()
        obj.put("selfCheck", JsonBool(selfCheckEnabled()))
        obj.put("scoresPath", JsonString(SCORES_PATH))
        obj.put("three", JsonString("r160"))
        obj.put("poems", JsonInt(poems().size))
        let mode = if (selfCheckEnabled()) { "自检" } else { "正常游玩" }
        eprintln("[typing] typing:config -> ${mode}（window=${ipc.window}）")
        return obj
    }
}

/** `report`：页面把验证结果回传，仓颉侧打 stderr（端到端验证闭环） */
public class ReportCommand <: CommandHandler {
    public init() {}

    public func handle(cmd: String, args: JsonObject, ipc: IpcContext): JsonValue {
        let line = argString(args, "line", "")
        eprintln("[frontend] " + line)
        return JsonBool(true)
    }
}

/** `typing:quit`：页面上的「退出」按钮 / 自检跑完自己收尾——走应用级 quit（收全部窗口） */
public class QuitCommand <: CommandHandler {
    private let app: TauriApp

    public init(app: TauriApp) {
        this.app = app
    }

    public func handle(cmd: String, args: JsonObject, ipc: IpcContext): JsonValue {
        eprintln("[typing] 页面请求退出（window=${ipc.window}）")
        this.app.quit()
        return JsonBool(true)
    }
}
