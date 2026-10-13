package cjTauri.tests

import cjTauri.*
import cjTauri.plugins.*
import std.collection.*
import std.fs.*
import std.sync.*
import stdx.encoding.json.*
import std.unittest.*
import std.unittest.testmacro.*

/*
 * store 插件单元测试：StoreBackend 的读写删 / keys / 原子写残留 / 损坏文件回落 / 并发写
 * + 命令面参数校验 + 命名权限集的闸门。
 *
 * 纯仓颉插件（零 C 桥），所以这里能测到「真实落盘」——比 serial 的单测多覆盖一层。
 * 临时文件全部放 /tmp（按固定名复用），不在仓库里留测试产物。
 */

const STORE_T_BASIC: String = "/tmp/store-unit-test-basic.json"
const STORE_T_CMD: String = "/tmp/store-unit-test-cmd.json"
const STORE_T_BAD: String = "/tmp/store-unit-test-bad.json"
const STORE_T_CONC: String = "/tmp/store-unit-test-conc.json"
// keys/clear 用例必须独享文件：basic 文件里留着前面用例写的键，共享会让 size 断言失真
const STORE_T_KEYS: String = "/tmp/store-unit-test-keys.json"

/** 取一条 store 命令处理器（插件带自定义路径，测试互不串文件） */
func storeCmd(short: String): CommandHandler {
    return StorePlugin(STORE_T_CMD).commands().get(short).getOrThrow()
}

/** 直接调命令，把 CommandException 的原文取出来（没抛就返回空串）*/
func storeErrOf(short: String, args: JsonObject): String {
    try {
        storeCmd(short).handle("store:${short}", args, IpcContext("main", IpcHub()))
        return ""
    } catch (e: CommandException) {
        return e.message
    }
}

func storeArgs1(key: String): JsonObject {
    var o = JsonObject()
    o.put("key", JsonString(key))
    return o
}

@Test
func testStorePluginSurface(): Unit {
    let p = StorePlugin()
    @Expect(p.name(), "store")
    let names = pluginCommandNames(p)
    @Expect(names.size, 5)
    var found = 0
    for (n in names) {
        if (n == "store:get" || n == "store:set" || n == "store:delete" || n == "store:keys" || n == "store:clear") {
            found++
        }
    }
    @Expect(found, 5)
}

@Test
func testStorePluginShimTargetsItsOwnNamespace(): Unit {
    let js = StorePlugin().jsShim()
    @Expect(js.contains("t.store"), true)
    @Expect(js.contains("'store:get'"), true)
    @Expect(js.contains("'store:set'"), true)
    @Expect(js.contains("'store:delete'"), true)
    @Expect(js.contains("'store:clear'"), true)
}

@Test
func testStorePermissionSetsGateWrites(): Unit {
    // 命名集要经 pluginPermissionSets 看（框架注册的是补全名，permissions() 只给短名）
    let sets = pluginPermissionSets(StorePlugin())
    @Expect(sets.size, 2)
    let ro = sets.get("store:readonly").getOrThrow()
    @Expect(ro.size, 2)
    // readonly 不含写：只想读的应用引用它，写能力不会被顺带打开
    var hasWrite = false
    for (n in ro) {
        if (n == "store:set" || n == "store:delete" || n == "store:clear") {
            hasWrite = true
        }
    }
    @Expect(hasWrite, false)
    @Expect(sets.get("store:default").getOrThrow().size, 5)
}

@Test
func testStoreSetGetRoundtripPersistsToDisk(): Unit {
    let path = STORE_T_BASIC
    let s1 = StoreBackend(path)
    let r1 = s1.set("theme", JsonString("dark"))
    @Expect(r1, true)
    let r2 = s1.set("count", JsonInt(3))
    @Expect(r2, true)
    // 新开一个 backend（=模拟应用重启）：数据必须从盘上回来
    let s2 = StoreBackend(path)
    // get 的返回就是 JsonValue（缺失时是 JSON null 或给定的 default），直接用
    @Expect(s2.get("theme", false, JsonBool(false)).asString().getValue(), "dark")
    @Expect(s2.get("count", false, JsonBool(false)).asInt().getValue(), 3)
}

@Test
func testStoreGetMissingDefaultAndNull(): Unit {
    let s = StoreBackend(STORE_T_BASIC)
    // 没给 default：回 JSON null（不是抛错）。JsonKind 这个 enum 连 == 都没定义
    // （invalid binary operator，实测 2026-10-09），比较一律用 match（music/serial 同款模式）
    let missKind = s.get("no-such-key", false, JsonBool(false)).kind()
    var missOk = false
    match (missKind) {
        case JsonKind.JsNull => missOk = true
        case _ => ()
    }
    @Expect(missOk, true)
    // 给了 default：原样返回
    @Expect(s.get("no-such-key", true, JsonString("fallback")).asString().getValue(), "fallback")
}

@Test
func testStoreDeleteReportsExisted(): Unit {
    let s = StoreBackend(STORE_T_BASIC)
    let r = s.set("gone-soon", JsonBool(true))
    @Expect(r, true)
    let (existed1, saved1) = s.delete("gone-soon")
    @Expect(existed1, true)
    @Expect(saved1, true)
    // 再删一次：本来就没有，existed=false（页面据此区分「删了」与「没有过」）
    let (existed2, saved2) = s.delete("gone-soon")
    @Expect(existed2, false)
    @Expect(saved2, true)
}

@Test
func testStoreKeysSortedAndClearCounts(): Unit {
    let s = StoreBackend(STORE_T_KEYS)
    let r1 = s.set("zebra", JsonInt(1))
    @Expect(r1, true)
    let r2 = s.set("alpha", JsonInt(2))
    @Expect(r2, true)
    let r3 = s.set("mid", JsonInt(3))
    @Expect(r3, true)
    let ks = s.keys()
    @Expect(ks.size, 3)
    @Expect(ks[0], "alpha")
    @Expect(ks[1], "mid")
    @Expect(ks[2], "zebra")
    let (cleared, saved) = s.clear()
    @Expect(cleared, 3)
    @Expect(saved, true)
    @Expect(s.keys().size, 0)
    // 清空后重启：仍是空的
    @Expect(StoreBackend(STORE_T_KEYS).keys().size, 0)
}

@Test
func testStoreAtomicWriteLeavesNoTmpBehind(): Unit {
    let path = STORE_T_BASIC
    let s = StoreBackend(path)
    let r = s.set("atomic", JsonBool(true))
    @Expect(r, true)
    // 原子写的中间产物必须已经被 rename 走，不能残留
    @Expect(exists(path + ".tmp"), false)
    // 文件本体是合法 JSON 对象（页面/人都能直接读）
    let parsed = JsonValue.fromStr(String.fromUtf8(File.readFrom(path)))
    let roundKind = parsed.kind()
    var roundOk = false
    match (roundKind) {
        case JsonKind.JsObject => roundOk = true
        case _ => ()
    }
    @Expect(roundOk, true)
}

@Test
func testStoreCorruptedFileRecovers(): Unit {
    let path = STORE_T_BAD
    // 造一个坏文件（半截 JSON，模拟进程中途被杀的旧版落盘）
    File.writeTo(path, "{\"theme\": \"da".toArray())
    let s = StoreBackend(path)
    // 读坏不是致命错误：从空开始，键为空
    @Expect(s.keys().size, 0)
    // 之后照常可用，且下一次写会覆盖掉坏文件
    let r = s.set("ok", JsonBool(true))
    @Expect(r, true)
    let parsed = JsonValue.fromStr(String.fromUtf8(File.readFrom(path)))
    let badKind = parsed.kind()
    var badOk = false
    match (badKind) {
        case JsonKind.JsObject => badOk = true
        case _ => ()
    }
    @Expect(badOk, true)
}

@Test
func testStoreConcurrentWritersKeepFileValid(): Unit {
    let path = STORE_T_CONC
    let s = StoreBackend(path)
    // 8 个 worker 各写 25 次，全部打同一个键：内存不丢更新、盘上始终是合法 JSON。
    // spawn 写法照框架自己的命令分发（ipc_hub.cj 的 `spawn { => ... }`）；
    // SyncCounter 是倒数计数器：init(8) 起始为 8，每个 worker 结束 dec()，waitUntilZero 等齐。
    let counter = SyncCounter(8)
    var i = 0
    while (i < 8) {
        let tag = "w${i}"
        let n = i
        let _ = spawn { =>
            var j = 0
            while (j < 25) {
                let r = s.set(tag, JsonInt(n * 100 + j))
                if (!r) {
                    eprintln("[store-test] ${tag} 第 ${j} 轮写盘失败")
                }
                j++
            }
            counter.dec()
        }
        i++
    }
    counter.waitUntilZero()
    // 8 个键都在；各自终值是 0..24 里的某一个（谁最后落盘就是谁的）
    let ks = s.keys()
    @Expect(ks.size, 8)
    let parsed = JsonValue.fromStr(String.fromUtf8(File.readFrom(path)))
    let concKind = parsed.kind()
    var concOk = false
    match (concKind) {
        case JsonKind.JsObject => concOk = true
        case _ => ()
    }
    @Expect(concOk, true)
}

@Test
func testStoreCommandParamValidation(): Unit {
    // 缺 key / 空 key / key 类型不对
    let noKey = JsonObject()
    @Expect(storeErrOf("get", noKey), "store: 缺少参数 \"key\"")
    let emptyKey = storeArgs1("")
    @Expect(storeErrOf("get", emptyKey), "store: key 不能为空字符串")
    let badKey = JsonObject()
    badKey.put("key", JsonInt(1))
    @Expect(storeErrOf("get", badKey), "store: 参数 \"key\" 必须是字符串")
    // set 缺 value（想存 null 要显式传）
    let argsV = storeArgs1("k")
    @Expect(storeErrOf("set", argsV), "store: 缺少参数 \"value\"（想存 null 就显式传 value: null）")
    // delete 不存在的键也成功（existed=false），不是错误
    let out = storeCmd("delete").handle("store:delete", storeArgs1("never-was"),
        IpcContext("main", IpcHub()))
    let existedKind = out.asObject().get("existed").getOrThrow().kind()
    var existedOk = false
    match (existedKind) {
        case JsonKind.JsBool => existedOk = true
        case _ => ()
    }
    @Expect(existedOk, true)
}
