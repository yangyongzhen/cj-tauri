package plugin_dialog

import cjTauri.*
import stdx.encoding.json.*

/**
 * 插件体系示例：接入官方 dialog 插件只需一行 .plugin(DialogPlugin())
 *
 * 要看的证据（stderr + 截图）：
 *  1. 启动时打印「已装配插件」清单与命名权限集（dialog:files / dialog:default）；
 *  2. capability 用 permissions: ["dialog:default"] 一次放行三条命令——清单里没写死任何命令名；
 *  3. 前端第一行就读到 __CJ_TAURI__.dialog（证明 shim 早于页面脚本）；
 *  4. 弹的是**系统原生**对话框（Linux/GTK、Windows/Win32）：提示框、打开文件、保存文件；
 *  5. 对照组：system:devtools 已注册但不在清单里 → 被拒（默认最小权限不被破坏）。
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
    eprintln("[plugin-dialog] main start")

    let app = TauriApp()
        .window(WindowConfig("cj-tauri 插件 dialog 示例", 900, 620))
        .plugin(DialogPlugin())      // 插件体系：一行接入（对标 Tauri v2 的 .plugin(...)）
        .register("report", ReportCommand())

    // 前端页面：内联 HTML（与 examples/hello 同风格，零 Node 依赖）
    let html = """
<!DOCTYPE html>
<html>
<head>
<meta charset="utf-8">
<title>cj-tauri 插件 dialog 示例</title>
<style>
  body { font-family: system-ui, sans-serif; background: #141a2e; color: #eee;
         display: flex; flex-direction: column; align-items: center; padding-top: 40px; }
  h1 { color: #7ce7ff; margin-bottom: 4px; }
  .card { background: #1b2440; border-radius: 12px; padding: 20px 26px; width: 660px;
          box-shadow: 0 8px 24px rgba(0,0,0,.4); }
  pre { background: #0d1226; border-radius: 8px; padding: 12px; font-size: 13px;
        line-height: 1.5; white-space: pre-wrap; word-break: break-all; margin: 10px 0 0; }
  button { background: #e94560; color: #fff; border: none; border-radius: 8px;
           padding: 8px 14px; font-size: 14px; cursor: pointer; margin-right: 6px; }
  button:hover { opacity: .85; }
  .muted { color: #8b93b0; font-size: 12px; }
</style>
</head>
<body>
  <h1>cj-tauri 插件 dialog</h1>
  <div class="card">
    <p>一行 <b>.plugin(DialogPlugin())</b> 接入；权限仍由 capabilities 决定。
      <br><span class="muted">本示例用命名权限集 permissions: ["dialog:default"] 一次放行三条命令；
      system:devtools 故意不在清单里，作未授权对照组。</span></p>
    <p>
      <button id="btnInfo">提示框</button>
      <button id="btnConfirm">确认框</button>
      <button id="btnOpen">打开文件</button>
      <button id="btnSave">保存文件</button>
    </p>
    <pre id="log">[dialog] …</pre>
  </div>
  <script>
    // 第一行就读插件命名空间：head 里的 shim 应当已经跑过（早于本脚本）
    var shimReadyAtScriptStart = !!(window.__CJ_TAURI__ && window.__CJ_TAURI__.dialog);

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

    var dlg = null;

    function runVerify() {
      dlg = window.__CJ_TAURI__.dialog;
      show('shim-ready-at-script-start=' + shimReadyAtScriptStart);
      show('dialog-namespace-type=' + (typeof dlg));

      // 1) 提示框：弹的是系统原生模态对话框，确认后 invoke 才 resolve
      dlg.message({ kind: 'info', title: 'cj-tauri dialog 示例',
                    message: '这是系统原生提示框（Linux/GTK、Windows/Win32）' })
        .then(function (ok) { show('dialog:message(info) => confirmed=' + ok); })
        .catch(function (e) { show('dialog:message FAIL => ' + e.message); })

        // 2) 打开文件：返回用户选中的路径（取消时返回空串）
        .then(function () {
          return dlg.open({ title: '挑一个文件（cj-tauri 示例）',
                            filter: '文本文件|*.txt|所有文件|*.*' });
        })
        .then(function (path) { show('dialog:open => path=' + JSON.stringify(path)); })
        .catch(function (e) { show('dialog:open FAIL => ' + e.message); })

        // 3) 对照组：注册过但清单没放行的命令必须被拒
        .then(function () {
          return window.__CJ_TAURI__.invoke('system:devtools');
        })
        .then(function () { show('DENY-FAIL system:devtools => 竟然放行了'); })
        .catch(function (e) { show('DENY-OK system:devtools: ' + e.message); })

        .then(function () { show('[verify] ALL DONE'); });
    }

    document.getElementById('btnInfo').onclick = function () {
      dlg.message({ kind: 'info', title: '提示', message: '原生提示框' })
        .then(function (ok) { show('dialog:message(info) => confirmed=' + ok); })
        .catch(function (e) { show('dialog:message FAIL => ' + e.message); });
    };
    document.getElementById('btnConfirm').onclick = function () {
      dlg.message({ kind: 'confirm', title: '确认', message: '确定要继续吗？' })
        .then(function (ok) { show('dialog:message(confirm) => confirmed=' + ok); })
        .catch(function (e) { show('dialog:message FAIL => ' + e.message); });
    };
    document.getElementById('btnOpen').onclick = function () {
      dlg.open({ title: '打开文件', filter: '文本文件|*.txt|所有文件|*.*' })
        .then(function (path) { show('dialog:open => path=' + JSON.stringify(path)); })
        .catch(function (e) { show('dialog:open FAIL => ' + e.message); });
    };
    document.getElementById('btnSave').onclick = function () {
      dlg.save({ title: '保存文件', filter: '文本文件|*.txt|所有文件|*.*' })
        .then(function (path) { show('dialog:save => path=' + JSON.stringify(path)); })
        .catch(function (e) { show('dialog:save FAIL => ' + e.message); });
    };

    // 自动化实证：等页面稳下来再依次弹（人工点击走上面的按钮）
    setTimeout(function () { waitForBridge(runVerify); }, 1200);
  </script>
</body>
</html>
"""
    eprintln("[plugin-dialog] before run")
    app.run(html)
    eprintln("[plugin-dialog] after run")
    return 0
}
