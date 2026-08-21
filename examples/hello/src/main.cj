package hello

import cjTauri.*
import stdx.encoding.json.*

/**
 * greet 命令：模拟 Tauri 官方 hello-world
 * 前端 invoke("greet", {"name": "..."}) → 返回 "Hello, ..."
 */
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
 * 定时器命令：每秒向 UI 推事件（验证 仓颉→JS 通道）
 * 前端 listen("tick") 接收
 */
public class TimerCommand <: CommandHandler {
    private var counter: Int64 = 0
    private var started: Bool = false

    public init() {}

    public func handle(cmd: String, args: JsonObject, ipc: IpcContext): JsonValue {
        if (!this.started) {
            this.started = true
            // 启动后台推送线程：每秒 emit tick
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
 * 验证报告命令：前端把验证结果回传，仓颉侧打印（端到端验证闭环）
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
    eprintln("[hello] main start")
    // 装配应用（对标 tauri::Builder）
    let app = TauriApp()
        .register("greet", GreetCommand())
        .register("timer", TimerCommand())
        .register("report", ReportCommand())

    // 加载能力清单（对标 capabilities/*.json）
    let capJson = JsonValue.fromStr("""
    {
        "identifier": "default",
        "windows": ["main"],
        "commands": ["greet", "timer", "system:version", "system:ping", "system:echo", "report"],
        "events": ["tick"]
    }""")
    app.addCapabilityJson(capJson)

    // 前端 HTML（Tauri 式 hello-world UI）
    let html = """
<!DOCTYPE html>
<html>
<head>
<meta charset="utf-8">
<title>cj-tauri hello</title>
<style>
  body { font-family: system-ui, sans-serif; background: #1a1a2e; color: #eee;
         display: flex; flex-direction: column; align-items: center; padding-top: 60px; }
  h1 { color: #7ce7ff; }
  .card { background: #16213e; border-radius: 12px; padding: 24px 32px; width: 420px;
          box-shadow: 0 8px 24px rgba(0,0,0,.4); }
  input, button { font-size: 15px; padding: 8px 12px; border-radius: 8px; border: none; }
  input { flex: 1; margin-right: 8px; background: #0f3460; color: #eee; }
  button { background: #e94560; color: #fff; cursor: pointer; }
  button:hover { opacity: .85; }
  .row { display: flex; margin: 12px 0; }
  #result { margin-top: 16px; min-height: 24px; font-size: 16px; }
  #tick { margin-top: 8px; color: #8be9fd; font-size: 13px; min-height: 20px; }
  .badge { color: #50fa7b; font-size: 12px; }
</style>
</head>
<body>
  <h1>cj-tauri</h1>
  <div class="card">
    <p>仓颉后端 + WebKit 前端（仿 Tauri 架构）<br><span class="badge">invoke / emit 双向 IPC</span></p>
    <div class="row">
      <input id="name" placeholder="输入名字" value="world">
      <button id="btn">greet</button>
    </div>
    <div id="result">等待 invoke…</div>
    <div id="tick"></div>
  </div>
  <script>

    // ==== 自动验证（端到端）====
    function runVerify() {
      if (!window.__CJ_TAURI__) { setTimeout(runVerify, 100); return; }
      var tauri = window.__CJ_TAURI__;

      // 按钮点击 greet（用户交互）
      document.getElementById('btn').onclick = function () {
        var name = document.getElementById('name').value || 'world';
        tauri.invoke('greet', { name: name })
          .then(function (data) {
            document.getElementById('result').textContent = 'invoke OK: ' + data;
          })
          .catch(function (err) {
            document.getElementById('result').textContent = 'invoke FAIL: ' + err.message;
          });
      };
      // 监听后端事件（仓颉 → JS）
      tauri.listen('tick', function (payload) {
        document.getElementById('tick').textContent = '事件 tick #' + payload.n + ' 来自仓颉后端';
      });

      var results = [];
      function report(line) { results.push(line); }
      function checkFinish() {
        setTimeout(function () {
          if (results.length >= 5) {
            var snapshot = results.slice();
            for (var j = 0; j < snapshot.length; j++) {
              (function (line) { tauri.invoke('report', { line: line }); })(snapshot[j]);
            }
            tauri.invoke('report', { line: '[verify] ALL DONE' });
          }
        }, 4000);
      }
      tauri.invoke('greet', { name: '仓颉' })
        .then(function (d) { report('greet OK: ' + d); checkFinish(); })
        .catch(function (e) { report('greet FAIL: ' + e.message); checkFinish(); });
      tauri.invoke('system:ping')
        .then(function (d) { report('system:ping OK: ' + d); checkFinish(); })
        .catch(function (e) { report('system:ping FAIL: ' + e.message); checkFinish(); });
      tauri.invoke('system:rm')
        .then(function (d) { report('DENY-FAIL system:rm => ' + JSON.stringify(d)); checkFinish(); })
        .catch(function (e) { report('DENY-OK system:rm: ' + e.message); checkFinish(); });
      tauri.invoke('no_such_cmd')
        .then(function (d) { report('UNREG-FAIL: ' + JSON.stringify(d)); checkFinish(); })
        .catch(function (e) { report('UNREG-OK no_such_cmd: ' + e.message); checkFinish(); });
      var tickCount = 0;
      tauri.listen('tick', function (payload) {
        tickCount++;
        report('tick #' + payload.n);
        if (tickCount >= 2) checkFinish();
      });
      tauri.invoke('timer')
        .then(function (d) { report('timer: ' + d); checkFinish(); })
        .catch(function (e) { report('timer FAIL: ' + e.message); checkFinish(); });
      setTimeout(function () {
        for (var i = 0; i < results.length; i++) tauri.invoke('report', { line: results[i] });
        tauri.invoke('report', { line: '[verify] FALLBACK results=' + results.length + ' tick=' + tickCount });
      }, 12000);
    }
    runVerify();
</script>
</body>
</html>
"""
    eprintln("[hello] before run")
    app.run(html)
    eprintln("[hello] after run")
    return 0
}
