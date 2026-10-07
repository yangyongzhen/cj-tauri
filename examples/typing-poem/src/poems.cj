package typing_poem

import std.collection.*
import stdx.encoding.json.*

/**
 * 古诗词素材（小学常背篇目）
 *
 * 素材放在**仓颉侧**而不是页面里，是这个示例的有意设计：页面上每个字都要有拼音，
 * 而「拼音与汉字逐字对齐」这件事最容易写错——放在仓颉侧就能在启动时**自检**（见 checkPoemData()），
 * 数据写错会立刻在 stderr 上喊出来，而不是等小朋友打到那一个字才发现对不上。
 * 页面只经 `poem:list` 取数据，自己不存一份（避免两处漂移）。
 *
 * 约定：`lines` 里每行一个二元组 `(汉字, 拼音)`，拼音按**音节**用单个空格分隔，
 * 且音节个数必须等于汉字个数（本项目所有入选诗篇都是一个字一个音节，没有儿化 / 轻声合并的情况）。
 * 页面的打字单位就是音节：打对一串字母 → 对应的那个字点亮。
 */
public class Poem {
    public let id: String
    public let title: String
    public let author: String
    public let dynasty: String
    public let lines: Array<(String, String)>

    public init(id: String, title: String, author: String, dynasty: String,
                lines: Array<(String, String)>) {
        this.id = id
        this.title = title
        this.author = author
        this.dynasty = dynasty
        this.lines = lines
    }

    /** 字数（= 音节数）：用来给难度分档，也是小朋友看到的「这一首要打多少个字」 */
    public func syllables(): Int64 {
        var n: Int64 = 0
        for (line in this.lines) {
            n += syllableCount(line[1])
        }
        return n
    }

    /** 难度星级：1★ 入门（≤18 字）/ 2★（≤24）/ 3★（更长）——档位由仓颉侧定，页面只渲染 */
    public func stars(): Int64 {
        let n = this.syllables()
        if (n <= 18) {
            return 1
        }
        if (n <= 24) {
            return 2
        }
        return 3
    }

    public func toJson(): JsonValue {
        let obj = JsonObject()
        obj.put("id", JsonString(this.id))
        obj.put("title", JsonString(this.title))
        obj.put("author", JsonString(this.author))
        obj.put("dynasty", JsonString(this.dynasty))
        obj.put("stars", JsonInt(this.stars()))
        obj.put("syllables", JsonInt(this.syllables()))
        let arr = ArrayList<JsonValue>()
        for (line in this.lines) {
            let l = JsonObject()
            l.put("text", JsonString(line[0]))
            l.put("pinyin", JsonString(line[1]))
            arr.add(l)
        }
        obj.put("lines", JsonArray(arr))
        return obj
    }
}

/** 拼音字符串的音节数：空格分隔，个数 = 空格数 + 1 */
func syllableCount(pinyin: String): Int64 {
    var n: Int64 = 1
    // 迭代 String 拿到的是 UInt32 码点（不是 Rune），空格就是 0x20
    for (cp in pinyin) {
        if (cp == 0x20) {
            n += 1
        }
    }
    return n
}

/**
 * 汉字个数：按「UTF-8 首字节」数码点
 *
 * 本 SDK 里 `for (b in text)` 迭代出的是 **UInt8 字节**，不是码点（AGENTS §4 那条已更正）：
 * 直接累加会把「鹅鹅鹅」数成 9（每字 3 字节），汉字与拼音的对齐检查就全废。
 * 续字节形如 10xxxxxx，其余都是首字节——汉字与 ASCII 都算一个。
 */
func charCount(text: String): Int64 {
    var n: Int64 = 0
    for (b in text) {
        if ((b & 0xC0u8) != 0x80u8) {
            n += 1
        }
    }
    return n
}

/**
 * 教材里最常出现的十首：五言短篇打底，七言给进阶
 *
 * 顺序即页面列表顺序：先《咏鹅》这种 18 字的小试，再五言 20 字，最后七言 28 字。
 */
public func poems(): Array<Poem> {
    return [
        Poem("yonge", "咏鹅", "骆宾王", "唐", [
            ("鹅鹅鹅", "e e e"),
            ("曲项向天歌", "qu xiang xiang tian ge"),
            ("白毛浮绿水", "bai mao fu lv shui"),
            ("红掌拨清波", "hong zhang bo qing bo")
        ]),
        Poem("jingyesi", "静夜思", "李白", "唐", [
            ("床前明月光", "chuang qian ming yue guang"),
            ("疑是地上霜", "yi shi di shang shuang"),
            ("举头望明月", "ju tou wang ming yue"),
            ("低头思故乡", "di tou si gu xiang")
        ]),
        Poem("chunxiao", "春晓", "孟浩然", "唐", [
            ("春眠不觉晓", "chun mian bu jue xiao"),
            ("处处闻啼鸟", "chu chu wen ti niao"),
            ("夜来风雨声", "ye lai feng yu sheng"),
            ("花落知多少", "hua luo zhi duo shao")
        ]),
        Poem("jiangxue", "江雪", "柳宗元", "唐", [
            ("千山鸟飞绝", "qian shan niao fei jue"),
            ("万径人踪灭", "wan jing ren zong mie"),
            ("孤舟蓑笠翁", "gu zhou suo li weng"),
            ("独钓寒江雪", "du diao han jiang xue")
        ]),
        Poem("minnong", "悯农", "李绅", "唐", [
            ("锄禾日当午", "chu he ri dang wu"),
            ("汗滴禾下土", "han di he xia tu"),
            ("谁知盘中餐", "shui zhi pan zhong can"),
            ("粒粒皆辛苦", "li li jie xin ku")
        ]),
        Poem("dengguanquelou", "登鹳雀楼", "王之涣", "唐", [
            ("白日依山尽", "bai ri yi shan jin"),
            ("黄河入海流", "huang he ru hai liu"),
            ("欲穷千里目", "yu qiong qian li mu"),
            ("更上一层楼", "geng shang yi ceng lou")
        ]),
        Poem("xiaochi", "小池", "杨万里", "宋", [
            ("泉眼无声惜细流", "quan yan wu sheng xi xi liu"),
            ("树阴照水爱晴柔", "shu yin zhao shui ai qing rou"),
            ("小荷才露尖尖角", "xiao he cai lu jian jian jiao"),
            ("早有蜻蜓立上头", "zao you qing ting li shang tou")
        ]),
        Poem("wanglushanpubu", "望庐山瀑布", "李白", "唐", [
            ("日照香炉生紫烟", "ri zhao xiang lu sheng zi yan"),
            ("遥看瀑布挂前川", "yao kan pu bu gua qian chuan"),
            ("飞流直下三千尺", "fei liu zhi xia san qian chi"),
            ("疑是银河落九天", "yi shi yin he luo jiu tian")
        ]),
        Poem("cunju", "村居", "高鼎", "清", [
            ("草长莺飞二月天", "cao zhang ying fei er yue tian"),
            ("拂堤杨柳醉春烟", "fu di yang liu zui chun yan"),
            ("儿童散学归来早", "er tong san xue gui lai zao"),
            ("忙趁东风放纸鸢", "mang chen dong feng fang zhi yuan")
        ]),
        Poem("jueju", "绝句", "杜甫", "唐", [
            ("两个黄鹂鸣翠柳", "liang ge huang li ming cui liu"),
            ("一行白鹭上青天", "yi hang bai lu shang qing tian"),
            ("窗含西岭千秋雪", "chuang han xi ling qian qiu xue"),
            ("门泊东吴万里船", "men bo dong wu wan li chuan")
        ])
    ]
}

/**
 * 素材自检：汉字与拼音逐字对齐（数据写错就当场喊出来）
 *
 * 返回问题条数（0 = 数据干净）。启动时打一行汇总，出错时逐条列出行号——
 * 拼音少写一个音节，游戏里就会在某个字上「卡住打不动」，靠日志比靠小朋友的反馈快得多。
 */
public func checkPoemData(): Int64 {
    var bad: Int64 = 0
    for (p in poems()) {
        var lineNo: Int64 = 0
        for (line in p.lines) {
            lineNo += 1
            let chars = charCount(line[0])
            let syl = syllableCount(line[1])
            if (chars != syl) {
                bad += 1
                eprintln("[typing] 素材错误：${p.title} 第 ${lineNo} 行「${line[0]}」有 ${chars} 个字，" +
                    "但拼音「${line[1]}」是 ${syl} 个音节")
            }
        }
    }
    if (bad == 0) {
        var syllables: Int64 = 0
        for (p in poems()) {
            syllables += p.syllables()
        }
        eprintln("[typing] 诗库自检通过：${poems().size} 首、共 ${syllables} 个音节，汉字与拼音逐字对齐")
    }
    return bad
}
