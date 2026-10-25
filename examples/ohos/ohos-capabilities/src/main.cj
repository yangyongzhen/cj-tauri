package ohosCapabilities

import cjTauri.*
import cjTauri.plugins.menu.*
import cjTauri.plugins.clipboard.*
import cjTauri.plugins.http.*
import cjTauri.plugins.fs.*
import cjTauri.plugins.mqtt.*
import cjTauri.plugins.redis.*
import cjTauri.plugins.ws.*
import cjTauri.plugins.log.*
import cjTauri.plugins.sqlite.*
import cjTauri.plugins.store.*
import stdx.encoding.json.*
import std.collection.*
@When[env == "ohos"]
import kit.PerformanceAnalysisKit.Hilog

/*
 * 探针回执通道
 *
 * 为什么必须由应用侧写日志：鸿蒙设备上 `eprintln` 不进 hilog（框架 stderr 全不可见，
 * 见 AGENTS §4），而能力位取证又只有「页面断言 → 有人把它打进设备日志」这一条路。
 * 于是探针页把每一条断言经 `probeLog` 命令送进来，这里原样写进 hilog（tag `CjProbe`），
 * `hdc shell hilog` 一抓就能逐条对账。桌面端没有 hilog，退回 stdout。
 */
@When[env == "ohos"]
public func probeLog(text: String): Unit {
    Hilog.info(1, "CjProbe", text)
}

/*
 * 第二扇窗的内联页面（多窗口组合验证用）
 *
 * `addWindow` 目前只接内联页面（src/app.cj 的契约），所以这里给一份精简探针：
 * ① 页面自认 label 必须是 second（`__CJ_TAURI_LABEL__` 由宿主注入）；
 * ② 第二窗自己的 sqlite / store 命令往返成立（证明命令分发按 `ipc.window` 找到 second 宿主，
 *    结果没有回投到第一扇窗）；
 * ③ 主窗的 `probe-key` 在第二窗读不到——store 是**应用级共享**存储，键隔离即语义正确
 *   （真串台会表现为第二窗读到第一窗的键值）。
 *
 * 注意：内联 JS 里**不写反斜杠**（三引号字符串会先吃掉转义，AGENTS §4）；换行用
 * `String.fromCharCode(10)`。sqlite:exec 不收 params，值直接内联。
 */
let SECOND_PAGE_HTML: String = """
<!doctype html><html><head><meta charset="utf-8"><title>second</title></head><body>
<h3>second window probe</h3><pre id="out"></pre>
<script>
(function () {
  var outEl = document.getElementById('out');
  function out(t) { if (outEl) { outEl.textContent = outEl.textContent + t + String.fromCharCode(10); } }
  function wait(n) {
    if (!window.__CJ_TAURI__ || !window.__CJ_TAURI__.invoke) {
      if (n <= 0) { out('bridge missing'); return; }
      setTimeout(function () { wait(n - 1); }, 50);
      return;
    }
    var t = window.__CJ_TAURI__;
    var me = typeof window.__CJ_TAURI_LABEL__ === 'undefined' ? 'unset' : window.__CJ_TAURI_LABEL__;
    function report(text) {
      t.invoke('probeLog', { text: text }).catch(function (e) { out('probeLog fail ' + e.message); });
    }
    report('PASS second window up me=' + me);
    var db = 'second-window.db';
    /* SQL 里的字符串字面量必须用**单引号**包：SQLite 把双引号优先当标识符，
       写成 VALUES (cj-second) 会被解析成列名表达式、报 no such column: cj（实测踩过）。 */
    t.invoke('sqlite:exec', { path: db, sql: "CREATE TABLE IF NOT EXISTS t2(id INTEGER PRIMARY KEY, v TEXT); DELETE FROM t2; INSERT INTO t2(v) VALUES ('cj-second')" })
      .then(function () { return t.invoke('sqlite:query', { path: db, sql: 'SELECT v FROM t2 ORDER BY id' }); })
      .then(function (q) {
        var ok = q && q.rows && q.rows.length === 1;
        var val = ok ? q.rows[0][0].value : null;
        report((ok && val === 'cj-second' ? 'PASS' : 'FAIL') + ' second sqlite round-trip v=' + val);
        return t.invoke('store:set', { key: 'second-key', value: 'second-value' });
      })
      .then(function () { return t.invoke('store:get', { key: 'second-key' }); })
      .then(function (v) {
        report((v === 'second-value' ? 'PASS' : 'FAIL') + ' second store round-trip v=' + v);
        return t.invoke('store:get', { key: 'probe-key', default: 'absent' });
      })
      .then(function (p) {
        report('INFO second reads main-window key probe-key=' + p);
        // 跨窗定向投递的**发送端**：投给对面（main）。发给自己在路由错误的实现下也会通过，
        // 等于没测；延迟 2.5s 是等主窗页面把 listen 注册上（它前序还有一串探针）。
        setTimeout(function () {
          t.invoke('probeEmitTo', { target: 'main', event: 'crosstalk:probe', payload: 'from-second' })
            .then(function () { report('INFO second emitted directed event to main'); })
            .catch(function (e) { report('FAIL second emit ' + e.message); });
        }, 2500);
      })
      .catch(function (e) { report('FAIL second ' + e.message); });
  }
  wait(120);
})();
</script>
</body></html>"""

@When[env != "ohos"]
public func probeLog(text: String): Unit {
    println("[CjProbe] ${text}")
}

/** 页面断言落日志：`tauri.invoke("probeLog", { text })` */
public class ProbeLogCommand <: CommandHandler {
    public init() {}

    public func handle(cmd: String, args: JsonObject, ipc: IpcContext): JsonValue {
        let _ = cmd
        let _ = ipc
        var text = ""
        if (let Some(t) <- args.get("text")) {
            match (t.kind()) {
                case JsonKind.JsString => text = t.asString().getValue()
                case _ => ()
            }
        }
        probeLog(text)
        return JsonBool(true)
    }
}

/**
 * 定向投递探针：把事件推给**对面窗口**
 *
 * 为什么必须「对面」：`emitToWindow` 若退化成广播、或路由错成「总是本窗」，
 * 「发给自己」的断言在错误实现下同样会通过——等于没测（AGENTS §4 的多窗口判据）。
 * 真正被验证的是「第二窗发的命令 → 主窗页面收到事件」，两端各自回投一条证据。
 */
public class ProbeEmitToCommand <: CommandHandler {
    private let app: TauriApp

    public init(app: TauriApp) {
        this.app = app
    }

    public func handle(cmd: String, args: JsonObject, ipc: IpcContext): JsonValue {
        let _ = cmd
        let _ = ipc
        let target = probeArg(args, "target")
        let event = probeArg(args, "event")
        let payload = probeArg(args, "payload")
        if (target.size == 0 || event.size == 0) {
            throw Exception("probeEmitTo: target / event required")
        }
        this.app.emitToWindow(event, JsonString(payload), target)
        return JsonBool(true)
    }
}

/** 取字符串型命令参数（缺省回空串）——探针命令的小工具 */
func probeArg(args: JsonObject, key: String): String {
    if (let Some(v) <- args.get(key)) {
        match (v.kind()) {
            case JsonKind.JsString => return v.asString().getValue()
            case _ => ()
        }
    }
    return ""
}


public class GreetCommand <: CommandHandler {
    public init() {}

    public func handle(cmd: String, args: JsonObject, ipc: IpcContext): JsonValue {
        var name = "world"
        if (let Some(n) <- args.get("name")) {
            match (n.kind()) {
                case JsonKind.JsString => name = n.asString().getValue()
                case _ => ()
            }
        }
        return JsonString("Hello, ${name}! 来自仓颉后端")
    }
}

/**
 * 定时器命令：启动后台线程，每秒向前端推一个 tick 事件（验证 仓颉 → JS 通道）
 * 前端：tauri.listen("tick", cb) + tauri.invoke("timer")
 */
public class TimerCommand <: CommandHandler {
    private var counter: Int64 = 0
    private var started: Bool = false

    public init() {}

    public func handle(cmd: String, args: JsonObject, ipc: IpcContext): JsonValue {
        if (!this.started) {
            this.started = true
            spawn {
                while (true) {
                    sleep(Duration.second)
                    this.counter += 1
                    var payload = JsonObject()
                    payload.put("n", JsonInt(this.counter))
                    ipc.emit("tick", payload)
                }
            }
        }
        return JsonString("timer started")
    }
}

/**
 * 演示菜单：一个普通项 + 一个带勾选项的子菜单
 *
 * 两个方向都在页面上看得到：
 *   菜单 → 页面：点「打个招呼」，宿主把事件推给前端（页面 listen("menu:click") 显示 id）
 *   页面 → 菜单：勾选页面上的复选框，走 menu 插件改「侧边栏」这一项的勾选状态
 */
func demoMenu(): MenuModel {
    var view = ArrayList<MenuItem>()
    view.add(MenuItem.checkbox("view.sidebar", "侧边栏", true))
    var items = ArrayList<MenuItem>()
    items.add(MenuItem.normal("file.hello", "打个招呼"))
    items.add(MenuItem.submenu("视图", view))
    return MenuModel(items)
}

/**
 * 业务装配点（RFC-002 §4.1）：骨架的 launcher（targets/ 下各目标的 src）调用它取 AppSpec。
 *
 * 零平台知识：不碰宿主、不知道页面文件路径、不知道能力目录——那些由清单
 * （cj-tauri.toml）决定，launcher 按清单覆盖（page/window/assets/capabilities）。
 * build() 负责业务自己的部分：命令注册、菜单、插件。
 */
public func build(): AppSpec {
    return AppSpec()
        .window(WindowConfig("ohos-capabilities", 1000, 700))
        // menu 插件：给前端挂 window.__CJ_TAURI__.menu.setEnabled / setChecked
        // （插件只声明「我提供什么」，**不自动放行**——要能调，就在 capabilities 里引用
        //   permissions: ["menu:state"]，或逐条写 commands）
        .plugin(MenuPlugin())
        // clipboard 插件：鸿蒙侧走原生 pasteboard（宿主实现见 host_arkweb.cj），
        // 命令是 clipboard:write / clipboard:read，能力清单里逐条声明才放行
        .plugin(ClipboardPlugin())
        // http 插件：鸿蒙侧走系统网络栈 ohos.net.http（http_ohos.cj）——真机核验
        // RequestMethod.Post/Delete 成员名、extraData 承载 POST 体、https 走 OS 的 TLS、
        // postStream 如实拒绝；主机白名单在 assets/capabilities/default.json 的 scopes.http
        .plugin(HttpPlugin())
        // fs 插件：鸿蒙沙箱内读写——真机核验 scope 相对路径口径与九条命令；
        // 主机白名单在 assets/capabilities/default.json 的 scopes.fs（allow: probe-fs/**）
        .plugin(FsPlugin())
        // mqtt 插件：真机核验明文 TCP 出网（stdx socket 不碰 TLS，预期设备上可用）；
        // 对端用公网明文 broker test.mosquitto.org:1883，自收回环对账（SUBACK + 收到自己的 PUBLISH）
        .plugin(MqttPlugin())
        // redis 插件：真机核验 RESP2 明文 TCP——对端是 PC 上的本仓 mock-redis，
        // 经 `hdc rport tcp:6380 tcp:6379` 反向转发（设备连自己的 127.0.0.1:6380）
        .plugin(RedisPlugin())
        // ws 插件：真机核验 RFC6455 明文握手（stdx WebSocket.upgradeFromClient）——
        // 对端是 PC 上的 python websockets echo，经 `hdc rport tcp:8765 tcp:8765` 反向转发；
        // 主机白名单在 default.json 的 scopes.ws（没写 = 全拒）
        .plugin(WsPlugin())
        // log 插件：真机核验鸿蒙降级契约——writeLogLine 返 false、logFile 回空串
        .plugin(LogPlugin())
        // sqlite 插件：真机核验 FFI 直连——设备与 NDK 都没有 sqlite 库，走 amalgamation
        // （public domain）随包编 so：libsqlite3.so 放 entry/libs/arm64-v8a/ 随 hap 分发，
        // entry link-option 加 -L/-lsqlite3 生成 DT_NEEDED（缺了模块加载期 U 解析失败）
        .plugin(SqlitePlugin())
        // store 插件：真机核验持久化 KV——落盘 <cwd>/store.json（鸿蒙 cwd = el2 files 目录，可写）
        .plugin(StorePlugin())
        .wire({ app =>
            // 第二扇窗（多窗口组合验证）：label 必须与骨架 index.cj 里 SECOND_WINDOW_LABEL 一致
            // ——框架按 label 查宿主、按 label 落页面（cj-tauri-second.html），两处不一致就白屏。
            // **AppSpec.wire 是单槽**（后一次调用覆盖前一次），addWindow 必须并进这个 lambda。
            // addWindow 只接内联页面（src/app.cj 的契约），所以给一份精简探针页。
            app.addWindow("second", WindowConfig("ohos-capabilities second", 900, 560), SECOND_PAGE_HTML)
            app.register("greet", GreetCommand())
            app.register("timer", TimerCommand())
            // 页面断言写设备日志：能力位取证靠它（见 probeLog 的注释）
            app.register("probeLog", ProbeLogCommand())
            // 跨窗定向投递探针（wrapper 收 app 才能调 emitToWindow）
            app.register("probeEmitTo", ProbeEmitToCommand(app))
            // 菜单栏必须在 run 之前挂：预置类宿主能力要赶在页面加载前定稿
            app.setMenu(demoMenu())
        })
}
