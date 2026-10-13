package cjTauri.tests

import cjTauri.*
import cjTauri.plugins.*
import std.collection.*
import std.env.*
import std.fs.*
import stdx.encoding.json.*
import std.unittest.*
import std.unittest.testmacro.*

/*
 * 路径 scope（RFC-003 第 4 期）单元测试。
 *
 * 锁住四件事：glob 语义（`*` 不跨分隔符、`**` 跨、`?` 吃一个**码点**）、变量展开（认不出就原文保留
 * = 失败即拒）、规范化（折叠 `.` 与 `..`）、判定顺序（deny 优先）。
 * 末尾是端到端对照组：同一份 fs 清单下，白名单内可读写、越界即拒、没写 scope 时旧行为照旧。
 */

func scopeRuleOf(allow: Array<String>, deny: Array<String>): ScopeRule {
    let r = ScopeRule()
    for (a in allow) {
        r.allow.add(a)
    }
    for (d in deny) {
        r.deny.add(d)
    }
    return r
}

@Test
func testGlobStarDoesNotCrossSeparator(): Unit {
    @Expect(globMatch("/a/b.txt", "/a/b.txt"), true)
    @Expect(globMatch("/a/*.txt", "/a/b.txt"), true)
    @Expect(globMatch("/a/*.txt", "/a/sub/b.txt"), false)
    @Expect(globMatch("/a/*", "/a/sub"), true)
    @Expect(globMatch("/a/*", "/a/sub/b"), false)
}

@Test
func testGlobDoubleStarCrossesSeparator(): Unit {
    @Expect(globMatch("/a/**", "/a/x/y/z"), true)
    @Expect(globMatch("/a/**/b.txt", "/a/x/y/b.txt"), true)
    @Expect(globMatch("/a/**/b.txt", "/a/b.txt"), true)
    @Expect(globMatch("/a/**/b.txt", "/a/x/y/c.txt"), false)
    @Expect(globMatch("/**", "/anything/at/all"), true)
}

@Test
func testGlobQuestionMatchesOneCodePoint(): Unit {
    @Expect(globMatch("/a/?.txt", "/a/b.txt"), true)
    // 汉字是 3 字节：`?` 必须吃掉整个码点，按字节吃会把它切碎
    @Expect(globMatch("/a/?.txt", "/a/中.txt"), true)
    @Expect(globMatch("/a/??.txt", "/a/中.txt"), false)
    // `?` 不吃分隔符
    @Expect(globMatch("/a/x?", "/a/x/"), false)
}

@Test
func testExpandScopeVars(): Unit {
    // $CWD 就是进程工作目录
    @Expect(expandScopeVars("$CWD/x"), scopeCwdPath() + "/x")
    // $HOME 按环境变量展开（环境里没有就原样保留，绝不悄悄放宽）
    match (getVariable("HOME")) {
        case Some(home) => @Expect(expandScopeVars("$HOME/notes"), home + "/notes")
        case None => @Expect(expandScopeVars("$HOME/notes"), "$HOME/notes")
    }
    // 认不出的变量与孤立的 $ 都原样保留 = 模式匹配不上 = 拒
    @Expect(expandScopeVars("$NOPE/x"), "$NOPE/x")
    @Expect(expandScopeVars("/a$/b"), "/a$/b")
    // 不含变量时原样返回
    @Expect(expandScopeVars("/plain/path"), "/plain/path")
}

@Test
func testNormalizeCollapsesLexicalDots(): Unit {
    let base = scopeCwdPath()
    @Expect(normalizeScopePath("target/./scope-ok.txt"), base + "/target/scope-ok.txt")
    // `..` 折叠：绕不过白名单
    @Expect(normalizeScopePath("target/sub/../../outside.txt"), base + "/outside.txt")
    // 绝对路径原样（不存在的也成立）
    @Expect(normalizeScopePath("/tmp/../etc/passwd"), "/etc/passwd")
}

@Test
func testScopeAllowsDenyWins(): Unit {
    let rule = scopeRuleOf(["/data/**"], ["/data/secret/**"])
    @Expect(scopeAllows(rule, "/data/ok.txt"), true)
    @Expect(scopeAllows(rule, "/data/secret/x.txt"), false)
    @Expect(scopeAllows(rule, "/etc/passwd"), false)
    // 空 allow = 全拒（显式最小权限，不做「空即放行」）
    let empty = scopeRuleOf([], ["/x"])
    @Expect(scopeAllows(empty, "/anything"), false)
}

@Test
func testCapabilityParsesScopesAndRegistryUnions(): Unit {
    let raw = "{\"identifier\":\"a\",\"commands\":[\"fs:readText\"]," +
        "\"scopes\":{\"fs\":{\"allow\":[\"/one/**\"],\"deny\":[\"/one/bad\"]}}}"
    let raw2 = "{\"identifier\":\"b\",\"commands\":[\"fs:readText\"]," +
        "\"scopes\":{\"fs\":{\"allow\":[\"/two/**\"]}}}"
    let reg = CapabilityRegistry()
    @Expect(reg.addFromJson(JsonValue.fromStr(raw)), true)
    @Expect(reg.addFromJson(JsonValue.fromStr(raw2)), true)
    @Expect(reg.hasScopeForPlugin("fs"), true)
    @Expect(reg.hasScopeForPlugin("other"), false)
    let merged = reg.scopeForPlugin("fs").getOrThrow()
    // 并集：两份清单的 allow/deny 都收进来（与 canInvoke 的「任一放行即放行」同口径）
    @Expect(merged.allow.size, 2)
    @Expect(merged.deny.size, 1)
    @Expect(scopeAllows(merged, "/two/x"), true)
    @Expect(scopeAllows(merged, "/one/bad"), false)
}

@Test
func testScopeRuleAcceptsBareStringForm(): Unit {
    let rule = parseScopeRule(JsonValue.fromStr("{\"allow\":\"/plain/**\"}")).getOrThrow()
    @Expect(rule.allow.size, 1)
    @Expect(rule.allow[0], "/plain/**")
}

/* ===== 端到端对照组：走真实 fs 插件 + 真实文件 ===== */

func fsHandler(shortName: String): CommandHandler {
    return FsPlugin().commands().get(shortName).getOrThrow()
}

func fsCtxWithScopes(allow: Array<String>, deny: Array<String>): IpcContext {
    let json = JsonObject()
    json.put("identifier", JsonString("probe"))
    let cmds = JsonArray()
    cmds.add(JsonString("fs:readText"))
    cmds.add(JsonString("fs:writeText"))
    json.put("commands", cmds)
    let rule = JsonObject()
    let arr = JsonArray()
    for (a in allow) {
        arr.add(JsonString(a))
    }
    rule.put("allow", arr)
    let darr = JsonArray()
    for (d in deny) {
        darr.add(JsonString(d))
    }
    if (deny.size > 0) {
        rule.put("deny", darr)
    }
    let scopes = JsonObject()
    scopes.put("fs", rule)
    json.put("scopes", scopes)
    let reg = CapabilityRegistry()
    reg.add(Capability.fromJson(json).getOrThrow())
    let hub = IpcHub()
    hub.setCapabilities(reg)
    return IpcContext("main", hub)
}

func fsCtxLegacy(): IpcContext {
    let json = JsonObject()
    json.put("identifier", JsonString("legacy"))
    let cmds = JsonArray()
    cmds.add(JsonString("fs:writeText"))
    json.put("commands", cmds)
    let reg = CapabilityRegistry()
    reg.add(Capability.fromJson(json).getOrThrow())
    let hub = IpcHub()
    hub.setCapabilities(reg)
    return IpcContext("main", hub)
}

/** JsonKind 没有 ==（比较走 match），断言里需要判类型时用这个 */
func isJsonBool(v: JsonValue): Bool {
    match (v.kind()) {
        case JsonKind.JsBool => return true
        case _ => return false
    }
}

func fsWriteArgs(path: String, contents: String): JsonObject {
    let args = JsonObject()
    args.put("path", JsonString(path))
    args.put("contents", JsonString(contents))
    return args
}

func fsErrorMessage(handler: CommandHandler, cmd: String, args: JsonObject, ctx: IpcContext): String {
    try {
        handler.handle(cmd, args, ctx)
        return ""
    } catch (e: CommandException) {
        return e.message
    }
}

@Test
func testFsScopeAllowsInsideWriteAndRead(): Unit {
    let ctx = fsCtxWithScopes([scopeCwdPath() + "/target/**"], [])
    let writer = fsHandler("writeText")
    let reader = fsHandler("readText")
    let path = "target/scope-probe-ok.txt"
    @Expect(isJsonBool(writer.handle("fs:writeText", fsWriteArgs(path, "scope payload"), ctx)), true)
    let got = reader.handle("fs:readText", fsWriteArgs(path, ""), ctx)
    @Expect(got.asString().getValue(), "scope payload")
}

@Test
func testFsScopeDeniesOutsideAllowList(): Unit {
    // 对照组：同一份清单，路径出了白名单 → 拒（错误可读，不是崩）
    let ctx = fsCtxWithScopes([scopeCwdPath() + "/target/**"], [])
    let msg = fsErrorMessage(fsHandler("writeText"), "fs:writeText",
        fsWriteArgs("target-scope-outside.txt", "nope"), ctx)
    @Expect(msg.contains("outside the authorized scope"), true)
    // 真实文件没被创建（拒发生在写之前）
    @Expect(exists(scopeCwdPath() + "/target-scope-outside.txt"), false)
}

@Test
func testFsScopeDenyListWins(): Unit {
    let ctx = fsCtxWithScopes([scopeCwdPath() + "/target/**"], [scopeCwdPath() + "/target/**blocked*"])
    let msg = fsErrorMessage(fsHandler("writeText"), "fs:writeText",
        fsWriteArgs("target/blocked-scope.txt", "nope"), ctx)
    @Expect(msg.contains("outside the authorized scope"), true)
    @Expect(exists(scopeCwdPath() + "/target/blocked-scope.txt"), false)
}

@Test
func testFsScopeCannotEscapeWithDotDot(): Unit {
    // `..` 绕不过：规范化之后按绝对路径判定
    let ctx = fsCtxWithScopes([scopeCwdPath() + "/target/**"], [])
    let msg = fsErrorMessage(fsHandler("writeText"), "fs:writeText",
        fsWriteArgs("target/../target-scope-escape.txt", "nope"), ctx)
    @Expect(msg.contains("outside the authorized scope"), true)
    @Expect(exists(scopeCwdPath() + "/target-scope-escape.txt"), false)
}

@Test
func testLegacyManifestWithoutScopesStillWorks(): Unit {
    // 旧清单（没写 scopes）：行为不变——全量放行，只是启动时有一行 stderr 提示
    let ctx = fsCtxLegacy()
    let path = "target/scope-legacy-ok.txt"
    let out = fsHandler("writeText").handle("fs:writeText", fsWriteArgs(path, "legacy"), ctx)
    @Expect(isJsonBool(out), true)
    @Expect(exists(scopeCwdPath() + "/target/scope-legacy-ok.txt"), true)
}

@Test
func testScopeAwareIsDeclaredOnlyByFsPlugin(): Unit {
    // 只有 fs 声明吃 scope：别的插件不该被这层校验影响（框架不替插件猜哪个参数是路径）
    @Expect(FsPlugin().scopeAware(), true)
}
