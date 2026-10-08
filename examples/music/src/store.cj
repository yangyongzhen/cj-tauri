package music_app

import std.fs.*
import stdx.encoding.json.*
import cjTauri.*

/**
 * 本机收藏库（收藏歌曲 + 最近播放）——落一个 JSON 文件在项目根
 *
 * 为什么收藏要落盘而不是只放页面的内存里：这是**用户资产**，重启应用必须还在；
 * 而且「收藏 → 分享歌单」这条主线上，分享出去的内容正是这份收藏。
 * 与 examples/typing-poem 的成绩文件同一套路（都是本机文件、都以项目根为工作目录）。
 *
 * 文件形状：`{ "songs": [ <后台返回的歌曲对象原样>… ], "recent": [ … ] }`
 * 歌曲对象不做字段裁剪——页面拿到的就是后端的 `{sid, song, sing, url, cover}`，
 * 存回来也一样，省掉一层「存的时候改名、读的时候再改回来」的映射（那种地方最容易悄悄丢字段）。
 */
public class MusicStore {
    private let path: String
    private var root: JsonObject

    public init(path: String) {
        this.path = path
        this.root = JsonObject()
        this.load()
    }

    /**
     * 读盘
     *
     * 读不到（第一次跑）与读坏都**不是致命错误**：前者是正常状态不打日志，后者留一行 stderr
     * 再从空开始——收藏文件不该有能力阻止应用启动。
     */
    private func load(): Unit {
        try {
            let text = String.fromUtf8(File.readFrom(this.path))
            let parsed = JsonValue.fromStr(text)
            match (parsed.kind()) {
                case JsonKind.JsObject => this.root = parsed.asObject()
                case _ => eprintln("[music] 收藏文件不是 JSON 对象，本轮从空开始：${this.path}")
            }
        } catch (e: Exception) {
            // 第一次跑就是这条路径——没有收藏文件是正常状态，不是错误
        }
    }

    /** 读一个数组字段；缺失 / 类型不对都回空数组（页面按数组用，不必判 null） */
    private func arrayOf(key: String): JsonValue {
        match (this.root.get(key)) {
            case Some(v) =>
                match (v.kind()) {
                    case JsonKind.JsArray => return v
                    case _ => return JsonArray()
                }
            case None => return JsonArray()
        }
    }

    /** 收藏的歌曲（数组） */
    func songs(): JsonValue {
        return this.arrayOf("songs")
    }

    /** 最近播放（数组，页面自己裁长度） */
    func recent(): JsonValue {
        return this.arrayOf("recent")
    }

    /** 整段替换一个字段（页面交上来的就是完整数组，主机侧不做增删改） */
    func setField(key: String, value: JsonValue): Unit {
        this.root.put(key, value)
    }

    /** 某个数组字段当前的条数（只用于打日志取证） */
    func countOf(key: String): Int64 {
        return this.arrayOf(key).asArray().size()
    }

    func pathOf(): String {
        return this.path
    }

    /** 覆盖写盘；失败只留一行 stderr 并返回 false（页面据此提示「本轮只在内存里」） */
    func save(): Bool {
        try {
            // File.writeTo 是覆盖写：文件已存在会截断，不需要先删
            File.writeTo(this.path, this.root.toJsonString().toArray())
            return true
        } catch (e: Exception) {
            eprintln("[music] 收藏写盘失败：${e}（路径 ${this.path}，本轮收藏只在内存里）")
            return false
        }
    }
}
