package ohos_app_cangjie_entry

import kit.PerformanceAnalysisKit.Hilog
import cjTauri.*
import cjTauri.plugins.dialog.*
import cjTauri.plugins.clipboard.*
import cjTauri.plugins.notification.*
import stdx.encoding.json.JsonObject
import stdx.encoding.json.JsonString
import stdx.encoding.json.JsonValue

/**
 * 鸿蒙真机验收探针（AGENTS §1 门禁 2/3 的判据）
 *
 * ## 为什么要「页面自发往返」而不是只打一行 hilog
 *
 * 判据是**页面自己发起**的一次闭环：页面先调 `system:version`（框架 `run()` 里注册的内置命令），
 * 拿到返回值后再调本文件的 `probe:log`，把结果送回原生并落 hilog。两条命令都要过能力校验，
 * 所以一次成功同时证明：① 桥脚本注入生效（`window.__CJ_TAURI__` 存在）② 命令分发与能力放行
 * ③ 页面 → 原生的同步回调（`javaScriptProxy.post`）与原生 → 页面的回投（`poll` 泵）都在工作。
 *
 * ## 为什么要两扇窗
 *
 * 多窗口下每个窗口有**自己的宿主**（鸿蒙侧按 label 分文件落盘、按 label 路由回调）。共用一个
 * 静态单槽时，表象是「两窗都能用，但事件与回执串到其中一扇」。所以本探针挂两扇窗，并让
 * 每扇窗报出自己的 label 与「原生侧记在报文上的 window」，两者不等即串台（判据见 `probe:log`）。
 *
 * ## 为什么不拿桌面 e2e 代替
 *
 * 鸿蒙没有 C 桥：ArkWeb 宿主整条路径都在仓颉侧（`src/host_arkweb.cj`），桌面两平台的
 * `scripts/e2e/` 完全覆盖不到它。
 */

/**
 * 附加窗口的 label（默认窗口用框架的 `DEFAULT_WINDOW_LABEL`）
 *
 * 应用侧组件（`CjTauriWebView`）与框架登记（`addWindow`）必须用**同一个**值：
 * 对不上时组件取不到宿主，`aboutToAppear` 读到空 pageUrl 就永远不建 `Web`（白屏死锁）。
 */
public let SECOND_WINDOW_LABEL: String = "second"

/**
 * 验收页面
 *
 * 用 raw string：三引号会先处理反斜杠转义（AGENTS §4），页面里任何 `\n` 都会被拆断；
 * raw string 原样保留，代价是全文**不能出现** `"#` 这个序列（那是收尾符）。
 *
 * 同一份页面被两扇窗共用：页面读自己的 `__CJ_TAURI_LABEL__` 自报身份，所以「谁是谁」不需要
 * 两份页面文案，也就不会出现「两份页面都一样、分不清跑的是哪个窗」的假证据。
 */
public let PROBE_TAURI_HTML: String = #"<!DOCTYPE html>
<html>
<head>
<meta charset="utf-8">
<title>cj-tauri ohos acceptance</title>
<style>
  body { background: #0f172a; color: #e2e8f0; font-family: sans-serif; padding: 18px; margin: 0; }
  h1 { font-size: 20px; color: #38bdf8; margin: 0 0 6px 0; }
  .k { color: #94a3b8; font-size: 12px; margin-top: 10px; }
  .v { font-size: 15px; color: #6ee7b7; margin: 3px 0 0 0; word-break: break-all; }
  .bad { color: #fca5a5; }
</style>
</head>
<body>
  <h1 id="head">cj-tauri · HarmonyOS ArkWeb 验收</h1>
  <div class="k">桥是否注入 / 本窗 label</div>
  <div class="v" id="bridge">-</div>
  <div class="k">system:version</div>
  <div class="v" id="ver">-</div>
  <div class="k">定向投递回执（probe:ping，来自另一个窗口）</div>
  <div class="v" id="echo">-</div>
  <div class="k">probe:hello / probe:log 回执</div>
  <div class="v" id="log">-</div>
  <div class="k">dialog:message（原生弹窗回执）</div>
  <div class="v" id="dlg">-</div>
  <div class="k">clipboard / notification（鸿蒙宿主未实现时应如实失败）</div>
  <div class="v" id="cap">-</div>
  <button id="btn">弹出原生确认框</button>
  <script>
    var bridgeEl = document.getElementById('bridge');
    var verEl = document.getElementById('ver');
    var echoEl = document.getElementById('echo');
    var logEl = document.getElementById('log');
    var dlgEl = document.getElementById('dlg');
    var capEl = document.getElementById('cap');
    function put(el, text) { el.textContent = String(text); }
    function fail(el, err) {
      el.className = 'v bad';
      put(el, 'ERROR: ' + (err && err.message ? err.message : err));
    }
    var api = window.__CJ_TAURI__;
    var label = (typeof window.__CJ_TAURI_LABEL__ === 'string' && window.__CJ_TAURI_LABEL__.length > 0) ? window.__CJ_TAURI_LABEL__ : 'main';
    /* 原生弹窗：命令在用户点按钮之前不会返回，所以这里把「点了什么」同时回投给 probe:log，
       页面上的文字与 hilog 两处可对账（AGENTS §1 门禁 3：行为变更要可观测证据）。 */
    function showDialog() {
      put(dlgEl, 'waiting for user...');
      api.invoke('dialog:message', {
        kind: 'confirm',
        /* 标题里带 label：两扇窗**同时**在场时，哪一半显示哪个 label 就是
           「每个组件各持一份 @State、overlay 不串台」的肉眼判据；共用一份状态时
           两半会显示同一个 label（或干脆只画一份）。 */
        title: 'cj-tauri 弹窗 ' + label,
        message: 'label=' + label + ' 的原生对话框取证'
      }).then(function (ok) {
        put(dlgEl, 'confirmed=' + String(ok));
        return api.invoke('probe:log', { kind: 'dialog-result', me: label, confirmed: ok });
      }).then(null, function (e) {
        fail(dlgEl, e);
      });
    }
    /* 剪贴板 / 通知：鸿蒙宿主把这两条能力位报成 0（src/host_arkweb.cj），所以**两扇窗都该
       被如实拒绝**。页面把成功与失败都回投一条 `probe:log`，判据是那行里的 `window=` 与
       `me=` 相等——报文按 label 路由到了本窗；若第二扇窗的报文被原生记成别的 label，
       即「插件把所有窗都发给默认窗那一个宿主」的串台（2026-10-20 dialog 的实机结论同源）。 */
    function showPlatformBits() {
      put(capEl, 'waiting...');
      var results = [];
      function record(kind, ok, text) {
        results.push(kind + '=' + ok);
        put(capEl, results.join(' | ') + (text ? ' [' + text + ']' : ''));
        api.invoke('probe:log', { kind: 'platform-' + kind, me: label, ok: ok, detail: String(text || '') });
      }
      api.invoke('clipboard:write', { text: 'cj-tauri ' + label }).then(function () {
        record('clipboard-write', true, '');
      }, function (e) {
        record('clipboard-write', false, (e && e.message) ? e.message : String(e));
      });
      api.invoke('clipboard:read', {}).then(function (v) {
        record('clipboard-read', true, JSON.stringify(v));
      }, function (e) {
        record('clipboard-read', false, (e && e.message) ? e.message : String(e));
      });
      api.invoke('notification:notify', { title: 'cj-tauri 通知 ' + label, body: 'label=' + label }).then(function () {
        record('notification', true, '');
      }, function (e) {
        record('notification', false, (e && e.message) ? e.message : String(e));
      });
    }
    if (!api) {
      fail(bridgeEl, 'window.__CJ_TAURI__ undefined');
    } else {
      put(bridgeEl, 'ok label=' + label);
      document.getElementById('head').textContent = 'cj-tauri · label=' + label;
      document.getElementById('btn').onclick = showDialog;
      api.listen('probe:ping', function (payload) {
        var from = (payload && payload.from) ? String(payload.from) : '?';
        put(echoEl, 'ping from ' + from);
        api.invoke('probe:log', { kind: 'ping-recv', me: label, from: from }).then(function (ack) {
          put(logEl, 'ping logged ' + JSON.stringify(ack));
        }).then(null, function (e) {
          fail(logEl, e);
        });
      });
      api.invoke('system:version').then(function (ver) {
        put(verEl, JSON.stringify(ver));
        return api.invoke('probe:hello', { me: label });
      }).then(function (ack) {
        put(logEl, 'hello ' + JSON.stringify(ack));
        /* **两扇窗都自动弹**（2026-10-20 多窗口取证）：两框同时在场时，
           上半屏（main）与下半屏（second）各应显示自己 label 的标题；
           谁显示成对面的 label、或只画出一份，就是 overlay 共用了静态状态。
           早先只让 main 自动弹是为了单窗口截图好认，现在要的正是「两框同在」。 */
        showDialog();
        /* 接着打两条同族能力位（剪贴板 / 通知）：它们只在 hilog 里留凭证，
           不影响上面那两框的弹窗取证，所以排在 dialog 之后、不阻塞。 */
        showPlatformBits();
      }).then(null, function (e) {
        fail(logEl, e);
      });
    }
  </script>
</body>
</html>"#

/**
 * `probe:log`：把页面送上来的内容落 hilog
 *
 * 存在的意义就是取证——命令返回值只是回执，真正的凭证是 hilog 里这条行。前端的
 * reject 也由页面自己显示（页面没接 catch 时失败只在页面上可见，AGENTS §4）。
 *
 * 日志里同时打两样东西：
 * - `window=` 原生侧的归属（报文自带的 window 字段，经 `IpcHub` 带进 `IpcContext`）
 * - `me=` 页面自认的 label（`__CJ_TAURI_LABEL__`）
 *
 * 两者相等才是「按 label 路由」；不相等即发生了串台（例如两窗抢同一个宿主）。
 */
class ProbeLogHandler <: CommandHandler {
    public func handle(cmd: String, args: JsonObject, ipc: IpcContext): JsonValue {
        Hilog.info(1, "CjTauriProbe", "probe:log window=${ipc.window} <- ${args.toString()}")
        return JsonString("logged")
    }
}

/**
 * `probe:hello`：页面报到，原生据此向**另一个窗口**定向推一条 `probe:ping`
 *
 * 方向刻意选「对面」：若两个宿主的 label 路由被串成一个槽（静态单槽 / 固定常量），
 * 这条定向事件就会落到发报窗自己身上，或者两扇窗都收到——两种错法都会在 hilog 里露出来，
 * 而「推给自己」那种写法在错误实现下依然能通过，等于没测。
 */
class ProbeHelloHandler <: CommandHandler {
    private let app: TauriApp

    public init(app: TauriApp) {
        this.app = app
    }

    public func handle(cmd: String, args: JsonObject, ipc: IpcContext): JsonValue {
        let _ = args
        var target = SECOND_WINDOW_LABEL
        if (ipc.window == SECOND_WINDOW_LABEL) {
            target = DEFAULT_WINDOW_LABEL
        }
        Hilog.info(1, "CjTauriProbe", "probe:hello window=${ipc.window} -> probe:ping target=${target}")
        var payload = JsonObject()
        payload.put("from", JsonString(ipc.window))
        this.app.emitToWindow("probe:ping", payload, target)
        return JsonString("pinged")
    }
}

/**
 * 装配并运行框架应用（**必须在非 UI 线程调用**：`run()` 会阻塞到 `quit()`）
 *
 * `ArkWebRuntime.configure(filesDir)` 要更早（在 Ability 的 `onCreate` 里），因为
 * `run(html)` 要把内联 HTML 落到沙箱再以 `file://` 加载。
 */
public func startTauriProbe(): Unit {
    let app = TauriApp()
    app.register("probe:log", ProbeLogHandler())
    app.register("probe:hello", ProbeHelloHandler(app))
    // 原生弹窗走官方 dialog 插件（`dialog:message`）：插件只校验参数，真正弹窗在宿主层——
    // 鸿蒙的宿主把它退成「入队 + 等 UI 侧回填」（src/host_arkweb.cj）。
    app.plugin(DialogPlugin())
    /* 同族能力位（剪贴板 / 通知）：鸿蒙宿主当前一律报 0，接进来只为取证「两扇窗各自
       被如实拒绝、报文没有串到对面」——插件层的解析器口径与 dialog 完全一致。 */
    app.plugin(ClipboardPlugin())
    app.plugin(NotificationPlugin())
    // 能力清单：内置命令也要显式声明（默认最小权限），漏写会得到 command not allowed。
    // 两扇窗都要登记在 windows 里，否则第二扇窗发起的命令一律被拒（command not allowed）。
    app.addCapabilityJson(
        JsonValue.fromStr(
            #"{"identifier":"probe","windows":["main","second"],"commands":["system:version","probe:log","probe:hello","dialog:message","clipboard:write","clipboard:read","notification:notify"],"events":["probe:ping"]}"#
        )
    )
    // 第二扇窗：登记 + 装配宿主。必须在 run() 之前——窗口表要赶在页面加载前定稿，
    // 而 ArkWeb 侧一个 label 一个宿主实例、页面按 label 分文件落盘（互不覆盖）。
    app.addWindow(SECOND_WINDOW_LABEL, WindowConfig("cj-tauri second", 600, 400), PROBE_TAURI_HTML)
    app.run(PROBE_TAURI_HTML)
}
