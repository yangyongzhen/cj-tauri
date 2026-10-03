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
 *   main  : boot → 轮询 boots 直到 2 → 触发后端 fire（广播 1 条 + 定向 2 条）→ 报告计数 → quit
 *   second: boot → 等 600ms → 报告计数（只该收到广播 + 投给 second 的那条定向）
 * 期望（run.sh 逐字断言）：
 *   [mwprobe] window=main   COUNTS role=driver   label=main   broadcast=1 target_main=1 target_second=0
 *   [mwprobe] window=second COUNTS role=observer label=second broadcast=1 target_main=0 target_second=1
 *
 * 跑法见本目录 run.sh（工作目录必须是本工程根：capabilities/ 按相对路径读）。
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
        if (let Some(line) <- args.get("line")) {
            match (line.kind()) {
                case JsonKind.JsString => eprintln("[mwprobe] window=${ipc.window} " + line.asString().getValue())
                case _ => ()
            }
        }
        // 非驱动窗的上报计数：驱动窗据此确认「观察窗已自报」再退出
        if (ipc.window != "main") {
            eprintln("[mwprobe] window=${ipc.window} observer-reports=${this.log.markObserver()}")
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
    // 这两个要拿 app 本体（一个收全部窗口、一个定向投递），所以放在 app 构造之后注册
    app.register("fire", FireCommand(app))
    app.register("quit", QuitCommand(app))
    app.run(pocHtml())
    eprintln("[mwprobe] after run")
    return 0
}
