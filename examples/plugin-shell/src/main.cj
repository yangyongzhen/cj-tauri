package plugin_shell

import cjTauri.*
import stdx.encoding.json.*

/**
 * 插件体系示例：接入官方 shell 插件只需一行 .plugin(ShellPlugin())
 *
 * 要看的证据（stderr + 截图）：
 *  1. 启动时打印「已装配插件」清单与命名权限集（shell:allow-open / shell:default）；
 *  2. capability 混用两种写法：permissions: ["shell:allow-open"] 放行「用系统默认程序打开」，
 *     shell:exec 另用明文 commands 逐条放行——**allow-open 不会顺带把执行能力送出去**；
 *  3. 前端第一行就读到 __CJ_TAURI__.shell（证明 shim 早于页面脚本）；
 *  4. shell:exec 取回退出码 / stdout / stderr；参数里写 `&&` 时它原样出现在输出里
 *     （证明参数是 argv 直传、不经过 shell，页面拼不出「注入」）；
 *  5. 对照组：system:devtools 已注册但不在清单里 → 被拒（默认最小权限不被破坏）；
 *  6. 「长命令 + 心跳」按钮：命令执行已挪到 worker 线程（异步分发），框架侧 `slow` 命令睡 3 秒期间，
 *     心跳（每次一次完整 IPC 往返）应当照常每 300ms 来一条——若命令还占着宿主 UI 线程，这几秒会整段静默。
 *
 * 运行目录 = 本示例根（capabilities/ 按相对路径解析，与 hello 一致）。
 */
/**
 * 框架侧慢命令：睡 3 秒再回答，用来验证「命令执行不占宿主 UI 线程」。
 * 与 `shell:exec` 跑一个长驻进程是同一类阻塞，但跨平台（不依赖 sleep 可执行文件）。
 */
public class SlowCommand <: CommandHandler {
    public init() {}

    public func handle(cmd: String, args: JsonObject, ipc: IpcContext): JsonValue {
        sleep(Duration.second * 3)
        return JsonBool(true)
    }
}

public class ReportCommand <: CommandHandler {
    public init() {}

    public func handle(cmd: String, args: JsonObject, ipc: IpcContext): JsonValue {
        if (let Some(line) <- args.get("line")) {
            match (line.kind()) {
                case JsonKind.JsString => eprintln("[frontend] " + line.asString().getValue())
                case _ => ()
            }
        }
        return JsonBool(true)
    }
}

main(): Int64 {
    eprintln("[plugin-shell] main start")

    let app = TauriApp()
        .window(WindowConfig("cj-tauri 插件 shell 示例", 940, 640))
        .plugin(ShellPlugin())       // 插件体系：一行接入（对标 Tauri v2 的 .plugin(...)）
        .register("report", ReportCommand())
        .register("slow", SlowCommand())

    // 前端页面：内联 HTML（与 examples/hello 同风格，零 Node 依赖）
    let html = """
<!DOCTYPE html>
<html>
<head>
<meta charset="utf-8">
<title>cj-tauri 插件 shell 示例</title>
<style>
  body { font-family: system-ui, sans-serif; background: #141a2e; color: #eee;
         display: flex; flex-direction: column; align-items: center; padding-top: 36px; }
  h1 { color: #7ce7ff; margin-bottom: 4px; }
  .card { background: #1b2440; border-radius: 12px; padding: 20px 26px; width: 700px;
          box-shadow: 0 8px 24px rgba(0,0,0,.4); }
  pre { background: #0d1226; border-radius: 8px; padding: 12px; font-size: 13px;
        line-height: 1.5; white-space: pre-wrap; word-break: break-all; margin: 10px 0 0;
        max-height: 300px; overflow: auto; }
  button { background: #e94560; color: #fff; border: none; border-radius: 8px;
           padding: 8px 14px; font-size: 14px; cursor: pointer; margin: 0 6px 6px 0; }
  button:hover { opacity: .85; }
  .muted { color: #8b93b0; font-size: 12px; }
</style>
</head>
<body>
  <h1>cj-tauri 插件 shell</h1>
  <div class="card">
    <p>一行 <b>.plugin(ShellPlugin())</b> 接入；权限仍由 capabilities 决定。
      <br><span class="muted">清单里 permissions: ["shell:allow-open"] 只放行「打开」，
      shell:exec 是另用明文逐条放行的——要执行能力就得自己写那一行。
      system:devtools 故意不在清单里，作未授权对照组。</span></p>
    <p>
      <button id="btnOpenUrl">打开链接</button>
      <button id="btnOpenFile">打开本地文件</button>
      <button id="btnUname">uname -a</button>
      <button id="btnExit">退出码 + stderr</button>
      <button id="btnProbe">注入对照</button>
      <button id="btnSlow">长命令 3 秒 + 心跳</button>
    </p>
    <pre id="log">[shell] …</pre>
  </div>
  <script>
    // 第一行就读插件命名空间：head 里的 shim 应当已经跑过（早于本脚本）
    var shimReadyAtScriptStart = !!(window.__CJ_TAURI__ && window.__CJ_TAURI__.shell);

    var logEl = document.getElementById('log');
    var lines = [];

    function show(line) {
      lines.push(line);
      // 换行用 fromCharCode(10) 现算：本段 JS 写在仓颉三引号字符串里，
      // 反斜杠转义会先被仓颉处理掉，写反斜杠-n 会变成真换行把 JS 拆断（整段语法错误）
      logEl.textContent = lines.join(String.fromCharCode(10));
      // 跟着最新一行走：日志长了也不会把新出的证据顶出可视区
      logEl.scrollTop = logEl.scrollHeight;
      // 同一行也回传仓颉侧 → stderr 留证
      if (window.__CJ_TAURI__) {
        window.__CJ_TAURI__.invoke('report', { line: line });
      }
    }

    function waitForBridge(cb) {
      if (window.__CJ_TAURI__) { cb(); return; }
      setTimeout(function () { waitForBridge(cb); }, 50);
    }

    var sh = null;

    function runVerify() {
      sh = window.__CJ_TAURI__.shell;
      show('shim-ready-at-script-start=' + shimReadyAtScriptStart);
      show('shell-namespace-type=' + (typeof sh));

      // 1) 打开链接：交给系统默认程序（Linux xdg-open / Windows rundll32 FileProtocolHandler）
      sh.open({ target: 'https://atomgit.com' })
        .then(function (ok) { show('shell:open(url) => ' + ok); })
        .catch(function (e) { show('shell:open FAIL => ' + e.message); })

        // 2) exec 取回 stdout：uname 的参数是 argv 直传，没有经过 shell
        .then(function () { return sh.exec({ program: 'uname', args: ['-a'] }); })
        .then(function (r) { show('shell:exec(uname) => code=' + r.code + ' stdout=' + r.stdout.trim()); })
        .catch(function (e) { show('shell:exec(uname) FAIL => ' + e.message); })

        // 3) 退出码与 stderr 分流：sh 是页面主动选用的程序，不是框架偷偷过了 shell
        .then(function () { return sh.exec({ program: 'sh', args: ['-c', 'echo to-stderr 1>&2; exit 7'] }); })
        .then(function (r) { show('shell:exec(exit7) => code=' + r.code + ' stderr=' + r.stderr.trim()); })
        .catch(function (e) { show('shell:exec(exit7) FAIL => ' + e.message); })

        // 4) 注入对照：参数里的 && 只是普通字符串——若框架过 shell，这里会多出 INJECTED
        .then(function () { return sh.exec({ program: 'echo', args: ['a b', '&&', 'echo INJECTED'] }); })
        .then(function (r) { show('shell:exec(probe) => ' + r.stdout.trim()); })
        .catch(function (e) { show('shell:exec(probe) FAIL => ' + e.message); })

        // 5) 程序不存在：给可读错误而不是崩
        .then(function () { return sh.exec({ program: 'cj-tauri-no-such-program-xyz' }); })
        .then(function () { show('shell:exec(missing) FAIL => 竟然成功了'); })
        .catch(function (e) { show('shell:exec(missing) OK => ' + e.message); })

        // 6) 对照组：注册过但清单没放行的命令必须被拒
        .then(function () { return window.__CJ_TAURI__.invoke('system:devtools'); })
        .then(function () { show('DENY-FAIL system:devtools => 竟然放行了'); })
        .catch(function (e) { show('DENY-OK system:devtools: ' + e.message); })

        .then(function () { show('[verify] ALL DONE'); });
    }

    document.getElementById('btnOpenUrl').onclick = function () {
      sh.open({ target: 'https://atomgit.com' })
        .then(function (ok) { show('shell:open(url) => ' + ok); })
        .catch(function (e) { show('shell:open FAIL => ' + e.message); });
    };
    document.getElementById('btnOpenFile').onclick = function () {
      sh.open({ target: 'capabilities/app.json' })
        .then(function (ok) { show('shell:open(file) => ' + ok); })
        .catch(function (e) { show('shell:open(file) FAIL => ' + e.message); });
    };
    document.getElementById('btnUname').onclick = function () {
      sh.exec({ program: 'uname', args: ['-a'] })
        .then(function (r) { show('shell:exec(uname) => code=' + r.code + ' stdout=' + r.stdout.trim()); })
        .catch(function (e) { show('shell:exec(uname) FAIL => ' + e.message); });
    };
    document.getElementById('btnExit').onclick = function () {
      sh.exec({ program: 'sh', args: ['-c', 'echo to-stderr 1>&2; exit 7'] })
        .then(function (r) { show('shell:exec(exit7) => code=' + r.code + ' stderr=' + r.stderr.trim()); })
        .catch(function (e) { show('shell:exec(exit7) FAIL => ' + e.message); });
    };
    document.getElementById('btnProbe').onclick = function () {
      sh.exec({ program: 'echo', args: ['a b', '&&', 'echo INJECTED'] })
        .then(function (r) { show('shell:exec(probe) => ' + r.stdout.trim()); })
        .catch(function (e) { show('shell:exec(probe) FAIL => ' + e.message); });
    };

    // 异步分发实证：慢命令（框架侧 slow，睡 3 秒）跑起来后心跳照常。
    // 心跳每 500ms 一次 system:version 往返——既要 JS 引擎有空，也要仓颉侧的 IPC 分发有空。
    document.getElementById('btnSlow').onclick = function () {
      var t0 = Date.now();
      var n = 0;
      show('slow: start（命令睡 3 秒，看下面心跳是否照常）');
      var hb = setInterval(function () {
        n = n + 1;
        var k = n;   // 每跳先捕获自己的序号：promise 回投时 n 可能已涨，直接读 n 会把几条都印成同一个号
        window.__CJ_TAURI__.invoke('system:version').then(function (v) {
          show('hb n=' + k + ' +' + (Date.now() - t0) + 'ms version=' + JSON.stringify(v));
        }).catch(function (e) { show('hb n=' + k + ' FAIL => ' + e.message); });
      }, 500);
      window.__CJ_TAURI__.invoke('slow').then(function (ok) {
        clearInterval(hb);
        show('slow: done ok=' + ok + ' +' + (Date.now() - t0) + 'ms，心跳发到 n=' + n + '（中途没有整段静默即 UI 未被卡住）');
      }).catch(function (e) {
        clearInterval(hb);
        show('slow FAIL => ' + e.message);
      });
    };

    // 自动化实证：等页面稳下来再依次跑（人工点击走上面的按钮）
    setTimeout(function () { waitForBridge(runVerify); }, 1200);
  </script>
</body>
</html>
"""
    eprintln("[plugin-shell] before run")
    app.run(html)
    eprintln("[plugin-shell] after run")
    return 0
}
