package cjTauri.tests

import cjTauri.*
import cjTauri.plugins.fs.*
import std.collection.*
import std.fs.*
import stdx.encoding.json.*
import std.unittest.*
import std.unittest.testmacro.*

/*
 * fs 插件单元测试：纯仓颉插件（零 C 桥），这里测到的是「真实落盘」。
 * 覆盖新四条命令（mkdir / rename / copy / stat）+ 命名权限集闸门 + 参数校验。
 * 临时目录固定 /tmp/fs-unit-test（按固定名复用，不在仓库里留测试产物）。
 */

const FS_T_BASE: String = "/tmp/fs-unit-test"

/** 递归删除基座目录（用例前置清场）：上一轮跑完留下的树会让 mkdir / copy 撞「already exists」 */
func fsWipeBase(dir: String): Unit {
    if (!exists(dir)) {
        return
    }
    if (FileInfo(dir).isDirectory()) {
        for (info in Directory.readFrom(dir)) {
            fsWipeBase("${dir}/${info.name}")
        }
    }
    // std.fs 的 remove 同时管文件与空目录（fs:remove 的注释有说明），自底向上删到这里必然为空
    remove(dir)
}

/** 取一条 fs 命令处理器 */
func fsCmd(short: String): CommandHandler {
    return FsPlugin().commands().get(short).getOrThrow()
}

/** 直接调命令，返回结果（抛 CommandException 就往上冒，由用例自己接） */
func fsRun(short: String, args: JsonObject): JsonValue {
    return fsCmd(short).handle("fs:${short}", args, IpcContext("main", IpcHub()))
}

/** 直接调命令，把 CommandException 的原文取出来（没抛就返回空串）*/
func fsErrOf(short: String, args: JsonObject): String {
    try {
        fsRun(short, args)
        return ""
    } catch (e: CommandException) {
        return e.message
    }
}

/** 只有 path 一个参数的入参 */
func fsArgs(path: String): JsonObject {
    var o = JsonObject()
    o.put("path", JsonString(path))
    return o
}

/** path + newPath 两个路径的入参（rename / copy） */
func fsArgsTo(path: String, newPath: String): JsonObject {
    var o = JsonObject()
    o.put("path", JsonString(path))
    o.put("newPath", JsonString(newPath))
    return o
}

/** path + recursive=true 的入参 */
func fsArgsRecursive(path: String): JsonObject {
    var o = JsonObject()
    o.put("path", JsonString(path))
    o.put("recursive", JsonBool(true))
    return o
}

/** path + newPath + overwrite=true 的入参（撞既有目标时放行） */
func fsArgsToOverwrite(path: String, newPath: String): JsonObject {
    var o = JsonObject()
    o.put("path", JsonString(path))
    o.put("newPath", JsonString(newPath))
    o.put("overwrite", JsonBool(true))
    return o
}

@Test
func testFsShimHasNewEntries(): Unit {
    let js = FsPlugin().jsShim()
    @Expect(js.contains("'fs:mkdir'"), true)
    @Expect(js.contains("'fs:rename'"), true)
    @Expect(js.contains("'fs:copy'"), true)
    @Expect(js.contains("'fs:stat'"), true)
}

@Test
func testFsPermissionSetsGateWrites(): Unit {
    let sets = pluginPermissionSets(FsPlugin())
    @Expect(sets.size, 2)
    let ro = sets.get("fs:readonly").getOrThrow()
    @Expect(ro.size, 4)
    // readonly 只含读：stat 进得来，任何写命令都不许被顺带打开
    var hasWrite = false
    for (n in ro) {
        if (n == "fs:writeText" || n == "fs:remove" || n == "fs:mkdir" || n == "fs:rename" || n == "fs:copy") {
            hasWrite = true
        }
    }
    @Expect(hasWrite, false)
    // default 是全集
    let all = sets.get("fs:default").getOrThrow()
    @Expect(all.size, 9)
}

@Test
func testFsMkdirCreatesAndRejectsDuplicate(): Unit {
    // 基座目录先递归建出来（后面的用例都挂在这棵树上）；上一轮的残留先清掉，
    // 否则第二次跑 test.sh 时 mkdir / copy 会撞「already exists」（固定目录复用的代价）
    fsWipeBase(FS_T_BASE)
    @Expect(fsRun("mkdir", fsArgsRecursive(FS_T_BASE)).asBool().getValue(), true)
    let dir = "${FS_T_BASE}/mkdir-a"
    @Expect(fsRun("mkdir", fsArgs(dir)).asBool().getValue(), true)
    @Expect(fsRun("exists", fsArgs(dir)).asBool().getValue(), true)
    // 已存在是错误不是成功：调用方要幂等就先 exists
    @Expect(fsErrOf("mkdir", fsArgs(dir)).contains("fs:mkdir failed"), true)
    // recursive=true 逐级建
    @Expect(fsRun("mkdir", fsArgsRecursive("${FS_T_BASE}/mkdir-b/c/d")).asBool().getValue(), true)
    // 缺省非递归：中间层不存在 → 报错
    @Expect(fsErrOf("mkdir", fsArgs("${FS_T_BASE}/x1/x2")).contains("fs:mkdir failed"), true)
}

@Test
func testFsRenameMovesAndHonorsOverwrite(): Unit {
    let src = "${FS_T_BASE}/r-src.txt"
    let dst = "${FS_T_BASE}/r-dst.txt"
    File.writeTo(src, "hello".toArray())
    File.writeTo(dst, "old".toArray())
    // 目标已存在且没声明 overwrite：报错，两边都原样
    @Expect(fsErrOf("rename", fsArgsTo(src, dst)).contains("fs:rename failed"), true)
    @Expect(String.fromUtf8(File.readFrom(dst)), "old")
    // overwrite=true：覆盖目标，源头消失
    @Expect(fsRun("rename", fsArgsToOverwrite(src, dst)).asBool().getValue(), true)
    @Expect(fsRun("exists", fsArgs(src)).asBool().getValue(), false)
    @Expect(String.fromUtf8(File.readFrom(dst)), "hello")
}

@Test
func testFsCopyKeepsSourceAndCopiesTrees(): Unit {
    let src = "${FS_T_BASE}/c-src.txt"
    let dst = "${FS_T_BASE}/c-dst.txt"
    File.writeTo(src, "copy me".toArray())
    @Expect(fsRun("copy", fsArgsTo(src, dst)).asBool().getValue(), true)
    // 源还在、内容一致
    @Expect(fsRun("exists", fsArgs(src)).asBool().getValue(), true)
    @Expect(String.fromUtf8(File.readFrom(dst)), "copy me")
    // 再拷一次撞既有目标：缺省报错；overwrite=true 才放行
    @Expect(fsErrOf("copy", fsArgsTo(src, dst)).contains("fs:copy failed"), true)
    @Expect(fsRun("copy", fsArgsToOverwrite(src, dst)).asBool().getValue(), true)
    // 目录整树拷贝：copy 的目录语义是递归
    let tree = "${FS_T_BASE}/c-tree"
    fsRun("mkdir", fsArgsRecursive("${tree}/sub"))
    File.writeTo("${tree}/sub/inner.txt", "deep".toArray())
    @Expect(fsRun("copy", fsArgsTo(tree, "${FS_T_BASE}/c-tree2")).asBool().getValue(), true)
    @Expect(String.fromUtf8(File.readFrom("${FS_T_BASE}/c-tree2/sub/inner.txt")), "deep")
}

/** JsonKind 转可比较的名字（JsonKind 没有 ==，比较要走 match 分支；分支体用表达式避免块解析歧义） */
func fsKindName(v: JsonValue): String {
    match (v.kind()) {
        case JsonKind.JsObject => "object"
        case JsonKind.JsArray => "array"
        case JsonKind.JsString => "string"
        case JsonKind.JsBool => "bool"
        case JsonKind.JsNull => "null"
        case _ => "other"
    }
}

@Test
func testFsStatReportsMetadata(): Unit {
    let file = "${FS_T_BASE}/s.txt"
    File.writeTo(file, "12345".toArray())
    let r = fsRun("stat", fsArgs(file))
    @Expect(fsKindName(r), "object")
    let obj = r.asObject()
    @Expect(obj.get("name").getOrThrow().asString().getValue(), "s.txt")
    @Expect(obj.get("dir").getOrThrow().asBool().getValue(), false)
    @Expect(obj.get("size").getOrThrow().asInt().getValue(), 5)
    @Expect(obj.get("lastModified").getOrThrow().asString().getValue().size > 0, true)
    // 目录也能 stat：dir=true
    let dirInfo = fsRun("stat", fsArgs(FS_T_BASE))
    @Expect(fsKindName(dirInfo), "object")
    @Expect(dirInfo.asObject().get("dir").getOrThrow().asBool().getValue(), true)
}

@Test
func testFsNewCommandsValidateArguments(): Unit {
    // 缺 newPath
    @Expect(fsErrOf("rename", fsArgs("${FS_T_BASE}/r-src.txt")).contains("missing argument"), true)
    @Expect(fsErrOf("copy", fsArgs("${FS_T_BASE}/r-src.txt")).contains("missing argument"), true)
    // 缺 path
    @Expect(fsErrOf("mkdir", JsonObject()).contains("missing argument"), true)
    // 可选布尔给了非布尔值：当场拒，不静默当 false
    var bad = fsArgs("${FS_T_BASE}/mkdir-a")
    bad.put("recursive", JsonInt(1))
    @Expect(fsErrOf("mkdir", bad).contains("must be a boolean"), true)
    // stat 不存在的路径：报错而不是返回空对象
    @Expect(fsErrOf("stat", fsArgs("${FS_T_BASE}/no-such-file")).contains("fs:stat failed"), true)
}
