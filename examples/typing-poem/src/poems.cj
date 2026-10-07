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
 *
 * 选篇范围（2026-10-07 按用户要求覆盖到小学阶段的常见篇目）：教育部推荐的《小学生必背古诗词 75 首》
 * 打底，再补上部编版语文教材里出现、但不在那 75 首里的诗词（含「日积月累」与「古诗词诵读」栏目的篇目）。
 * **不收**三类：①文言文（学弈、两小儿辩日这类，没有逐字拼音的玩法）；②蒙学韵文（对韵歌、人之初）；
 * ③仍在版权期内的现代诗词（毛泽东《卜算子·咏梅》等 2026 年底才进入公有领域，先不引）。
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

    /**
     * 难度星级：1★ 五言短篇（≤20 字）/ 2★ 七言与词曲（≤28）/ 3★ 更长的长诗——档位由仓颉侧定，页面只渲染
     *
     * 三档对应孩子眼里三条清楚的线：五言一句五个字的「好打」、七言七个字的「要忍一忍」、
     * 以及《长歌行》《春夜喜雨》这种一屏排不完的「大篇」。诗库按音节数排序，星级与列表顺序一致。
     */
    public func stars(): Int64 {
        let n = this.syllables()
        if (n <= 20) {
            return 1
        }
        if (n <= 28) {
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
    // 迭代 String 拿到的是 UInt8 字节（不是 UInt32 码点，细节见 charCount 与 AGENTS §4）；空格就是 0x20
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
 * 小学古诗词库：五言打底、七言进阶、长诗与词曲殿后
 *
 * 顺序即页面列表顺序，按**音节数**从少到多排：16 字《采薇》→ 18 字《咏鹅》→ 五言 20 字一批 →
 * 27 字词曲（忆江南 / 渔歌子 / 敕勒歌）→ 七言 28 字一大批 → 30 字以上的《游子吟》《江南》
 * 《春夜喜雨》《长歌行》。孩子从列表顶上往下推进，难度自然递增。
 * 行数不必都是 4：卡面排版按行数自适应，**7 行以上自动分成左右两栏**（页面里的 columnRows()/vScale()），
 * 这样《长歌行》10 行也还是大字。
 *
 * 拼音口径：一律写**带声调字母省略、不带声调符号**的规范拼音字母（与仓颉侧一致），
 * 绿/女按键盘习惯写 `lv` / `nv`；一字一音节，不做儿化合并。
 */
public func poems(): Array<Poem> {
    return [
        // ── 四言 / 五言短篇（16–20 字，1★ 入门） ──
        Poem("caiwei", "采薇（节选）", "佚名", "先秦", [
            ("昔我往矣", "xi wo wang yi"),
            ("杨柳依依", "yang liu yi yi"),
            ("今我来思", "jin wo lai si"),
            ("雨雪霏霏", "yu xue fei fei")
        ]),
        Poem("yonge", "咏鹅", "骆宾王", "唐", [
            ("鹅鹅鹅", "e e e"),
            ("曲项向天歌", "qu xiang xiang tian ge"),
            ("白毛浮绿水", "bai mao fu lv shui"),
            ("红掌拨清波", "hong zhang bo qing bo")
        ]),
        Poem("hua", "画", "佚名", "唐", [
            ("远看山有色", "yuan kan shan you se"),
            ("近听水无声", "jin ting shui wu sheng"),
            ("春去花还在", "chun qu hua hai zai"),
            ("人来鸟不惊", "ren lai niao bu jing")
        ]),
        Poem("chishang", "池上", "白居易", "唐", [
            ("小娃撑小艇", "xiao wa cheng xiao ting"),
            ("偷采白莲回", "tou cai bai lian hui"),
            ("不解藏踪迹", "bu jie cang zong ji"),
            ("浮萍一道开", "fu ping yi dao kai")
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
        // 诗库里的《悯农》是「其二」（锄禾日当午）；id 沿用建库时的 minnong，成绩文件按 id 记最高分，不随标题改
        Poem("minnong", "悯农其二", "李绅", "唐", [
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
        Poem("minnong1", "悯农其一", "李绅", "唐", [
            ("春种一粒粟", "chun zhong yi li su"),
            ("秋收万颗子", "qiu shou wan ke zi"),
            ("四海无闲田", "si hai wu xian tian"),
            ("农夫犹饿死", "nong fu you e si")
        ]),
        Poem("feng", "风", "李峤", "唐", [
            ("解落三秋叶", "jie luo san qiu ye"),
            ("能开二月花", "neng kai er yue hua"),
            ("过江千尺浪", "guo jiang qian chi lang"),
            ("入竹万竿斜", "ru zhu wan gan xie")
        ]),
        Poem("luchai", "鹿柴", "王维", "唐", [
            ("空山不见人", "kong shan bu jian ren"),
            ("但闻人语响", "dan wen ren yu xiang"),
            ("返景入深林", "fan jing ru shen lin"),
            ("复照青苔上", "fu zhao qing tai shang")
        ]),
        Poem("gulangyuexing", "古朗月行（节选）", "李白", "唐", [
            ("小时不识月", "xiao shi bu shi yue"),
            ("呼作白玉盘", "hu zuo bai yu pan"),
            ("又疑瑶台镜", "you yi yao tai jing"),
            ("飞在青云端", "fei zai qing yun duan")
        ]),
        Poem("xunyinzhe", "寻隐者不遇", "贾岛", "唐", [
            ("松下问童子", "song xia wen tong zi"),
            ("言师采药去", "yan shi cai yao qu"),
            ("只在此山中", "zhi zai ci shan zhong"),
            ("云深不知处", "yun shen bu zhi chu")
        ]),
        Poem("meihua", "梅花", "王安石", "宋", [
            ("墙角数枝梅", "qiang jiao shu zhi mei"),
            ("凌寒独自开", "ling han du zi kai"),
            ("遥知不是雪", "yao zhi bu shi xue"),
            ("为有暗香来", "wei you an xiang lai")
        ]),
        Poem("yesushansi", "夜宿山寺", "李白", "唐", [
            ("危楼高百尺", "wei lou gao bai chi"),
            ("手可摘星辰", "shou ke zhai xing chen"),
            ("不敢高声语", "bu gan gao sheng yu"),
            ("恐惊天上人", "kong jing tian shang ren")
        ]),
        // 杜甫有两首《绝句》都收在小学课本里：这首是「迟日江山丽」，另一首七言的「两个黄鹂」在后面
        Poem("jueju2", "绝句（迟日江山丽）", "杜甫", "唐", [
            ("迟日江山丽", "chi ri jiang shan li"),
            ("春风花草香", "chun feng hua cao xiang"),
            ("泥融飞燕子", "ni rong fei yan zi"),
            ("沙暖睡鸳鸯", "sha nuan shui yuan yang")
        ]),
        Poem("jiangshangyuzhe", "江上渔者", "范仲淹", "宋", [
            ("江上往来人", "jiang shang wang lai ren"),
            ("但爱鲈鱼美", "dan ai lu yu mei"),
            ("君看一叶舟", "jun kan yi ye zhou"),
            ("出没风波里", "chu mo feng bo li")
        ]),
        Poem("suojian", "所见", "袁枚", "清", [
            ("牧童骑黄牛", "mu tong qi huang niu"),
            ("歌声振林樾", "ge sheng zhen lin yue"),
            ("意欲捕鸣蝉", "yi yu bu ming chan"),
            ("忽然闭口立", "hu ran bi kou li")
        ]),
        Poem("duzuojingtingshan", "独坐敬亭山", "李白", "唐", [
            ("众鸟高飞尽", "zhong niao gao fei jin"),
            ("孤云独去闲", "gu yun du qu xian"),
            ("相看两不厌", "xiang kan liang bu yan"),
            ("只有敬亭山", "zhi you jing ting shan")
        ]),
        Poem("sujiandejiang", "宿建德江", "孟浩然", "唐", [
            ("移舟泊烟渚", "yi zhou bo yan zhu"),
            ("日暮客愁新", "ri mu ke chou xin"),
            ("野旷天低树", "ye kuang tian di shu"),
            ("江清月近人", "jiang qing yue jin ren")
        ]),
        Poem("niaomingjian", "鸟鸣涧", "王维", "唐", [
            ("人闲桂花落", "ren xian gui hua luo"),
            ("夜静春山空", "ye jing chun shan kong"),
            ("月出惊山鸟", "yue chu jing shan niao"),
            ("时鸣春涧中", "shi ming chun jian zhong")
        ]),
        Poem("zhouyesuo", "舟夜书所见", "查慎行", "清", [
            ("月黑见渔灯", "yue hei jian yu deng"),
            ("孤光一点萤", "gu guang yi dian ying"),
            ("微微风簇浪", "wei wei feng cu lang"),
            ("散作满河星", "san zuo man he xing")
        ]),
        Poem("xiarijueju", "夏日绝句", "李清照", "宋", [
            ("生当作人杰", "sheng dang zuo ren jie"),
            ("死亦为鬼雄", "si yi wei gui xiong"),
            ("至今思项羽", "zhi jin si xiang yu"),
            ("不肯过江东", "bu ken guo jiang dong")
        ]),
        Poem("mashi", "马诗", "李贺", "唐", [
            ("大漠沙如雪", "da mo sha ru xue"),
            ("燕山月似钩", "yan shan yue si gou"),
            ("何当金络脑", "he dang jin luo nao"),
            ("快走踏清秋", "kuai zou ta qing qiu")
        ]),
        Poem("qibushi", "七步诗", "曹植", "三国", [
            ("煮豆燃豆萁", "zhu dou ran dou qi"),
            ("豆在釜中泣", "dou zai fu zhong qi"),
            ("本是同根生", "ben shi tong gen sheng"),
            ("相煎何太急", "xiang jian he tai ji")
        ]),
        Poem("fudeguyuancao", "赋得古原草送别（节选）", "白居易", "唐", [
            ("离离原上草", "li li yuan shang cao"),
            ("一岁一枯荣", "yi sui yi ku rong"),
            ("野火烧不尽", "ye huo shao bu jin"),
            ("春风吹又生", "chun feng chui you sheng")
        ]),
        Poem("saixiaqu", "塞下曲", "卢纶", "唐", [
            ("月黑雁飞高", "yue hei yan fei gao"),
            ("单于夜遁逃", "chan yu ye dun tao"),
            ("欲将轻骑逐", "yu jiang qing ji zhu"),
            ("大雪满弓刀", "da xue man gong dao")
        ]),
        // ── 词曲长短句（27 字，2★；行数 5–7，卡面自动分栏） ──
        Poem("yijiangnan", "忆江南", "白居易", "唐", [
            ("江南好", "jiang nan hao"),
            ("风景旧曾谙", "feng jing jiu ceng an"),
            ("日出江花红胜火", "ri chu jiang hua hong sheng huo"),
            ("春来江水绿如蓝", "chun lai jiang shui lv ru lan"),
            ("能不忆江南", "neng bu yi jiang nan")
        ]),
        Poem("yugezi", "渔歌子", "张志和", "唐", [
            ("西塞山前白鹭飞", "xi sai shan qian bai lu fei"),
            ("桃花流水鳜鱼肥", "tao hua liu shui gui yu fei"),
            ("青箬笠", "qing ruo li"),
            ("绿蓑衣", "lv suo yi"),
            ("斜风细雨不须归", "xie feng xi yu bu xu gui")
        ]),
        Poem("chilege", "敕勒歌", "佚名", "北朝", [
            ("敕勒川", "chi le chuan"),
            ("阴山下", "yin shan xia"),
            ("天似穹庐", "tian si qiong lu"),
            ("笼盖四野", "long gai si ye"),
            ("天苍苍", "tian cang cang"),
            ("野茫茫", "ye mang mang"),
            ("风吹草低见牛羊", "feng chui cao di xian niu yang")
        ]),
        // ── 七言绝句（28 字，2★；先放建库时就在的 12 首，再补教材其余篇目） ──
        Poem("zengwanglun", "赠汪伦", "李白", "唐", [
            ("李白乘舟将欲行", "li bai cheng zhou jiang yu xing"),
            ("忽闻岸上踏歌声", "hu wen an shang ta ge sheng"),
            ("桃花潭水深千尺", "tao hua tan shui shen qian chi"),
            ("不及汪伦送我情", "bu ji wang lun song wo qing")
        ]),
        Poem("yongliu", "咏柳", "贺知章", "唐", [
            ("碧玉妆成一树高", "bi yu zhuang cheng yi shu gao"),
            ("万条垂下绿丝绦", "wan tiao chui xia lv si tao"),
            ("不知细叶谁裁出", "bu zhi xi ye shui cai chu"),
            ("二月春风似剪刀", "er yue chun feng si jian dao")
        ]),
        Poem("wangtianmenshan", "望天门山", "李白", "唐", [
            ("天门中断楚江开", "tian men zhong duan chu jiang kai"),
            ("碧水东流至此回", "bi shui dong liu zhi ci hui"),
            ("两岸青山相对出", "liang an qing shan xiang dui chu"),
            ("孤帆一片日边来", "gu fan yi pian ri bian lai")
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
        Poem("jueju", "绝句（两个黄鹂鸣翠柳）", "杜甫", "唐", [
            ("两个黄鹂鸣翠柳", "liang ge huang li ming cui liu"),
            ("一行白鹭上青天", "yi hang bai lu shang qing tian"),
            ("窗含西岭千秋雪", "chuang han xi ling qian qiu xue"),
            ("门泊东吴万里船", "men bo dong wu wan li chuan")
        ]),
        Poem("shanxing", "山行", "杜牧", "唐", [
            ("远上寒山石径斜", "yuan shang han shan shi jing xie"),
            ("白云生处有人家", "bai yun sheng chu you ren jia"),
            ("停车坐爱枫林晚", "ting che zuo ai feng lin wan"),
            ("霜叶红于二月花", "shuang ye hong yu er yue hua")
        ]),
        Poem("jiuyuejiuri", "九月九日忆山东兄弟", "王维", "唐", [
            ("独在异乡为异客", "du zai yi xiang wei yi ke"),
            ("每逢佳节倍思亲", "mei feng jia jie bei si qin"),
            ("遥知兄弟登高处", "yao zhi xiong di deng gao chu"),
            ("遍插茱萸少一人", "bian cha zhu yu shao yi ren")
        ]),
        Poem("qingming", "清明", "杜牧", "唐", [
            ("清明时节雨纷纷", "qing ming shi jie yu fen fen"),
            ("路上行人欲断魂", "lu shang xing ren yu duan hun"),
            ("借问酒家何处有", "jie wen jiu jia he chu you"),
            ("牧童遥指杏花村", "mu tong yao zhi xing hua cun")
        ]),
        Poem("chunri", "春日", "朱熹", "宋", [
            ("胜日寻芳泗水滨", "sheng ri xun fang si shui bin"),
            ("无边光景一时新", "wu bian guang jing yi shi xin"),
            ("等闲识得东风面", "deng xian shi de dong feng mian"),
            ("万紫千红总是春", "wan zi qian hong zong shi chun")
        ]),
        Poem("tixilinbi", "题西林壁", "苏轼", "宋", [
            ("横看成岭侧成峰", "heng kan cheng ling ce cheng feng"),
            ("远近高低各不同", "yuan jin gao di ge bu tong"),
            ("不识庐山真面目", "bu shi lu shan zhen mian mu"),
            ("只缘身在此山中", "zhi yuan shen zai ci shan zhong")
        ]),
        Poem("huixiangoushu", "回乡偶书", "贺知章", "唐", [
            ("少小离家老大回", "shao xiao li jia lao da hui"),
            ("乡音无改鬓毛衰", "xiang yin wu gai bin mao shuai"),
            ("儿童相见不相识", "er tong xiang jian bu xiang shi"),
            ("笑问客从何处来", "xiao wen ke cong he chu lai")
        ]),
        Poem("liangzhouci", "凉州词", "王之涣", "唐", [
            ("黄河远上白云间", "huang he yuan shang bai yun jian"),
            ("一片孤城万仞山", "yi pian gu cheng wan ren shan"),
            ("羌笛何须怨杨柳", "qiang di he xu yuan yang liu"),
            ("春风不度玉门关", "chun feng bu du yu men guan")
        ]),
        Poem("liangzhouci2", "凉州词", "王翰", "唐", [
            ("葡萄美酒夜光杯", "pu tao mei jiu ye guang bei"),
            ("欲饮琵琶马上催", "yu yin pi pa ma shang cui"),
            ("醉卧沙场君莫笑", "zui wo sha chang jun mo xiao"),
            ("古来征战几人回", "gu lai zheng zhan ji ren hui")
        ]),
        Poem("chusai", "出塞", "王昌龄", "唐", [
            ("秦时明月汉时关", "qin shi ming yue han shi guan"),
            ("万里长征人未还", "wan li chang zheng ren wei huan"),
            ("但使龙城飞将在", "dan shi long cheng fei jiang zai"),
            ("不教胡马度阴山", "bu jiao hu ma du yin shan")
        ]),
        Poem("furonglou", "芙蓉楼送辛渐", "王昌龄", "唐", [
            ("寒雨连江夜入吴", "han yu lian jiang ye ru wu"),
            ("平明送客楚山孤", "ping ming song ke chu shan gu"),
            ("洛阳亲友如相问", "luo yang qin you ru xiang wen"),
            ("一片冰心在玉壶", "yi pian bing xin zai yu hu")
        ]),
        Poem("songyuaner", "送元二使安西", "王维", "唐", [
            ("渭城朝雨浥轻尘", "wei cheng zhao yu yi qing chen"),
            ("客舍青青柳色新", "ke she qing qing liu se xin"),
            ("劝君更尽一杯酒", "quan jun geng jin yi bei jiu"),
            ("西出阳关无故人", "xi chu yang guan wu gu ren")
        ]),
        Poem("huanghelou", "黄鹤楼送孟浩然之广陵", "李白", "唐", [
            ("故人西辞黄鹤楼", "gu ren xi ci huang he lou"),
            ("烟花三月下扬州", "yan hua san yue xia yang zhou"),
            ("孤帆远影碧空尽", "gu fan yuan ying bi kong jin"),
            ("唯见长江天际流", "wei jian chang jiang tian ji liu")
        ]),
        Poem("zaofabaidi", "早发白帝城", "李白", "唐", [
            ("朝辞白帝彩云间", "zhao ci bai di cai yun jian"),
            ("千里江陵一日还", "qian li jiang ling yi ri huan"),
            ("两岸猿声啼不住", "liang an yuan sheng ti bu zhu"),
            ("轻舟已过万重山", "qing zhou yi guo wan chong shan")
        ]),
        Poem("biedongda", "别董大", "高适", "唐", [
            ("千里黄云白日曛", "qian li huang yun bai ri xun"),
            ("北风吹雁雪纷纷", "bei feng chui yan xue fen fen"),
            ("莫愁前路无知己", "mo chou qian lu wu zhi ji"),
            ("天下谁人不识君", "tian xia shui ren bu shi jun")
        ]),
        Poem("jiangpanbuduxunhua", "江畔独步寻花", "杜甫", "唐", [
            ("黄四娘家花满蹊", "huang si niang jia hua man xi"),
            ("千朵万朵压枝低", "qian duo wan duo ya zhi di"),
            ("留连戏蝶时时舞", "liu lian xi die shi shi wu"),
            ("自在娇莺恰恰啼", "zi zai jiao ying qia qia ti")
        ]),
        Poem("fengqiaoyebo", "枫桥夜泊", "张继", "唐", [
            ("月落乌啼霜满天", "yue luo wu ti shuang man tian"),
            ("江枫渔火对愁眠", "jiang feng yu huo dui chou mian"),
            ("姑苏城外寒山寺", "gu su cheng wai han shan si"),
            ("夜半钟声到客船", "ye ban zhong sheng dao ke chuan")
        ]),
        Poem("wangdongting", "望洞庭", "刘禹锡", "唐", [
            ("湖光秋月两相和", "hu guang qiu yue liang xiang he"),
            ("潭面无风镜未磨", "tan mian wu feng jing wei mo"),
            ("遥望洞庭山水翠", "yao wang dong ting shan shui cui"),
            ("白银盘里一青螺", "bai yin pan li yi qing luo")
        ]),
        Poem("langtaosha", "浪淘沙", "刘禹锡", "唐", [
            ("九曲黄河万里沙", "jiu qu huang he wan li sha"),
            ("浪淘风簸自天涯", "lang tao feng bo zi tian ya"),
            ("如今直上银河去", "ru jin zhi shang yin he qu"),
            ("同到牵牛织女家", "tong dao qian niu zhi nv jia")
        ]),
        Poem("mujiangyin", "暮江吟", "白居易", "唐", [
            ("一道残阳铺水中", "yi dao can yang pu shui zhong"),
            ("半江瑟瑟半江红", "ban jiang se se ban jiang hong"),
            ("可怜九月初三夜", "ke lian jiu yue chu san ye"),
            ("露似真珠月似弓", "lu si zhen zhu yue si gong")
        ]),
        Poem("dalinsitaohua", "大林寺桃花", "白居易", "唐", [
            ("人间四月芳菲尽", "ren jian si yue fang fei jin"),
            ("山寺桃花始盛开", "shan si tao hua shi sheng kai"),
            ("长恨春归无觅处", "chang hen chun gui wu mi chu"),
            ("不知转入此中来", "bu zhi zhuan ru ci zhong lai")
        ]),
        Poem("chuzhouxijian", "滁州西涧", "韦应物", "唐", [
            ("独怜幽草涧边生", "du lian you cao jian bian sheng"),
            ("上有黄鹂深树鸣", "shang you huang li shen shu ming"),
            ("春潮带雨晚来急", "chun chao dai yu wan lai ji"),
            ("野渡无人舟自横", "ye du wu ren zhou zi heng")
        ]),
        Poem("yuanri", "元日", "王安石", "宋", [
            ("爆竹声中一岁除", "bao zhu sheng zhong yi sui chu"),
            ("春风送暖入屠苏", "chun feng song nuan ru tu su"),
            ("千门万户曈曈日", "qian men wan hu tong tong ri"),
            ("总把新桃换旧符", "zong ba xin tao huan jiu fu")
        ]),
        Poem("bochuanguazhou", "泊船瓜洲", "王安石", "宋", [
            ("京口瓜洲一水间", "jing kou gua zhou yi shui jian"),
            ("钟山只隔数重山", "zhong shan zhi ge shu chong shan"),
            ("春风又绿江南岸", "chun feng you lv jiang nan an"),
            ("明月何时照我还", "ming yue he shi zhao wo huan")
        ]),
        Poem("shuhuyinxiansheng", "书湖阴先生壁", "王安石", "宋", [
            ("茅檐长扫净无苔", "mao yan chang sao jing wu tai"),
            ("花木成畦手自栽", "hua mu cheng qi shou zi zai"),
            ("一水护田将绿绕", "yi shui hu tian jiang lv rao"),
            ("两山排闼送青来", "liang shan pai ta song qing lai")
        ]),
        Poem("wanghulou", "六月二十七日望湖楼醉书", "苏轼", "宋", [
            ("黑云翻墨未遮山", "hei yun fan mo wei zhe shan"),
            ("白雨跳珠乱入船", "bai yu tiao zhu luan ru chuan"),
            ("卷地风来忽吹散", "juan di feng lai hu chui san"),
            ("望湖楼下水如天", "wang hu lou xia shui ru tian")
        ]),
        Poem("yinhushang", "饮湖上初晴后雨", "苏轼", "宋", [
            ("水光潋滟晴方好", "shui guang lian yan qing fang hao"),
            ("山色空蒙雨亦奇", "shan se kong meng yu yi qi"),
            ("欲把西湖比西子", "yu ba xi hu bi xi zi"),
            ("淡妆浓抹总相宜", "dan zhuang nong mo zong xiang yi")
        ]),
        Poem("huichongchunjiang", "惠崇春江晚景", "苏轼", "宋", [
            ("竹外桃花三两枝", "zhu wai tao hua san liang zhi"),
            ("春江水暖鸭先知", "chun jiang shui nuan ya xian zhi"),
            ("蒌蒿满地芦芽短", "lou hao man di lu ya duan"),
            ("正是河豚欲上时", "zheng shi he tun yu shang shi")
        ]),
        Poem("zengliujingwen", "赠刘景文", "苏轼", "宋", [
            ("荷尽已无擎雨盖", "he jin yi wu qing yu gai"),
            ("菊残犹有傲霜枝", "ju can you you ao shuang zhi"),
            ("一年好景君须记", "yi nian hao jing jun xu ji"),
            ("最是橙黄橘绿时", "zui shi cheng huang ju lv shi")
        ]),
        Poem("shier", "示儿", "陆游", "宋", [
            ("死去元知万事空", "si qu yuan zhi wan shi kong"),
            ("但悲不见九州同", "dan bei bu jian jiu zhou tong"),
            ("王师北定中原日", "wang shi bei ding zhong yuan ri"),
            ("家祭无忘告乃翁", "jia ji wu wang gao nai weng")
        ]),
        Poem("qiuyejiangxiao", "秋夜将晓出篱门迎凉有感", "陆游", "宋", [
            ("三万里河东入海", "san wan li he dong ru hai"),
            ("五千仞岳上摩天", "wu qian ren yue shang mo tian"),
            ("遗民泪尽胡尘里", "yi min lei jin hu chen li"),
            ("南望王师又一年", "nan wang wang shi you yi nian")
        ]),
        Poem("sishitianyuan", "四时田园杂兴（其三十一）", "范成大", "宋", [
            ("昼出耘田夜绩麻", "zhou chu yun tian ye ji ma"),
            ("村庄儿女各当家", "cun zhuang er nv ge dang jia"),
            ("童孙未解供耕织", "tong sun wei jie gong geng zhi"),
            ("也傍桑阴学种瓜", "ye bang sang yin xue zhong gua")
        ]),
        Poem("suxinshixugongdian", "宿新市徐公店", "杨万里", "宋", [
            ("篱落疏疏一径深", "li luo shu shu yi jing shen"),
            ("树头新绿未成阴", "shu tou xin lv wei cheng yin"),
            ("儿童急走追黄蝶", "er tong ji zou zhui huang die"),
            ("飞入菜花无处寻", "fei ru cai hua wu chu xun")
        ]),
        Poem("xiaochujingci", "晓出净慈寺送林子方", "杨万里", "宋", [
            ("毕竟西湖六月中", "bi jing xi hu liu yue zhong"),
            ("风光不与四时同", "feng guang bu yu si shi tong"),
            ("接天莲叶无穷碧", "jie tian lian ye wu qiong bi"),
            ("映日荷花别样红", "ying ri he hua bie yang hong")
        ]),
        Poem("zhizinongbing", "稚子弄冰", "杨万里", "宋", [
            ("稚子金盆脱晓冰", "zhi zi jin pen tuo xiao bing"),
            ("彩丝穿取当银钲", "cai si chuan qu dang yin zheng"),
            ("敲成玉磬穿林响", "qiao cheng yu qing chuan lin xiang"),
            ("忽作玻璃碎地声", "hu zuo bo li sui di sheng")
        ]),
        Poem("cunwan", "村晚", "雷震", "宋", [
            ("草满池塘水满陂", "cao man chi tang shui man bei"),
            ("山衔落日浸寒漪", "shan xian luo ri jin han yi"),
            ("牧童归去横牛背", "mu tong gui qu heng niu bei"),
            ("短笛无腔信口吹", "duan di wu qiang xin kou chui")
        ]),
        Poem("sanqudaozhong", "三衢道中", "曾几", "宋", [
            ("梅子黄时日日晴", "mei zi huang shi ri ri qing"),
            ("小溪泛尽却山行", "xiao xi fan jin que shan xing"),
            ("绿阴不减来时路", "lv yin bu jian lai shi lu"),
            ("添得黄鹂四五声", "tian de huang li si wu sheng")
        ]),
        Poem("xuemei", "雪梅", "卢钺", "宋", [
            ("梅雪争春未肯降", "mei xue zheng chun wei ken xiang"),
            ("骚人阁笔费评章", "sao ren ge bi fei ping zhang"),
            ("梅须逊雪三分白", "mei xu xun xue san fen bai"),
            ("雪却输梅一段香", "xue que shu mei yi duan xiang")
        ]),
        Poem("hanshi", "寒食", "韩翃", "唐", [
            ("春城无处不飞花", "chun cheng wu chu bu fei hua"),
            ("寒食东风御柳斜", "han shi dong feng yu liu xie"),
            ("日暮汉宫传蜡烛", "ri mu han gong chuan la zhu"),
            ("轻烟散入五侯家", "qing yan san ru wu hou jia")
        ]),
        Poem("shiwuyewangyue", "十五夜望月", "王建", "唐", [
            ("中庭地白树栖鸦", "zhong ting di bai shu qi ya"),
            ("冷露无声湿桂花", "leng lu wu sheng shi gui hua"),
            ("今夜月明人尽望", "jin ye yue ming ren jin wang"),
            ("不知秋思落谁家", "bu zhi qiu si luo shui jia")
        ]),
        Poem("qiqiao", "乞巧", "林杰", "唐", [
            ("七夕今宵看碧霄", "qi xi jin xiao kan bi xiao"),
            ("牵牛织女渡河桥", "qian niu zhi nv du he qiao"),
            ("家家乞巧望秋月", "jia jia qi qiao wang qiu yue"),
            ("穿尽红丝几万条", "chuan jin hong si ji wan tiao")
        ]),
        Poem("change", "嫦娥", "李商隐", "唐", [
            ("云母屏风烛影深", "yun mu ping feng zhu ying shen"),
            ("长河渐落晓星沉", "chang he jian luo xiao xing chen"),
            ("嫦娥应悔偷灵药", "chang e ying hui tou ling yao"),
            ("碧海青天夜夜心", "bi hai qing tian ye ye xin")
        ]),
        Poem("zaochunchengshuibu", "早春呈水部张十八员外", "韩愈", "唐", [
            ("天街小雨润如酥", "tian jie xiao yu run ru su"),
            ("草色遥看近却无", "cao se yao kan jin que wu"),
            ("最是一年春好处", "zui shi yi nian chun hao chu"),
            ("绝胜烟柳满皇都", "jue sheng yan liu man huang du")
        ]),
        Poem("guanshuyougan", "观书有感", "朱熹", "宋", [
            ("半亩方塘一鉴开", "ban mu fang tang yi jian kai"),
            ("天光云影共徘徊", "tian guang yun ying gong pai huai"),
            ("问渠那得清如许", "wen qu na de qing ru xu"),
            ("为有源头活水来", "wei you yuan tou huo shui lai")
        ]),
        Poem("tilinandi", "题临安邸", "林升", "宋", [
            ("山外青山楼外楼", "shan wai qing shan lou wai lou"),
            ("西湖歌舞几时休", "xi hu ge wu ji shi xiu"),
            ("暖风熏得游人醉", "nuan feng xun de you ren zui"),
            ("直把杭州作汴州", "zhi ba hang zhou zuo bian zhou")
        ]),
        Poem("youyuanbuzhi", "游园不值", "叶绍翁", "宋", [
            ("应怜屐齿印苍苔", "ying lian ji chi yin cang tai"),
            ("小扣柴扉久不开", "xiao kou chai fei jiu bu kai"),
            ("春色满园关不住", "chun se man yuan guan bu zhu"),
            ("一枝红杏出墙来", "yi zhi hong xing chu qiang lai")
        ]),
        Poem("yeshusuojian", "夜书所见", "叶绍翁", "宋", [
            ("萧萧梧叶送寒声", "xiao xiao wu ye song han sheng"),
            ("江上秋风动客情", "jiang shang qiu feng dong ke qing"),
            ("知有儿童挑促织", "zhi you er tong tiao cu zhi"),
            ("夜深篱落一灯明", "ye shen li luo yi deng ming")
        ]),
        Poem("xiangcunsyue", "乡村四月", "翁卷", "宋", [
            ("绿遍山原白满川", "lv bian shan yuan bai man chuan"),
            ("子规声里雨如烟", "zi gui sheng li yu ru yan"),
            ("乡村四月闲人少", "xiang cun si yue xian ren shao"),
            ("才了蚕桑又插田", "cai liao can sang you cha tian")
        ]),
        Poem("momei", "墨梅", "王冕", "元", [
            ("吾家洗砚池头树", "wu jia xi yan chi tou shu"),
            ("个个花开淡墨痕", "ge ge hua kai dan mo hen"),
            ("不要人夸好颜色", "bu yao ren kua hao yan se"),
            ("只留清气满乾坤", "zhi liu qing qi man qian kun")
        ]),
        Poem("shihuiyin", "石灰吟", "于谦", "明", [
            ("千锤万凿出深山", "qian chui wan zao chu shen shan"),
            ("烈火焚烧若等闲", "lie huo fen shao ruo deng xian"),
            ("粉骨碎身浑不怕", "fen gu sui shen hun bu pa"),
            ("要留清白在人间", "yao liu qing bai zai ren jian")
        ]),
        Poem("zhushi", "竹石", "郑燮", "清", [
            ("咬定青山不放松", "yao ding qing shan bu fang song"),
            ("立根原在破岩中", "li gen yuan zai po yan zhong"),
            ("千磨万击还坚劲", "qian mo wan ji hai jian jing"),
            ("任尔东西南北风", "ren er dong xi nan bei feng")
        ]),
        Poem("jihaizashi", "己亥杂诗", "龚自珍", "清", [
            ("九州生气恃风雷", "jiu zhou sheng qi shi feng lei"),
            ("万马齐喑究可哀", "wan ma qi yin jiu ke ai"),
            ("我劝天公重抖擞", "wo quan tian gong chong dou sou"),
            ("不拘一格降人才", "bu ju yi ge jiang ren cai")
        ]),
        Poem("feng2", "蜂", "罗隐", "唐", [
            ("不论平地与山尖", "bu lun ping di yu shan jian"),
            ("无限风光尽被占", "wu xian feng guang jin bei zhan"),
            ("采得百花成蜜后", "cai de bai hua cheng mi hou"),
            ("为谁辛苦为谁甜", "wei shui xin ku wei shui tian")
        ]),
        Poem("jiangnancun", "江南春", "杜牧", "唐", [
            ("千里莺啼绿映红", "qian li ying ti lv ying hong"),
            ("水村山郭酒旗风", "shui cun shan guo jiu qi feng"),
            ("南朝四百八十寺", "nan chao si bai ba shi si"),
            ("多少楼台烟雨中", "duo shao lou tai yan yu zhong")
        ]),
        Poem("congjunxing", "从军行", "王昌龄", "唐", [
            ("青海长云暗雪山", "qing hai chang yun an xue shan"),
            ("孤城遥望玉门关", "gu cheng yao wang yu men guan"),
            ("黄沙百战穿金甲", "huang sha bai zhan chuan jin jia"),
            ("不破楼兰终不还", "bu po lou lan zhong bu huan")
        ]),
        Poem("huaji", "画鸡", "唐寅", "明", [
            ("头上红冠不用裁", "tou shang hong guan bu yong cai"),
            ("满身雪白走将来", "man shen xue bai zou jiang lai"),
            ("平生不敢轻言语", "ping sheng bu gan qing yan yu"),
            ("一叫千门万户开", "yi jiao qian men wan hu kai")
        ]),
        Poem("xiaoerchuidiao", "小儿垂钓", "胡令能", "唐", [
            ("蓬头稚子学垂纶", "peng tou zhi zi xue chui lun"),
            ("侧坐莓苔草映身", "ce zuo mei tai cao ying shen"),
            ("路人借问遥招手", "lu ren jie wen yao zhao shou"),
            ("怕得鱼惊不应人", "pa de yu jing bu ying ren")
        ]),
        Poem("cailianqu", "采莲曲", "王昌龄", "唐", [
            ("荷叶罗裙一色裁", "he ye luo qun yi se cai"),
            ("芙蓉向脸两边开", "fu rong xiang lian liang bian kai"),
            ("乱入池中看不见", "luan ru chi zhong kan bu jian"),
            ("闻歌始觉有人来", "wen ge shi jue you ren lai")
        ]),
        // ── 长诗与词曲（30 字以上，3★；7 行以上卡面自动分左右两栏） ──
        Poem("youziyin", "游子吟", "孟郊", "唐", [
            ("慈母手中线", "ci mu shou zhong xian"),
            ("游子身上衣", "you zi shen shang yi"),
            ("临行密密缝", "lin xing mi mi feng"),
            ("意恐迟迟归", "yi kong chi chi gui"),
            ("谁言寸草心", "shui yan cun cao xin"),
            ("报得三春晖", "bao de san chun hui")
        ]),
        Poem("jiangnan", "江南", "佚名", "汉", [
            ("江南可采莲", "jiang nan ke cai lian"),
            ("莲叶何田田", "lian ye he tian tian"),
            ("鱼戏莲叶间", "yu xi lian ye jian"),
            ("鱼戏莲叶东", "yu xi lian ye dong"),
            ("鱼戏莲叶西", "yu xi lian ye xi"),
            ("鱼戏莲叶南", "yu xi lian ye nan"),
            ("鱼戏莲叶北", "yu xi lian ye bei")
        ]),
        Poem("chunyexiyu", "春夜喜雨", "杜甫", "唐", [
            ("好雨知时节", "hao yu zhi shi jie"),
            ("当春乃发生", "dang chun nai fa sheng"),
            ("随风潜入夜", "sui feng qian ru ye"),
            ("润物细无声", "run wu xi wu sheng"),
            ("野径云俱黑", "ye jing yun ju hei"),
            ("江船火独明", "jiang chuan huo du ming"),
            ("晓看红湿处", "xiao kan hong shi chu"),
            ("花重锦官城", "hua zhong jin guan cheng")
        ]),
        Poem("shanjuqiuming", "山居秋暝", "王维", "唐", [
            ("空山新雨后", "kong shan xin yu hou"),
            ("天气晚来秋", "tian qi wan lai qiu"),
            ("明月松间照", "ming yue song jian zhao"),
            ("清泉石上流", "qing quan shi shang liu"),
            ("竹喧归浣女", "zhu xuan gui huan nv"),
            ("莲动下渔舟", "lian dong xia yu zhou"),
            ("随意春芳歇", "sui yi chun fang xie"),
            ("王孙自可留", "wang sun zi ke liu")
        ]),
        Poem("guogurenzhuang", "过故人庄", "孟浩然", "唐", [
            ("故人具鸡黍", "gu ren ju ji shu"),
            ("邀我至田家", "yao wo zhi tian jia"),
            ("绿树村边合", "lv shu cun bian he"),
            ("青山郭外斜", "qing shan guo wai xie"),
            ("开轩面场圃", "kai xuan mian chang pu"),
            ("把酒话桑麻", "ba jiu hua sang ma"),
            ("待到重阳日", "dai dao chong yang ri"),
            ("还来就菊花", "huan lai jiu ju hua")
        ]),
        Poem("huanxisha", "浣溪沙", "苏轼", "宋", [
            ("山下兰芽短浸溪", "shan xia lan ya duan jin xi"),
            ("松间沙路净无泥", "song jian sha lu jing wu ni"),
            ("萧萧暮雨子规啼", "xiao xiao mu yu zi gui ti"),
            ("谁道人生无再少", "shui dao ren sheng wu zai shao"),
            ("门前流水尚能西", "men qian liu shui shang neng xi"),
            ("休将白发唱黄鸡", "xiu jiang bai fa chang huang ji")
        ]),
        Poem("busuanzisongbao", "卜算子送鲍浩然之浙东", "王观", "宋", [
            ("水是眼波横", "shui shi yan bo heng"),
            ("山是眉峰聚", "shan shi mei feng ju"),
            ("欲问行人去那边", "yu wen xing ren qu na bian"),
            ("眉眼盈盈处", "mei yan ying ying chu"),
            ("才始送春归", "cai shi song chun gui"),
            ("又送君归去", "you song jun gui qu"),
            ("若到江南赶上春", "ruo dao jiang nan gan shang chun"),
            ("千万和春住", "qian wan he chun zhu")
        ]),
        Poem("qingpingyuecunju", "清平乐村居", "辛弃疾", "宋", [
            ("茅檐低小", "mao yan di xiao"),
            ("溪上青青草", "xi shang qing qing cao"),
            ("醉里吴音相媚好", "zui li wu yin xiang mei hao"),
            ("白发谁家翁媪", "bai fa shui jia weng ao"),
            ("大儿锄豆溪东", "da er chu dou xi dong"),
            ("中儿正织鸡笼", "zhong er zheng zhi ji long"),
            ("最喜小儿亡赖", "zui xi xiao er wu lai"),
            ("溪头卧剥莲蓬", "xi tou wo bao lian peng")
        ]),
        Poem("qingpingyuechungui", "清平乐春归何处", "黄庭坚", "宋", [
            ("春归何处", "chun gui he chu"),
            ("寂寞无行路", "ji mo wu xing lu"),
            ("若有人知春去处", "ruo you ren zhi chun qu chu"),
            ("唤取归来同住", "huan qu gui lai tong zhu"),
            ("春无踪迹谁知", "chun wu zong ji shui zhi"),
            ("除非问取黄鹂", "chu fei wen qu huang li"),
            ("百啭无人能解", "bai zhuan wu ren neng jie"),
            ("因风飞过蔷薇", "yin feng fei guo qiang wei")
        ]),
        Poem("changgexing", "长歌行", "佚名", "汉", [
            ("青青园中葵", "qing qing yuan zhong kui"),
            ("朝露待日晞", "zhao lu dai ri xi"),
            ("阳春布德泽", "yang chun bu de ze"),
            ("万物生光辉", "wan wu sheng guang hui"),
            ("常恐秋节至", "chang kong qiu jie zhi"),
            ("焜黄华叶衰", "kun huang hua ye shuai"),
            ("百川东到海", "bai chuan dong dao hai"),
            ("何时复西归", "he shi fu xi gui"),
            ("少壮不努力", "shao zhuang bu nu li"),
            ("老大徒伤悲", "lao da tu shang bei")
        ]),
        Poem("xijiangyue", "西江月夜行黄沙道中", "辛弃疾", "宋", [
            ("明月别枝惊鹊", "ming yue bie zhi jing que"),
            ("清风半夜鸣蝉", "qing feng ban ye ming chan"),
            ("稻花香里说丰年", "dao hua xiang li shuo feng nian"),
            ("听取蛙声一片", "ting qu wa sheng yi pian"),
            ("七八个星天外", "qi ba ge xing tian wai"),
            ("两三点雨山前", "liang san dian yu shan qian"),
            ("旧时茅店社林边", "jiu shi mao dian she lin bian"),
            ("路转溪桥忽见", "lu zhuan xi qiao hu xian")
        ]),
        Poem("tiaotiaoqianniuxing", "迢迢牵牛星", "佚名", "汉", [
            ("迢迢牵牛星", "tiao tiao qian niu xing"),
            ("皎皎河汉女", "jiao jiao he han nv"),
            ("纤纤擢素手", "xian xian zhuo su shou"),
            ("札札弄机杼", "zha zha nong ji zhu"),
            ("终日不成章", "zhong ri bu cheng zhang"),
            ("泣涕零如雨", "qi ti ling ru yu"),
            ("河汉清且浅", "he han qing qie qian"),
            ("相去复几许", "xiang qu fu ji xu"),
            ("盈盈一水间", "ying ying yi shui jian"),
            ("脉脉不得语", "mo mo bu de yu")
        ]),
        Poem("wenjuanguan", "闻官军收河南河北", "杜甫", "唐", [
            ("剑外忽传收蓟北", "jian wai hu chuan shou ji bei"),
            ("初闻涕泪满衣裳", "chu wen ti lei man yi chang"),
            ("却看妻子愁何在", "que kan qi zi chou he zai"),
            ("漫卷诗书喜欲狂", "man juan shi shu xi yu kuang"),
            ("白日放歌须纵酒", "bai ri fang ge xu zong jiu"),
            ("青春作伴好还乡", "qing chun zuo ban hao huan xiang"),
            ("即从巴峡穿巫峡", "ji cong ba xia chuan wu xia"),
            ("便下襄阳向洛阳", "bian xia xiang yang xiang luo yang")
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
