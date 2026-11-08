package typing_english

import std.collection.*
import stdx.encoding.json.*

/**
 * 小学常用英语词汇（分课素材）
 *
 * 素材放在**仓颉侧**而不是页面里，理由与 typing-poem 那条一致：词条最容易写错的地方是
 * 「音标对不上单词」「中文漏了」「同一个词在两课里重复练」，这些都能在启动时自检出来
 * （见 checkWordData()），不用等小朋友打到那一条才发现。页面只经 `word:list` 取数据，
 * 自己不存一份，避免两处漂移。
 *
 * 词形约定（页面只吃 a-z 字母键，所以要守这条）：
 *   · `en` 一律**小写、纯字母**——不含空格 / 连字符 / 撇号。像 ice cream、don't 这种带其它
 *     字符的词不入库（要么拆成单词，要么换成同义的单个词）；
 *   · `ipa` 用常见英式音标写法，重音符号用 ˈ（页面只展示，不参与打字判定）；
 *   · `zh` 是给小学生看的简短释义，一个词最多两条同义（用「；」分隔），不写长句。
 *
 * 选词范围（2026-11-08 按用户要求）：人教版 PEP 小学英语三到六年级的常用词打底，按主题分课，
 * 每课 12～16 个词。**优先挑「一个词对应一个具体事物」的名词与形容词**——这类词打完中文弹出来
 * 一眼就懂，最适合「打字 + 顺带记词」这个玩法；抽象词（because、beautiful）难记也难解释，先不收。
 */
public class Word {
    public let en: String
    public let ipa: String
    public let pos: String
    public let zh: String

    public init(en: String, ipa: String, pos: String, zh: String) {
        this.en = en
        this.ipa = ipa
        this.pos = pos
        this.zh = zh
    }

    /** 字母数：难度分档与页面上的「这个词要打几下」都用它 */
    public func letters(): Int64 {
        return Int64(this.en.size)
    }

    public func toJson(): JsonValue {
        let obj = JsonObject()
        obj.put("en", JsonString(this.en))
        obj.put("ipa", JsonString(this.ipa))
        obj.put("pos", JsonString(this.pos))
        obj.put("zh", JsonString(this.zh))
        obj.put("letters", JsonInt(this.letters()))
        return obj
    }
}

/**
 * 一课 = 一个主题（数字颜色 / 动物 / 食物…）
 *
 * 分课而不是一口气报一百多个词，是因为小朋友的注意力单位是「一小把」：一课的词数
 * 控制在 16 以内，打完一课就有一次结算与星级，比「打完整个词库才给反馈」撑得住得多。
 */
public class Lesson {
    public let id: String
    public let title: String
    public let subtitle: String
    public let words: Array<Word>

    public init(id: String, title: String, subtitle: String, words: Array<Word>) {
        this.id = id
        this.title = title
        this.subtitle = subtitle
        this.words = words
    }

    /** 本课字母总数：速度统计与进度条的分母 */
    public func letters(): Int64 {
        var n: Int64 = 0
        for (w in this.words) {
            n += w.letters()
        }
        return n
    }

    /** 词数：页面进度显示「3 / 14」的分母 */
    public func count(): Int64 {
        return Int64(this.words.size)
    }

    /**
     * 难度星级：按**平均词长**分档（1★ ≤4.0 字母 / 2★ ≤6.0 / 3★ 更长）
     *
     * 为什么用平均词长而不是词数：这套玩法的卡点不在「有几个词」，而在「每个词要敲几下」。
     * 全是 cat、dog 的课再长也是 1★；animals 那课是短的，而 school 那课有 library、homework，
     * 打起来明显更费手。
     */
    public func stars(): Int64 {
        if (this.words.size == 0) {
            return 1
        }
        let avg = Float64(this.letters()) / Float64(this.words.size)
        if (avg <= 4.0) {
            return 1
        }
        if (avg <= 6.0) {
            return 2
        }
        return 3
    }

    public func toJson(): JsonValue {
        let obj = JsonObject()
        obj.put("id", JsonString(this.id))
        obj.put("title", JsonString(this.title))
        obj.put("subtitle", JsonString(this.subtitle))
        obj.put("stars", JsonInt(this.stars()))
        obj.put("count", JsonInt(this.count()))
        obj.put("letters", JsonInt(this.letters()))
        let arr = ArrayList<JsonValue>()
        for (w in this.words) {
            arr.add(w.toJson())
        }
        obj.put("words", JsonArray(arr))
        return obj
    }
}

/** 一课一条的便捷构造：`lesson("animals", "动物", "Animals", ...)` */
func lesson(id: String, title: String, subtitle: String, words: Array<Word>): Lesson {
    return Lesson(id, title, subtitle, words)
}

/// 词条的便捷构造。参数顺序固定 en, ipa, pos, zh，写词库时一行一个词，便于逐行核对。
func w(en: String, ipa: String, pos: String, zh: String): Word {
    return Word(en, ipa, pos, zh)
}

/**
 * 全部课时（按「先容易后吃力」排序）
 *
 * 顺序有意为之：数字与颜色是三年级第一批词，词短、直觉强；动词形容词放在最后，
 * 因为它们的意思依赖语境，写在前面反而不好懂。
 */
public func lessons(): Array<Lesson> {
    return [
        lesson("numbers", "数字与颜色", "Numbers & Colours", [
            w("one", "/wʌn/", "num.", "一"),
            w("two", "/tuː/", "num.", "二"),
            w("three", "/θriː/", "num.", "三"),
            w("four", "/fɔː/", "num.", "四"),
            w("five", "/faɪv/", "num.", "五"),
            w("six", "/sɪks/", "num.", "六"),
            w("seven", "/ˈsevn/", "num.", "七"),
            w("eight", "/eɪt/", "num.", "八"),
            w("nine", "/naɪn/", "num.", "九"),
            w("ten", "/ten/", "num.", "十"),
            w("red", "/red/", "adj.", "红色的"),
            w("blue", "/bluː/", "adj.", "蓝色的"),
            w("green", "/ɡriːn/", "adj.", "绿色的"),
            w("yellow", "/ˈjeləʊ/", "adj.", "黄色的"),
            w("black", "/blæk/", "adj.", "黑色的"),
            w("white", "/waɪt/", "adj.", "白色的")
        ]),
        lesson("animals", "动物", "Animals", [
            w("cat", "/kæt/", "n.", "猫"),
            w("dog", "/dɒɡ/", "n.", "狗"),
            w("pig", "/pɪɡ/", "n.", "猪"),
            w("duck", "/dʌk/", "n.", "鸭子"),
            w("bird", "/bɜːd/", "n.", "鸟"),
            w("fish", "/fɪʃ/", "n.", "鱼"),
            w("rabbit", "/ˈræbɪt/", "n.", "兔子"),
            w("monkey", "/ˈmʌŋki/", "n.", "猴子"),
            w("tiger", "/ˈtaɪɡə/", "n.", "老虎"),
            w("panda", "/ˈpændə/", "n.", "熊猫"),
            w("horse", "/hɔːs/", "n.", "马"),
            w("sheep", "/ʃiːp/", "n.", "绵羊"),
            w("lion", "/ˈlaɪən/", "n.", "狮子"),
            w("elephant", "/ˈelɪfənt/", "n.", "大象")
        ]),
        lesson("food", "食物与饮料", "Food & Drinks", [
            w("rice", "/raɪs/", "n.", "米饭"),
            w("bread", "/bred/", "n.", "面包"),
            w("milk", "/mɪlk/", "n.", "牛奶"),
            w("water", "/ˈwɔːtə/", "n.", "水"),
            w("egg", "/eɡ/", "n.", "鸡蛋"),
            w("cake", "/keɪk/", "n.", "蛋糕"),
            w("apple", "/ˈæpl/", "n.", "苹果"),
            w("banana", "/bəˈnɑːnə/", "n.", "香蕉"),
            w("orange", "/ˈɒrɪndʒ/", "n.", "橙子"),
            w("juice", "/dʒuːs/", "n.", "果汁"),
            w("meat", "/miːt/", "n.", "肉"),
            w("noodle", "/ˈnuːdl/", "n.", "面条")
        ]),
        lesson("family", "家人与职业", "Family & People", [
            w("father", "/ˈfɑːðə/", "n.", "爸爸"),
            w("mother", "/ˈmʌðə/", "n.", "妈妈"),
            w("brother", "/ˈbrʌðə/", "n.", "哥哥；弟弟"),
            w("sister", "/ˈsɪstə/", "n.", "姐姐；妹妹"),
            w("grandpa", "/ˈɡrænpɑː/", "n.", "爷爷；外公"),
            w("grandma", "/ˈɡrænmɑː/", "n.", "奶奶；外婆"),
            w("uncle", "/ˈʌŋkl/", "n.", "叔叔；舅舅"),
            w("aunt", "/ɑːnt/", "n.", "阿姨；姑姑"),
            w("friend", "/frend/", "n.", "朋友"),
            w("teacher", "/ˈtiːtʃə/", "n.", "老师"),
            w("doctor", "/ˈdɒktə/", "n.", "医生"),
            w("nurse", "/nɜːs/", "n.", "护士"),
            w("driver", "/ˈdraɪvə/", "n.", "司机"),
            w("farmer", "/ˈfɑːmə/", "n.", "农民")
        ]),
        lesson("school", "学校与文具", "School Things", [
            w("book", "/bʊk/", "n.", "书"),
            w("pen", "/pen/", "n.", "钢笔"),
            w("pencil", "/ˈpensl/", "n.", "铅笔"),
            w("ruler", "/ˈruːlə/", "n.", "尺子"),
            w("eraser", "/ɪˈreɪzə/", "n.", "橡皮"),
            w("bag", "/bæɡ/", "n.", "书包"),
            w("desk", "/desk/", "n.", "书桌"),
            w("chair", "/tʃeə/", "n.", "椅子"),
            w("school", "/skuːl/", "n.", "学校"),
            w("class", "/klɑːs/", "n.", "班级；课"),
            w("library", "/ˈlaɪbrəri/", "n.", "图书馆"),
            w("homework", "/ˈhəʊmwɜːk/", "n.", "家庭作业")
        ]),
        lesson("body", "身体与衣物", "Body & Clothes", [
            w("head", "/hed/", "n.", "头"),
            w("hand", "/hænd/", "n.", "手"),
            w("foot", "/fʊt/", "n.", "脚"),
            w("eye", "/aɪ/", "n.", "眼睛"),
            w("ear", "/ɪə/", "n.", "耳朵"),
            w("nose", "/nəʊz/", "n.", "鼻子"),
            w("mouth", "/maʊθ/", "n.", "嘴"),
            w("hair", "/heə/", "n.", "头发"),
            w("coat", "/kəʊt/", "n.", "外套"),
            w("shirt", "/ʃɜːt/", "n.", "衬衫"),
            w("shoes", "/ʃuːz/", "n.", "鞋"),
            w("hat", "/hæt/", "n.", "帽子"),
            w("dress", "/dres/", "n.", "连衣裙"),
            w("sock", "/sɒk/", "n.", "短袜")
        ]),
        lesson("nature", "天气与自然", "Weather & Nature", [
            w("sun", "/sʌn/", "n.", "太阳"),
            w("moon", "/muːn/", "n.", "月亮"),
            w("star", "/stɑː/", "n.", "星星"),
            w("sky", "/skaɪ/", "n.", "天空"),
            w("rain", "/reɪn/", "n.", "雨"),
            w("snow", "/snəʊ/", "n.", "雪"),
            w("wind", "/wɪnd/", "n.", "风"),
            w("cloud", "/klaʊd/", "n.", "云"),
            w("tree", "/triː/", "n.", "树"),
            w("flower", "/ˈflaʊə/", "n.", "花"),
            w("river", "/ˈrɪvə/", "n.", "河流"),
            w("mountain", "/ˈmaʊntən/", "n.", "山"),
            w("spring", "/sprɪŋ/", "n.", "春天"),
            w("winter", "/ˈwɪntə/", "n.", "冬天")
        ]),
        lesson("verbs", "动作与形容", "Actions & Feelings", [
            w("run", "/rʌn/", "v.", "跑"),
            w("jump", "/dʒʌmp/", "v.", "跳"),
            w("swim", "/swɪm/", "v.", "游泳"),
            w("read", "/riːd/", "v.", "读；阅读"),
            w("write", "/raɪt/", "v.", "写"),
            w("sing", "/sɪŋ/", "v.", "唱歌"),
            w("dance", "/dɑːns/", "v.", "跳舞"),
            w("draw", "/drɔː/", "v.", "画画"),
            w("happy", "/ˈhæpi/", "adj.", "快乐的"),
            w("sad", "/sæd/", "adj.", "伤心的"),
            w("tall", "/tɔːl/", "adj.", "高的"),
            w("short", "/ʃɔːt/", "adj.", "矮的；短的"),
            w("big", "/bɪɡ/", "adj.", "大的"),
            w("small", "/smɔːl/", "adj.", "小的"),
            w("hot", "/hɒt/", "adj.", "热的"),
            w("cold", "/kəʊld/", "adj.", "冷的")
        ])
    ]
}

/**
 * 词库自检：返回问题处数（0 = 干净）。启动时打日志，不抛异常——素材写坏不该让游戏开不了窗。
 *
 * 查四件事，每一件都对应一种「页面会卡住 / 会记错」的真实故障：
 *   ① `en` 非空且**全是小写 a-z**：页面只吃字母键，词里混进空格或撇号就永远打不完；
 *   ② `zh` 与 `ipa` 非空：中文弹窗没有中文、音标位空着，是这一版最不该出现的缺陷；
 *   ③ **全局唯一**：同一个词出现在两课里，练习与成绩会被摊到两条路上；
 *   ④ 每课至少 8 个词：太短的一课结算频繁、星级毫无意义。
 */
public func checkWordData(): Int64 {
    var bad: Int64 = 0
    let seen = ArrayList<String>()
    for (ls in lessons()) {
        if (ls.words.size < 8) {
            bad += 1
            eprintln("[english] 素材错误：${ls.title} 只有 ${ls.words.size} 个词，一课至少 8 个")
        }
        for (word in ls.words) {
            let en = word.en
            if (en.size == 0) {
                bad += 1
                eprintln("[english] 素材错误：${ls.title} 有一个空单词")
                continue
            }
            var badChar = ""
            for (b in en) {
                if (!(b >= 97u8 && b <= 122u8)) {
                    badChar = String.fromUtf8([b])
                    break
                }
            }
            if (badChar.size > 0) {
                bad += 1
                let msg = "[english] 素材错误：${ls.title} 的「${en}」含非 a-z 字符「${badChar}」——页面只吃字母键，这个词永远打不完"
                eprintln(msg)
            }
            if (word.zh.size == 0) {
                bad += 1
                eprintln("[english] 素材错误：${ls.title} 的「${en}」没有中文释义")
            }
            if (word.ipa.size == 0) {
                bad += 1
                eprintln("[english] 素材错误：${ls.title} 的「${en}」没有音标")
            }
            for (prev in seen) {
                if (prev == en) {
                    bad += 1
                    eprintln("[english] 素材错误：「${en}」在词库里出现了两次（${ls.title} 这里重复）")
                }
            }
            seen.add(en)
        }
    }
    eprintln("[english] 词库自检：${lessons().size} 课 / ${seen.size} 个词，问题 ${bad} 处")
    return bad
}

/** 词库总词数（页面 HUD 与自检断言用） */
public func totalWords(): Int64 {
    var n: Int64 = 0
    for (ls in lessons()) {
        n += ls.count()
    }
    return n
}
