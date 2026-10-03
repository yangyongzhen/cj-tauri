package multi_window

import cjTauri.*
import std.collection.*
import std.env.*
import std.sync.*
import stdx.encoding.json.*

/*
 * 多窗口 PoC 探针（批次 3 可行性验证的第一步）
 *
 * 目的：把「多窗口好不好做」从判断变成实测。最小假设三条——
 *   A) 一个进程里能同时跑两个宿主（Linux：两条各自跑 gtk_main 的原生线程）；
 *   B) 两个窗口各自拿到自己的 label（注入的 window.__CJ_TAURI_LABEL__ 与 IPC 报文里的 window 字段一致）；
 *   C) 广播投到两个窗口、定向只投目标窗口。
 * A 是真正的未知项（GTK3/GDK 不是多线程安全的，WebKitGTK 要求「调用必须在创建它的那条线程里」），
 * B/C 是批次 2 那套抽象的实证。三条都落在桥的 stderr 日志上——凭证是日志行，不是页面上显示的东西。
 *
 * 画面：main（驱动窗）+ second（观察窗），两页是**同一份 HTML**，角色由自己的 label 推出来：
 *   main  : boot → 轮询 boots 直到 2 → fire（广播 1 条 + 定向 2 条）→ 报计数
 *           → 阶段 2 广播「一起开原生框」→ 自己也开一个 → 等观察窗报结果
 *           → 阶段 3 只关 second → 证明应用还在（alive）→ quit
 *   second: boot → 有界等自己那两条事件到齐 → 报计数 → 等「开框」信号 → 开框 → 报结果
 * 期望（run.bat 逐字断言，单窗对照少最后几条）：
 *   [mwprobe] window=main   COUNTS role=driver   label=main   broadcast=1 target_main=1 target_second=0
 *   [mwprobe] window=second COUNTS role=observer label=second broadcast=1 target_main=0 target_second=1
 *   [mwprobe] window=main   ASK which=main   kind=info inflight=1
 *   [mwprobe] window=second ASK which=second kind=info inflight=2
 *   [mwprobe] window=main   ASK-DONE which=main   ok=true
 *   [mwprobe] window=second ASK-DONE which=second ok=true
 *   [mwprobe] window=main   CLOSE-WINDOW which=second requested
 *   [mwprobe] window=main   ALIVE second=1 main=0
 *
 * 阶段 2/3 是「两窗回调并发」的用例（架构文档 §7.5 的残余项）。B/C 两条假设已经由批次 2 的通路
 * 证明，这里补的是**共享状态**那一半：
 *   - 对话框状态在 C 核里是 **per-host** 的（`h->dlg_busy` / `dlg_lock` / `dlg_cur`），跨宿主本就不互斥，
 *     所以两窗能同时开着各自的框；`ASK … inflight=2` 是这件事的唯一硬证据——第二条 ask 进栈时
 *     第一条**还没出栈**（它要等人关框才回来），所以两个框确实同时在开。
 *   - 退出是**逐窗判**的（app.cj 的 allWindowsExited 轮询每个宿主的 shouldQuit）：关掉 second
 *     不该让应用返回，main 随后还能发命令、还能收到回执，本身就是证据。
 * 仍**未被本用例覆盖**的两处，别当成已了结：① `HostGlobals.onDestroy` 是静态单槽，且
 * `WebViewHost` 接口上根本没有安装点（应用侧装不进去），所以它现在恒为 no-op；
 * ② 文件类对话框的结果走共享的 `HostGlobals.dialogResult` 单槽——两窗同时开文件框时，
 * 「先返回者读到的可能是后返回者写的值」。本用例用 message 框（结果是返回值、不经槽位）绕开了它。
 *
 * 原生框要有人点：Windows 侧由 `dismiss-dialogs.ps1` 自动确认（run.bat 会起它）。
 * 跑法见本目录 run.bat（工作目录必须是本工程根：capabilities/ 按相对路径读）。
 */

/**
 * 已启动窗口的登记表
 *
 * 命令在 worker 线程上跑（IpcHub 异步分发），两个窗口的 boot 会并发到达，所以计数要加锁。
 */
class BootLog {
    private let lock: Mutex = Mutex()
    private var labels: ArrayList<String> = ArrayList<String>()

    func mark(label: String): Int64 {
        var n: Int64 = 0
        synchronized(this.lock) {
            if (!this.labels.contains(label)) {
                this.labels.add(label)
            }
            n = this.labels.size
        }
        return n
    }

    func count(): Int64 {
        var n: Int64 = 0
        synchronized(this.lock) {
            n = this.labels.size
        }
        return n
    }
}

/**
 * 观察窗的上报计数
 *
 * 驱动窗退出前要确认「观察窗已经自报」——抢在它前面把窗口收掉，`COUNTS role=observer`
 * 这条证据就永远拿不到（Windows 实测 second 可能比 main 先 boot，固定的时序假设必翻车）。
 */
class ReportLog {
    private let lock: Mutex = Mutex()
    private var observers: Int64 = 0
    private var asks: Int64 = 0

    func markObserver(): Int64 {
        var n: Int64 = 0
        synchronized(this.lock) {
            this.observers = this.observers + 1
            n = this.observers
        }
        return n
    }

    func observerCount(): Int64 {
        var n: Int64 = 0
        synchronized(this.lock) {
            n = this.observers
        }
        return n
    }

    /** 阶段 2 的结果单独计数：驱动窗要等的是「观察窗的框也出结果了」，不是它又报了一次 */
    func markAsk(): Int64 {
        var n: Int64 = 0
        synchronized(this.lock) {
            this.asks = this.asks + 1
            n = this.asks
        }
        return n
    }

    func askCount(): Int64 {
        var n: Int64 = 0
        synchronized(this.lock) {
            n = this.asks
        }
        return n
    }
}

/**
 * 「同一时刻有几个原生框在飞」的计数（阶段 2 的并发取证）
 *
 * 每条 ask 进栈 +1、对话框返回后 -1，并把自己看到的数打进日志。第二个 ask 读到 2 就证明
 * 第一个的框当时还开着——两个窗口的原生框真的并存，而不是排队。加锁是因为 ask 跑在命令
 * worker 线程上（IpcHub 异步分发），两条 ask 会并发到达。
 */
class AskLog {
    private let lock: Mutex = Mutex()
    private var inflight: Int64 = 0

    func enter(): Int64 {
        var n: Int64 = 0
        synchronized(this.lock) {
            this.inflight = this.inflight + 1
            n = this.inflight
        }
        return n
    }

    func leave(): Unit {
        synchronized(this.lock) {
            this.inflight = this.inflight - 1
        }
    }
}

/** 取顶层字符串参数（缺失 / 类型不对用缺省值） */
func stringArg(args: JsonObject, key: String, dflt: String): String {
    if (let Some(v) <- args.get(key)) {
        match (v.kind()) {
            case JsonKind.JsString => return v.asString().getValue()
            case _ => ()
        }
    }
    return dflt
}

/**
 * 把页面结论打回 stderr，并盖上**路由侧**看到的窗口身份：每行都是「窗口 + 结论」两段证据。
 */
public class ReportCommand <: CommandHandler {
    private let log: ReportLog

    init(log: ReportLog) {
        this.log = log
    }

    public func handle(cmd: String, args: JsonObject, ipc: IpcContext): JsonValue {
        // 先把上报正文取出来再判：原来只在 if (let Some(line) <- …) 块里可见，
        // 下面的 ASK-RESULT 判定拿不到它
        var text = ""
        var had = false
        if (let Some(line) <- args.get("line")) {
            match (line.kind()) {
                case JsonKind.JsString =>
                    text = line.asString().getValue()
                    had = true
                case _ => ()
            }
        }
        if (had) {
            eprintln("[mwprobe] window=${ipc.window} " + text)
        }
        // 非驱动窗的上报计数：驱动窗据此确认「观察窗已自报」再退出
        if (ipc.window != "main") {
            let n = this.log.markObserver()
            eprintln("[mwprobe] window=${ipc.window} observer-reports=${n}")
            // 阶段 2 的结果另算：它证明的是「观察窗的原生框也出结果了」，不是它又报了一次计数
            if (text.startsWith("ASK-RESULT")) {
                eprintln("[mwprobe] window=${ipc.window} ask-reports=${this.log.markAsk()}")
            }
        }
        return JsonBool(true)
    }
}

/** 观察窗已自报的次数（驱动窗轮询它，避免抢跑） */
public class ObserverReportsCommand <: CommandHandler {
    private let log: ReportLog

    init(log: ReportLog) {
        this.log = log
    }

    public func handle(cmd: String, args: JsonObject, ipc: IpcContext): JsonValue {
        return JsonInt(this.log.observerCount())
    }
}

/**
 * 窗口启动登记：ipc.window 是路由侧的身份，jsLabel 是页面侧读到的注入值——
 * 两者一致，才说明「注入的 label」与「报文里的 label」是同一个身份（架构文档 §7.3 的懒读链路）。
 */
public class BootCommand <: CommandHandler {
    private let log: BootLog

    init(log: BootLog) {
        this.log = log
    }

    public func handle(cmd: String, args: JsonObject, ipc: IpcContext): JsonValue {
        let jsLabel = stringArg(args, "label", "(missing)")
        let n = this.log.mark(ipc.window)
        eprintln("[mwprobe] window=${ipc.window} BOOT jsLabel=${jsLabel} booted=${n}")
        return JsonInt(n)
    }
}

/** 已启动窗口数：驱动窗轮询它来判断「第二窗也起来了」，不用固定 sleep 赌时序 */
public class BootsCommand <: CommandHandler {
    private let log: BootLog

    init(log: BootLog) {
        this.log = log
    }

    public func handle(cmd: String, args: JsonObject, ipc: IpcContext): JsonValue {
        return JsonInt(this.log.count())
    }
}

/**
 * 后端出向事件：1 条广播 + 2 条定向（同名事件，靠 payload.target 区分）。
 * 两条定向刻意用**同名同形状**的 payload：窗口收到哪几条只能由路由决定，页面侧无从猜。
 */
public class FireCommand <: CommandHandler {
    private let app: TauriApp

    init(app: TauriApp) {
        this.app = app
    }

    public func handle(cmd: String, args: JsonObject, ipc: IpcContext): JsonValue {
        var all = JsonObject()
        all.put("target", JsonString("all"))
        this.app.emit("probe:broadcast", all)

        var forMain = JsonObject()
        forMain.put("target", JsonString("main"))
        this.app.emitToWindow("probe:targeted", forMain, "main")

        var forSecond = JsonObject()
        forSecond.put("target", JsonString("second"))
        this.app.emitToWindow("probe:targeted", forSecond, "second")

        eprintln("[mwprobe] fire: broadcast=1 targeted=2 (main, second)")
        return JsonBool(true)
    }
}

/** 收尾：应用级退出（AppHost.quit 收掉每个窗口的循环），由驱动窗的页面触发 */
public class QuitCommand <: CommandHandler {
    private let app: TauriApp

    init(app: TauriApp) {
        this.app = app
    }

    public func handle(cmd: String, args: JsonObject, ipc: IpcContext): JsonValue {
        eprintln("[mwprobe] window=${ipc.window} requested quit -> 收全部窗口")
        this.app.quit()
        return JsonBool(true)
    }
}

/**
 * 某窗口的循环是否已退出：0 = 还在跑，1 = 已退出，2 = 没注册过（一眼看出 label 写错）
 */
func exitState(app: TauriApp, label: String): Int64 {
    match (app.hostOf(label)) {
        case Some(host) => if (host.shouldQuit()) { return 1 } else { return 0 }
        case None => return 2
    }
}

/**
 * 原生消息框（阶段 2 的并发用例）：跑在命令 worker 线程上
 *
 * which 缺省 = 发起它的那个窗口。`hostOf(label).showMessageDialog` 与 dialog 插件走同一条通路，
 * 所以这里验的就是插件背后那条路在多窗口下成不成立。`inflight` 见 AskLog。
 */
public class AskCommand <: CommandHandler {
    private let app: TauriApp
    private let log: AskLog

    init(app: TauriApp, log: AskLog) {
        this.app = app
        this.log = log
    }

    public func handle(cmd: String, args: JsonObject, ipc: IpcContext): JsonValue {
        var which = stringArg(args, "which", ipc.window)
        if (which.size == 0) {
            which = ipc.window
        }
        let kind = stringArg(args, "kind", "info")
        let n = this.log.enter()
        eprintln("[mwprobe] window=${ipc.window} ASK which=${which} kind=${kind} inflight=${n}")
        var ok = false
        match (this.app.hostOf(which)) {
            case Some(host) =>
                ok = host.showMessageDialog(kind, "multi-window probe (${which})",
                                            "window=${which} inflight=${n}")
            case None => eprintln("[mwprobe] ASK unknown window: ${which}")
        }
        this.log.leave()
        eprintln("[mwprobe] window=${ipc.window} ASK-DONE which=${which} ok=${ok}")
        return JsonBool(ok)
    }
}

/** 观察窗的原生框出结果了几次（驱动窗据此确认阶段 2 两边都跑到了） */
public class AskReportsCommand <: CommandHandler {
    private let log: ReportLog

    init(log: ReportLog) {
        this.log = log
    }

    public func handle(cmd: String, args: JsonObject, ipc: IpcContext): JsonValue {
        return JsonInt(this.log.askCount())
    }
}

/** 广播「一起开原生框」的信号：两窗的页面都在监听它，收到就各自向自己的宿主开框 */
public class DialogGoCommand <: CommandHandler {
    private let app: TauriApp

    init(app: TauriApp) {
        this.app = app
    }

    public func handle(cmd: String, args: JsonObject, ipc: IpcContext): JsonValue {
        var p = JsonObject()
        p.put("by", JsonString(ipc.window))
        this.app.emit("probe:dialog-go", p)
        eprintln("[mwprobe] window=${ipc.window} DIALOG-GO broadcast")
        return JsonBool(true)
    }
}

/**
 * 只关掉一个窗口（阶段 3）：`hostOf(which).quit()` 是**宿主**的低层原语，不是应用级退出
 *
 * 与 `quit`（AppHost.quit，收全部窗口）刻意分开——本命令存在的意义就是证明
 * 「少了一个窗口，应用不该跟着返回」（app.cj 的 allWindowsExited 是逐窗判的）。
 */
public class CloseWindowCommand <: CommandHandler {
    private let app: TauriApp

    init(app: TauriApp) {
        this.app = app
    }

    public func handle(cmd: String, args: JsonObject, ipc: IpcContext): JsonValue {
        let which = stringArg(args, "which", ipc.window)
        match (this.app.hostOf(which)) {
            case Some(host) =>
                eprintln("[mwprobe] window=${ipc.window} CLOSE-WINDOW which=${which} requested")
                host.quit()
                return JsonBool(true)
            case None =>
                eprintln("[mwprobe] CLOSE-WINDOW unknown window: ${which}")
                return JsonBool(false)
        }
    }
}

/** 各窗口退出状态的快照：这条命令能在 second 关掉之后被 main 跑完，本身就是「应用没退」的证据 */
public class AliveCommand <: CommandHandler {
    private let app: TauriApp

    init(app: TauriApp) {
        this.app = app
    }

    public func handle(cmd: String, args: JsonObject, ipc: IpcContext): JsonValue {
        let second = exitState(this.app, "second")
        // 变量别叫 main：字符串插值里的 ${main} 会解析成同名函数，报 “unexpected main function”
        let mainUp = exitState(this.app, "main")
        eprintln("[mwprobe] window=${ipc.window} ALIVE second=${second} main=${mainUp}")
        return JsonString("second=${second} main=${mainUp}")
    }
}

/**
 * 两页共用的一份 HTML
 *
 * 角色不靠参数注入，而是**由自己的 label 推出来**（DRIVER = label 是 main）：
 * 一个字符串喂两个窗口，正好也验证了「每个窗口拿到的是自己那份 label」。
 */
func pocHtml(): String {
    return """
<!DOCTYPE html>
<html>
<head><meta charset="utf-8"><title>multi-window PoC</title>
<style>
body { font-family: ui-monospace, monospace; background: #16161d; color: #ddd; padding: 24px; }
#role { font-size: 15px; color: #8ec07c; margin-bottom: 12px; }
#hits { font-size: 14px; color: #fabd2f; }
</style>
</head>
<body>
<div id="role">waiting for bridge...</div>
<pre id="hits">(no events yet)</pre>
<script>
var LABEL = window.__CJ_TAURI_LABEL__ || '(unset)';
var DRIVER = (LABEL === 'main');
var hits = { broadcast: 0, target_main: 0, target_second: 0 };

function counts() {
  return 'broadcast=' + hits.broadcast + ' target_main=' + hits.target_main +
         ' target_second=' + hits.target_second;
}
function paint() { document.getElementById('hits').textContent = counts(); }
function delay(ms) { return new Promise(function (r) { setTimeout(r, ms); }); }

// 向**自己的宿主**开一个原生消息框，并把结果报回后端（结果就是 invoke 的返回值）
function askSelf() {
  var tauri = window.__CJ_TAURI__;
  return tauri.invoke('ask', { which: LABEL, kind: 'info' }).then(function (ok) {
    return tauri.invoke('report', { line: 'ASK-RESULT which=' + LABEL + ' ok=' + ok });
  });
}

// 有界轮询：等到 pred() 为真或超时（返回是否等到了）。两个窗口的 boot 先后由运行时决定
// （Windows 实测 second 可能先起来），所以两边都不能用固定 sleep 赌时序。
function waitUntil(pred, ms) {
  return new Promise(function (res) {
    var t0 = Date.now();
    (function poll() {
      if (pred()) { res(true); return; }
      if (Date.now() - t0 > ms) { res(false); return; }
      setTimeout(poll, 50);
    })();
  });
}

async function main() {
  var tauri = window.__CJ_TAURI__;
  document.getElementById('role').textContent =
    'label: ' + LABEL + '  role: ' + (DRIVER ? 'driver' : 'observer');

  function report(line) { return tauri.invoke('report', { line: line }); }

  // 阶段 2 的起跑信号：两个窗口都听。驱动窗由下面的阶段 2 显式开框（否则会开两个），
  // 观察窗就靠这条与它并行——这正是「两框同时在开」的来源。
  tauri.listen('probe:dialog-go', function () {
    if (DRIVER) { return; }
    askSelf();
  });

  tauri.listen('probe:broadcast', function () { hits.broadcast++; paint(); });
  tauri.listen('probe:targeted', function (p) {
    if (p && p.target === 'main') { hits.target_main++; }
    if (p && p.target === 'second') { hits.target_second++; }
    paint();
  });

  await tauri.invoke('boot', { label: LABEL });

  if (!DRIVER) {
    // 观察窗：不等固定延迟，按「自己那两条事件是否到齐」有界等待（最多 8s）后自报。
    var got = await waitUntil(function () {
      return hits.broadcast >= 1 && hits.target_second >= 1;
    }, 8000);
    await report('COUNTS role=observer label=' + LABEL + ' ' + counts() + ' settled=' + got);
    return;
  }

  // 驱动窗：等两个窗口都起来（有界轮询，最多 10s）
  var n = 0;
  for (var i = 0; i < 100; i++) {
    n = await tauri.invoke('boots', {});
    if (n >= 2) { break; }
    await delay(100);
  }
  await report('GATE boots=' + n);
  if (n < 2) {
    await report('FAIL second window never booted');
    await tauri.invoke('quit', {});
    return;
  }

  await tauri.invoke('fire', {});
  // 自己的两条事件到齐再自报（有界等待，不用固定 sleep 赌）
  await waitUntil(function () { return hits.broadcast >= 1 && hits.target_main >= 1; }, 8000);
  // 再等观察窗自报：抢在它前面退出，second 的 COUNTS 就永远缺证（有界，最多 8s）
  var seen = 0;
  for (var j = 0; j < 160; j++) {
    seen = await tauri.invoke('observer-reports', {});
    if (seen >= 1) { break; }
    await delay(50);
  }
  await report('COUNTS role=driver label=' + LABEL + ' ' + counts() + ' observer_reports=' + seen);

  // ---- 阶段 2：两窗同时开原生框（并发用例）----
  // 先广播信号（观察窗的监听器立刻开框），驱动窗紧接着也开一个。两个框都要等人关才返回，
  // 所以第二条 ask 进栈时第一条必然还在——`inflight=2` 就是这么来的。
  await tauri.invoke('dialog-go', {});
  await askSelf();
  var asks = 0;
  for (var k = 0; k < 300; k++) {
    asks = await tauri.invoke('ask-reports', {});
    if (asks >= 1) { break; }
    await delay(100);
  }
  await report('DIALOG-PHASE observer_asks=' + asks);

  // ---- 阶段 3：只关 second，应用不该跟着退 ----
  await tauri.invoke('close-window', { which: 'second' });
  await delay(500);   // 闭窗要走完销毁路径（置 shouldQuit）才查得到
  var alive = await tauri.invoke('alive', {});
  await report('CLOSE-PHASE alive=' + alive);
  await tauri.invoke('quit', {});
}

function start() {
  // 桥是 document-start 注入的，正常情况直接可用；等一拍只是为了不被注入顺序的偶发差异坑到
  if (window.__CJ_TAURI__) { main(); }
  else { setTimeout(start, 100); }
}
start();
</script>
</body>
</html>
"""
}

/**
 * 是否登记第二个窗口（AB 对照开关）
 *
 * `MW_MODE=single` 时只起主窗：用来把「多窗口缝本身有问题」与「一个进程两个 GTK 主循环不成立」
 * 这两件事分开——单窗模式干净而双窗必崩/挂，才说明问题出在后者。
 */
func extraWindowEnabled(): Bool {
    match (getVariable("MW_MODE")) {
        case Some(v) => return v != "single"
        case None => return true
    }
}

main(): Int64 {
    eprintln("[mwprobe] main start")
    let log = BootLog()
    let reports = ReportLog()
    let asks = AskLog()
    var app = TauriApp()
        .window(WindowConfig("cj-tauri 多窗口 PoC（main）", 620, 400))
    if (extraWindowEnabled()) {
        app = app.addWindow("second", WindowConfig("cj-tauri 多窗口 PoC（second）", 620, 400), pocHtml())
    } else {
        eprintln("[mwprobe] MW_MODE=single：只起主窗（对照组）")
    }
    app.register("report", ReportCommand(reports))
    app.register("boot", BootCommand(log))
    app.register("boots", BootsCommand(log))
    app.register("observer-reports", ObserverReportsCommand(reports))
    app.register("ask-reports", AskReportsCommand(reports))
    // 这几个要拿 app 本体（收全部窗口 / 定向投递 / 按 label 取宿主），所以放在 app 构造之后注册
    app.register("fire", FireCommand(app))
    app.register("quit", QuitCommand(app))
    app.register("ask", AskCommand(app, asks))
    app.register("dialog-go", DialogGoCommand(app))
    app.register("close-window", CloseWindowCommand(app))
    app.register("alive", AliveCommand(app))
    app.run(pocHtml())
    eprintln("[mwprobe] after run")
    return 0
}
