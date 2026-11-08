package typing_english

import std.env.*
import std.fs.*
import std.collection.*
import stdx.encoding.json.*
import cjTauri.*

/**
 * 打字 + 记词的命令层：词库下发、成绩落盘、自检开关、退出
 *
 * 分工与 typing-poem 一致——**素材与成绩都在仓颉侧**，页面只经 invoke 取用：
 *   · `word:list`     词库（含音标与中文）由宿主持有，页面不自带一份，两处不会漂移；
 *   · `score:save`    本课最好成绩写本机文件（页面刷新不丢），并回投「是否破纪录」；
 *   · `typing:config` 让页面知道这次是不是自检跑、以及中文弹窗该停多久；
 *   · `report`        页面把验证结果写回 stderr——与仓内其他示例同一套端到端取证通道；
 *   · `typing:quit`   页面上的退出按钮 / 自检跑完自己收尾。
 */

/** 最好成绩落盘位置（相对运行目录 = 项目根）。`.local` 后缀已加进根 .gitignore：本机数据不进仓 */
let SCORES_PATH = "typing-english-scores.local.json"

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
    // Int64 转换越界在仓颉里是**抛异常**（不是回绕）：留一条兜底，别让一个坏数（含 NaN）
    // 把整条 score:save 打断——页面可控的 seconds 是最容易送进坏数的地方。
    if (!(x > -1.0e15 && x < 1.0e15)) { return 0.0 }
    return Float64(Int64(x * 10.0 + 0.5)) / 10.0
}

// ---------------------------------------------------------------- 成绩存储

/**
 * 本课最好成绩：一个「课 id → 记录」的 JSON 对象，整体读写文件
 *
 * 为什么整份读写而不是逐条追加：体量是「8 课各一行」，读写只在进入 / 打完一课发生；
 * 换来的是**格式自愈**——文件被人改坏也只是本轮从空开始，不会把解析错误带进游戏。
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
                case _ => eprintln("[english] 成绩文件不是 JSON 对象，本轮从空开始：${this.path}")
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

    func raw(): JsonValue {
        return this.root
    }

    func save(): Bool {
        try {
            // File.writeTo 是覆盖写：文件已存在会截断，不需要先删
            File.writeTo(this.path, this.root.toJsonString().toArray())
            return true
        } catch (e: Exception) {
            eprintln("[english] 成绩写盘失败：${e}（路径 ${this.path}，本轮成绩只在内存里）")
            return false
        }
    }
}

/**
 * 星级：正确率与速度双门槛，先保正确再谈快
 *
 * 门槛按**词/分**（wpm）算而不是字母/分：小朋友看得懂「一分钟打几个词」，
 * 而且换课换词长时这个指标仍然可比。三档取 10 / 5 词/分，
 * 对应「打完 14 个词的 animals 课分别在 84 秒、168 秒以内」。
 */
func starsFor(accuracy: Float64, wpm: Float64): Int64 {
    if (accuracy >= 0.95 && wpm >= 10.0) {
        return 3
    }
    if (accuracy >= 0.85 && wpm >= 5.0) {
        return 2
    }
    return 1
}

// ---------------------------------------------------------------- 命令

/** `word:list`：词库交给页面（含星级，难度分档由仓颉侧定） */
public class WordListCommand <: CommandHandler {
    public init() {}

    public func handle(cmd: String, args: JsonObject, ipc: IpcContext): JsonValue {
        let _ = cmd
        let _ = args
        let arr = ArrayList<JsonValue>()
        for (ls in lessons()) {
            arr.add(ls.toJson())
        }
        eprintln("[english] word:list -> ${arr.size} 课 / ${totalWords()} 个词（window=${ipc.window}）")
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
        let _ = cmd
        let _ = args
        eprintln("[english] score:list（window=${ipc.window}）")
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
        // 签名由 CommandHandler 钉死：这个 handler 用不到命令名与窗口信息，就地显式弃用（零警告要求）
        let _ = cmd
        let _ = ipc
        let id = argString(args, "id", "")
        if (id.size == 0) {
            throw Exception("score:save 需要 id（哪一课）")
        }
        let title = argString(args, "title", id)
        // 用时必须是浮点：Int64 会把「一秒内打完」（无人值守自检就是）截成 0，
        // 速度随之变 0、星级被拖到最低——typing-poem 早期自检第一轮就是这么暴露的。
        let seconds = argFloat(args, "seconds", 0.0)
        let correct = argInt(args, "correct", 0)
        let errors = argInt(args, "errors", 0)
        let words = argInt(args, "words", 0)
        if (words <= 0) {
            throw Exception("score:save 的 words 必须是正整数（这一课打了几个词）")
        }

        let total = correct + errors
        let accuracy = if (total > 0) { Float64(correct) / Float64(total) } else { 0.0 }
        let wpm = if (seconds > 0.0) { Float64(words) * 60.0 / seconds } else { 0.0 }
        let stars = starsFor(accuracy, wpm)

        let previous = store.recordOf(id)
        var attempts: Int64 = 1
        var bestStars: Int64 = 0
        var bestWpm: Float64 = 0.0
        var bestAccuracy: Float64 = 0.0
        var bestSeconds: Float64 = 0.0
        match (previous) {
            case Some(old) =>
                attempts = argInt(old, "attempts", 0) + 1
                bestStars = argInt(old, "bestStars", 0)
                bestWpm = argFloat(old, "bestWpm", 0.0)
                // 文件里存的是**百分比**（与 lastAccuracy 一致），这里要的是**分数**：少除这个 100，
                // 每存一轮就把旧值放大 100 倍，涨到 9.6e15 时 round1 的 Int64 转换溢出，
                // score:save 从此每次抛异常、成绩再也存不下去（typing-poem 实机自检第 12 次才暴露）。
                // 超出 [0,1] 的值只可能来自被放大的历史文件，不信它，用本轮正确率当起点。
                let readAcc = argFloat(old, "bestAccuracy", 0.0) / 100.0
                bestAccuracy = if (readAcc >= 0.0 && readAcc <= 1.0) { readAcc } else { accuracy }
                bestSeconds = argFloat(old, "bestSeconds", 0.0)
            case None => ()
        }
        // 破纪录的判据：星级优先，同级看速度——正确率已经含在星级门槛里
        var updated = false
        if (stars > bestStars || (stars == bestStars && wpm > bestWpm)) {
            updated = true
            bestStars = stars
            bestWpm = wpm
            bestAccuracy = accuracy
            bestSeconds = seconds
        }

        let rec = JsonObject()
        rec.put("id", JsonString(id))
        rec.put("title", JsonString(title))
        rec.put("attempts", JsonInt(attempts))
        rec.put("bestStars", JsonInt(bestStars))
        rec.put("bestWpm", JsonFloat(round1(bestWpm)))
        rec.put("bestAccuracy", JsonFloat(round1(bestAccuracy * 100.0)))
        rec.put("bestSeconds", JsonFloat(round1(bestSeconds)))
        rec.put("lastStars", JsonInt(stars))
        rec.put("lastWpm", JsonFloat(round1(wpm)))
        rec.put("lastAccuracy", JsonFloat(round1(accuracy * 100.0)))
        rec.put("lastErrors", JsonInt(errors))
        rec.put("words", JsonInt(words))
        store.put(id, rec)
        let written = store.save()

        let secR = round1(seconds)
        let accR = round1(accuracy * 100.0)
        let wpmR = round1(wpm)
        eprintln("[english] score:save ${title} 用时 ${secR}s 正确率 ${accR}% 速度 ${wpmR} 词/分 星级 ${stars} 破纪录=${updated} 第 ${attempts} 次 落盘=${written}")

        let out = JsonObject()
        out.put("updated", JsonBool(updated))
        out.put("attempts", JsonInt(attempts))
        out.put("stars", JsonInt(stars))
        out.put("wpm", JsonFloat(round1(wpm)))
        out.put("accuracy", JsonFloat(round1(accuracy * 100.0)))
        out.put("bestStars", JsonInt(bestStars))
        out.put("bestWpm", JsonFloat(round1(bestWpm)))
        out.put("persisted", JsonBool(written))
        return out
    }
}

// ---------------------------------------------------------------- 运行模式

/** 自检模式：跑启动器时设 CJ_TYPING_SELFCHECK=1，页面就自己把一课打完并回投断言 */
func selfCheckEnabled(): Bool {
    match (getVariable("CJ_TYPING_SELFCHECK")) {
        case Some(v) => return v == "1"
        case None => return false
    }
}

/**
 * 人眼验收用的入口：`CJ_TYPING_LESSON=<课 id>` 起页面就直奔那一课，跳过选课面板。
 *
 * 为什么留这个钩子：中文弹窗的**大小、位置、两三条排队时的间距**只能靠眼睛看——
 * 几何断言能证明「在页面上方、不重叠」，证明不了「一眼看得清」。有了它，
 * `set CJ_TYPING_LESSON=school && run.bat` 一开窗就是那一课，截图就能归档对比。
 */
func startLessonId(): String {
    match (getVariable("CJ_TYPING_LESSON")) {
        case Some(v) => return v
        case None => return ""
    }
}

/**
 * 中文释义的停留时长（毫秒），默认 2600
 *
 * 让它是**可调**的，是因为这个数只有人眼能定：太短看不清、太长连续打词时会积压。
 * 页面侧还有一条自适应规则（见 ui/index.html 的 popQueue），这里给的是基准值。
 */
func popupMs(): Int64 {
    let opt = getVariable("CJ_TYPING_POP_MS")
    let ms = match (opt) {
        case Some(v) => parsePop(v)
        case None => 2600
    }
    return ms
}

/** 解析失败或超出取值区间一律回默认值：这个数只影响观感，不值得为它拦一道启动失败 */
func parsePop(text: String): Int64 {
    // 自己按字节解析，不用 std.convert：只认 ASCII 数字，见到别的字符就当没填。
    // （String 的迭代给的是 UInt8 字节，不是 Rune——仓颉这边的老规矩。）
    var n: Int64 = 0
    var digits = 0
    for (b in text) {
        if (b >= 48u8 && b <= 57u8) {
            if (digits >= 6) {
                return 2600
            }
            n = n * 10 + Int64(b - 48u8)
            digits += 1
        } else if (b != 32u8 && b != 9u8) {
            return 2600
        }
    }
    if (digits == 0 || n < 600 || n > 12000) {
        return 2600
    }
    return n
}

/** `typing:config`：把宿主侧的运行模式交给页面（自检 / 成绩文件位置 / 弹窗时长） */
public class TypingConfigCommand <: CommandHandler {
    public init() {}

    public func handle(cmd: String, args: JsonObject, ipc: IpcContext): JsonValue {
        let _ = cmd
        let _ = args
        let preset = startLessonId()
        let obj = JsonObject()
        obj.put("selfCheck", JsonBool(selfCheckEnabled()))
        obj.put("startLesson", JsonString(preset))
        obj.put("scoresPath", JsonString(SCORES_PATH))
        obj.put("popMs", JsonInt(popupMs()))
        obj.put("lessons", JsonInt(lessons().size))
        obj.put("words", JsonInt(totalWords()))
        let mode = if (selfCheckEnabled()) { "自检" } else if (preset.size > 0) { "指定课（${preset}）" } else { "正常游玩" }
        eprintln("[english] typing:config -> ${mode} 弹窗停留 ${popupMs()}ms（window=${ipc.window}）")
        return obj
    }
}

/** `report`：页面把验证结果回传，仓颉侧打 stderr（端到端验证闭环） */
public class ReportCommand <: CommandHandler {
    public init() {}

    public func handle(cmd: String, args: JsonObject, ipc: IpcContext): JsonValue {
        let _ = cmd
        let _ = ipc
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
        let _ = cmd
        let _ = args
        eprintln("[english] 页面请求退出（window=${ipc.window}）")
        this.app.quit()
        return JsonBool(true)
    }
}
