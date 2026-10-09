package plugin_serial

import cjTauri.*
import std.env.*
import stdx.encoding.json.*

/**
 * 插件体系示例：接入官方 serial 插件只需一行 .plugin(SerialPlugin())（对标 Tauri v2 的 .plugin(...)）
 *
 * 三处联动在本示例里齐了（漏一处命令就用不了，见 AGENTS §2）：
 *   1. 实现：框架自带 SerialPlugin（src/plugin_serial.cj）
 *   2. 装配：下面那行 .plugin(SerialPlugin())
 *   3. 声明：capabilities/default.json —— 本示例故意用**两种写法各来一份**：
 *        permissions: ["serial:readonly"]  → 命名集（open / read / close）
 *        commands:    [... "serial:write"] → 明文（写能力必须显式列出，不在 readonly 集里）
 *      集声明 ≠ 放行：清单不引用就不生效（默认最小权限不破）。
 *
 * 两种跑法：
 *   手动：起窗口，填设备路径 + 波特率，点 open / write / read / close。
 *   探针：设 CJ_SERIAL_PROBE_PATH 后启动，应用把配置经 **document-start 预执行脚本**注入页面，
 *        页面脚本在加载时自动跑一轮 open → write（等一会）→ read → close 并自退，
 *        证据全在 stderr：桥的 `serial open:` / `serial termios:` / `serial close:` 行
 *        与页面的 `[frontend] serial:… => …` 行（`report` 命令回投）。
 *        Linux 侧一键跑通见 run.sh（用 python3 的 pty 造虚拟串口对，读写闭环不需要真设备，也不需要 socat）。
 *        其它环境变量：CJ_SERIAL_PROBE_BAUD / DATA / ENCODING(utf8|hex) / READ_MS / QUIT(0|1)。
 *
 * 运行目录 = 本示例根（capabilities/ 按相对路径解析，与 hello 一致）。
 */

/** 把前端每一行回投到 stderr（诊断一律走 stderr，AGENTS §4）——探针取证靠的就是这一条 */
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

/**
 * 前端主动退应用（探针跑完一轮就走，自动化脚本才好收尾）
 *
 * 命令跑在 worker 线程上，而 quit 在平台层是「投到 GUI 线程」的（Linux 走 g_idle_add，
 * Windows 走消息循环），所以从命令里退是安全的——GTK / WebView2 的调用仍留在宿主那条线程上。
 */
public class QuitCommand <: CommandHandler {
    private let app: TauriApp

    public init(app: TauriApp) {
        this.app = app
    }

    public func handle(cmd: String, args: JsonObject, ipc: IpcContext): JsonValue {
        eprintln("[plugin-serial] quit requested by frontend")
        this.app.quit()
        return JsonBool(true)
    }
}

func envOr(name: String, fallback: String): String {
    match (getVariable(name)) {
        case Some(v) => return v
        case None => return fallback
    }
}

main(): Int64 {
    eprintln("[plugin-serial] main start")

    let plugin = SerialPlugin()
    let app = TauriApp()
        .window(WindowConfig("cj-tauri 插件 serial 示例", 860, 640))
        .plugin(plugin)                        // 插件体系：一行接入
        .register("report", ReportCommand())
    app.register("quit", QuitCommand(app))     // 要引用 app 本身，所以这条不串在链上
    eprintln("[plugin-serial] 插件 serial：命令 ${plugin.commands().size} 条，命名权限集 ${plugin.permissions().size} 组")

    // 探针模式：给了设备路径就把配置注入页面（document-start，早于页面脚本）。
    // 字面量用 JSON 编码器拼——Windows 的 \\.\COM3 这种路径里的反斜杠自动转义，不必手写
    // （三引号字符串里的反斜杠会被仓颉先吃掉，AGENTS §4 记过）。
    let probePath = envOr("CJ_SERIAL_PROBE_PATH", "")
    if (probePath.size > 0) {
        let baud = envOr("CJ_SERIAL_PROBE_BAUD", "115200")
        let data = envOr("CJ_SERIAL_PROBE_DATA", "cj-tauri-ping")
        let encoding = envOr("CJ_SERIAL_PROBE_ENCODING", "utf8")
        let readMs = envOr("CJ_SERIAL_PROBE_READ_MS", "400")
        let quit = envOr("CJ_SERIAL_PROBE_QUIT", "1")
        let js = "window.__SERIAL_PROBE__ = { path: " + JsonString(probePath).toJsonString() +
            ", baud: " + JsonString(baud).toJsonString() +
            ", data: " + JsonString(data).toJsonString() +
            ", encoding: " + JsonString(encoding).toJsonString() +
            ", readMs: " + JsonString(readMs).toJsonString() +
            ", quit: " + JsonString(quit).toJsonString() + " };\n"
        match (app.hostOf("main")) {
            case Some(host) =>
                host.addInitScript(js)
                eprintln("[plugin-serial] 探针模式：path=${probePath} baud=${baud} data=${data}" +
                    " encoding=${encoding} readMs=${readMs} quit=${quit}")
            case None => eprintln("[plugin-serial] 探针模式：主窗未登记，配置没注入")
        }
    }

    let html = """
<!DOCTYPE html>
<html>
<head>
<meta charset="utf-8">
<title>cj-tauri 插件 serial 示例</title>
<style>
  body { font-family: system-ui, sans-serif; background: #141a2e; color: #eee;
         display: flex; flex-direction: column; align-items: center; padding: 28px 0; }
  h1 { color: #7ce7ff; margin: 0 0 4px; }
  .card { background: #1b2440; border-radius: 12px; padding: 18px 24px; width: 720px;
          box-shadow: 0 8px 24px rgba(0,0,0,.4); margin-bottom: 14px; }
  pre { background: #0d1226; border-radius: 8px; padding: 12px; font-size: 13px;
        line-height: 1.5; white-space: pre-wrap; word-break: break-all; margin: 8px 0 0;
        max-height: 260px; overflow: auto; }
  button { background: #e94560; color: #fff; border: none; border-radius: 8px;
           padding: 7px 13px; font-size: 14px; cursor: pointer; margin-right: 6px; }
  button:hover { opacity: .85; }
  input { background: #0d1226; color: #eee; border: 1px solid #35406b; border-radius: 6px;
          padding: 6px 8px; font-size: 14px; }
  .muted { color: #8b93b0; font-size: 12px; }
  label { font-size: 13px; color: #b9c2dd; }
</style>
</head>
<body>
  <h1>cj-tauri 插件 serial</h1>
  <div class="card">
    <p>一行 <b>.plugin(SerialPlugin())</b> 接入；权限仍由 capabilities 决定。
      <br><span class="muted">本示例：permissions 引用命名集 <b>serial:readonly</b>（open/read/close），
      commands 里明文追加 <b>serial:write</b>——两种写法混用等价。</span></p>
    <p>
      <label>设备</label> <input id="path" size="34" value="/dev/ttyUSB0">
      <label>波特率</label> <input id="baud" size="8" value="115200">
    </p>
    <p>
      <label>数据</label> <input id="data" size="22" value="hello-from-cj-tauri">
      <label>十六进制</label> <input id="hex" type="checkbox">
    </p>
    <p><button id="bOpen">open</button><button id="bWrite">write</button>
       <button id="bRead">read</button><button id="bClose">close</button></p>
    <pre id="log">等待桥就绪…</pre>
  </div>
  <script>
    // 第一行就读插件命名空间：head 里的 shim 应当已经跑过（早于本脚本）
    var shimReadyAtScriptStart = !!(window.__CJ_TAURI__ && window.__CJ_TAURI__.serial);

    var logEl = document.getElementById('log');
    var lines = [];
    var handle = 0;

    function show(line) {
      lines.push(line);
      // 换行用 fromCharCode(10) 现算：本段 JS 写在仓颉三引号字符串里，反斜杠转义会先被仓颉吃掉，
      // 写反斜杠-n 会变成真换行把 JS 拆断（整段语法错误，页面里一行都不执行）
      logEl.textContent = lines.join(String.fromCharCode(10));
      if (window.__CJ_TAURI__) {
        window.__CJ_TAURI__.invoke('report', { line: line });
      }
    }

    function waitForBridge(cb) {
      if (window.__CJ_TAURI__ && window.__CJ_TAURI__.serial) { cb(); return; }
      setTimeout(function () { waitForBridge(cb); }, 50);
    }

    function sleep(ms) {
      return new Promise(function (resolve) { setTimeout(resolve, ms); });
    }

    function ser() { return window.__CJ_TAURI__.serial; }

    function manualArgs() {
      return { path: document.getElementById('path').value,
               baud: parseInt(document.getElementById('baud').value, 10),
               dataBits: 8, parity: 'none', stopBits: 1 };
    }

    function manualData() {
      return { handle: handle,
               data: document.getElementById('data').value,
               encoding: document.getElementById('hex').checked ? 'hex' : 'utf8' };
    }

    document.getElementById('bOpen').onclick = function () {
      ser().open(manualArgs()).then(function (r) {
        handle = r.handle;
        show('serial:open => handle=' + r.handle + ' path=' + r.path +
             ' baud=' + r.baud + ' dataBits=' + r.dataBits + ' parity=' + r.parity +
             ' stopBits=' + r.stopBits);
      }).catch(function (e) { show('serial:open FAIL => ' + e.message); });
    };

    document.getElementById('bWrite').onclick = function () {
      ser().write(manualData()).then(function (w) {
        show('serial:write => written=' + w.written + '/' + w.bytes);
      }).catch(function (e) { show('serial:write FAIL => ' + e.message); });
    };

    document.getElementById('bRead').onclick = function () {
      ser().read({ handle: handle, maxBytes: 64, timeoutMs: 400 }).then(function (r) {
        show('serial:read => count=' + r.count + ' hex=' + r.hex + ' text=' + JSON.stringify(r.text));
      }).catch(function (e) { show('serial:read FAIL => ' + e.message); });
    };

    document.getElementById('bClose').onclick = function () {
      ser().close({ handle: handle }).then(function (v) {
        show('serial:close => ' + v + '（句柄 ' + handle + ' 已释放）');
        handle = 0;
      }).catch(function (e) { show('serial:close FAIL => ' + e.message); });
    };

    // 探针模式：应用侧（环境变量 CJ_SERIAL_PROBE_PATH）注入的配置，页面加载时自动跑一轮并自退。
    // 这条链才是「页面 → 桥 → IPC → 能力校验 → 命令 → C 桥 → 串口」的完整一跳。
    function runProbe(p) {
      var ms = parseInt(p.readMs, 10);
      show('[probe] start path=' + p.path + ' baud=' + p.baud + ' encoding=' + p.encoding +
           ' data=' + p.data);
      return ser().open({ path: p.path, baud: parseInt(p.baud, 10), dataBits: 8,
                          parity: 'none', stopBits: 1 })
        .then(function (r) {
          handle = r.handle;
          show('serial:open => handle=' + r.handle + ' path=' + r.path + ' baud=' + r.baud);
          return ser().write({ handle: handle, data: p.data, encoding: p.encoding });
        })
        .then(function (w) {
          show('serial:write => written=' + w.written + '/' + w.bytes);
          return sleep(ms);
        })
        .then(function () {
          return ser().read({ handle: handle, maxBytes: 64, timeoutMs: ms });
        })
        .then(function (r) {
          show('serial:read => count=' + r.count + ' hex=' + r.hex + ' text=' + JSON.stringify(r.text));
          return ser().close({ handle: handle });
        })
        .then(function (v) {
          show('serial:close => ' + v);
          show('[probe] ALL DONE');
          if (p.quit === '1') { setTimeout(function () { window.__CJ_TAURI__.invoke('quit', {}); }, 400); }
        })
        .catch(function (e) {
          show('[probe] FAIL => ' + e.message);
          if (p.quit === '1') { setTimeout(function () { window.__CJ_TAURI__.invoke('quit', {}); }, 400); }
        });
    }

    waitForBridge(function () {
      show('shim-ready-at-script-start=' + shimReadyAtScriptStart);
      show('serial-namespace-type=' + (typeof window.__CJ_TAURI__.serial));
      if (window.__SERIAL_PROBE__) {
        runProbe(window.__SERIAL_PROBE__);
      } else {
        show('（手动模式：填设备路径后点 open / write / read / close）');
      }
    });
  </script>
</body>
</html>
"""

    eprintln("[plugin-serial] before run")
    app.run(html)
    eprintln("[plugin-serial] after run")
    return 0
}
