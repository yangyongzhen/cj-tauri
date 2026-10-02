package plugin_fs

import cjTauri.*
import stdx.encoding.json.*

/**
 * 插件体系示例：接入官方 fs 插件只需一行 .plugin(FsPlugin())
 *
 * 要看的证据（stderr）：
 *  1. 启动时打印「已装配插件」清单（插件名 + 命令全名）；
 *  2. capability 只放行 fs:readText / fs:exists，故意漏掉 fs:writeText
 *     → 启动时给出「缺哪条、加到哪」的提示；
 *  3. 前端脚本第一行就读到 __CJ_TAURI__.fs（证明 shim 早于页面脚本）；
 *  4. fs:readText / fs:exists 成功，fs:writeText 被拒 —— 默认最小权限的对照组。
 *
 * 运行目录 = 本示例根（capabilities/ 按相对路径解析，与 hello 一致）。
 */
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
    eprintln("[plugin-fs] main start")

    let app = TauriApp()
        .window(WindowConfig("cj-tauri 插件 fs 示例", 900, 620))
        .plugin(FsPlugin())          // 插件体系：一行接入（对标 Tauri v2 的 .plugin(...)）
        .register("report", ReportCommand())

    // 前端页面：内联 HTML（与 examples/hello 同风格，零 Node 依赖）
    let html = """
<!DOCTYPE html>
<html>
<head>
<meta charset="utf-8">
<title>cj-tauri 插件 fs 示例</title>
<style>
  body { font-family: system-ui, sans-serif; background: #141a2e; color: #eee;
         display: flex; flex-direction: column; align-items: center; padding-top: 48px; }
  h1 { color: #7ce7ff; margin-bottom: 4px; }
  .card { background: #1b2440; border-radius: 12px; padding: 20px 26px; width: 640px;
          box-shadow: 0 8px 24px rgba(0,0,0,.4); }
  pre { background: #0d1226; border-radius: 8px; padding: 12px; font-size: 13px;
        line-height: 1.5; white-space: pre-wrap; word-break: break-all; margin: 10px 0 0; }
  button { background: #e94560; color: #fff; border: none; border-radius: 8px;
           padding: 8px 14px; font-size: 14px; cursor: pointer; }
  button:hover { opacity: .85; }
  .muted { color: #8b93b0; font-size: 12px; }
</style>
</head>
<body>
  <h1>cj-tauri 插件 fs</h1>
  <div class="card">
    <p>一行 <b>.plugin(FsPlugin())</b> 接入；权限仍由 capabilities 决定。
      <br><span class="muted">本示例故意只放行 fs:readText / fs:exists，fs:writeText 不在清单里。</span></p>
    <p><button id="again">重跑一遍</button></p>
    <pre id="log">readText / exists / writeText(对照) …</pre>
  </div>
  <script>
    // 第一行就读插件命名空间：head 里的 shim 应当已经跑过（早于本脚本）
    var shimReadyAtScriptStart = !!(window.__CJ_TAURI__ && window.__CJ_TAURI__.fs);

    var logEl = document.getElementById('log');
    var lines = [];

    function show(line) {
      lines.push(line);
      // 换行用 fromCharCode(10) 现算：本段 JS 写在仓颉三引号字符串里，
      // 反斜杠转义会先被仓颉处理掉，写反斜杠-n 会变成真换行把 JS 拆断（整段语法错误）
      logEl.textContent = lines.join(String.fromCharCode(10));
      // 同一行也回传仓颉侧 → stderr 留证
      if (window.__CJ_TAURI__) {
        window.__CJ_TAURI__.invoke('report', { line: line });
      }
    }

    function waitForBridge(cb) {
      if (window.__CJ_TAURI__) { cb(); return; }
      setTimeout(function () { waitForBridge(cb); }, 50);
    }

    function runVerify() {
      var fs = window.__CJ_TAURI__.fs;
      show('shim-ready-at-script-start=' + shimReadyAtScriptStart);
      show('fs-namespace-type=' + (typeof fs));

      // 1) 放行过的命令：应当成功
      fs.exists({ path: 'capabilities/default.json' })
        .then(function (v) { show('fs:exists(capabilities/default.json) => ' + v); })
        .catch(function (e) { show('fs:exists FAIL => ' + e.message); });

      fs.readText({ path: 'capabilities/default.json' })
        .then(function (text) {
          show('fs:readText OK => ' + text.length + ' chars; contains fs:readText=' +
               (text.indexOf('fs:readText') >= 0));
        })
        .catch(function (e) { show('fs:readText FAIL => ' + e.message); });

      fs.exists({ path: 'no-such-file-xyz.txt' })
        .then(function (v) { show('fs:exists(missing) => ' + v); })
        .catch(function (e) { show('fs:exists(missing) FAIL => ' + e.message); });

      // 2) 对照组：没在 capability 里放行的命令必须被拒
      fs.writeText({ path: '/tmp/cj-plugin-should-not-exist.txt', contents: 'x' })
        .then(function (v) { show('DENY-FAIL fs:writeText => ' + JSON.stringify(v)); })
        .catch(function (e) { show('DENY-OK fs:writeText: ' + e.message); });

      setTimeout(function () { show('[verify] ALL DONE'); }, 1500);
    }

    document.getElementById('again').onclick = function () {
      waitForBridge(runVerify);
    };

    waitForBridge(runVerify);
  </script>
</body>
</html>
"""
    eprintln("[plugin-fs] before run")
    app.run(html)
    eprintln("[plugin-fs] after run")
    return 0
}
