package ipc_coalesce

import cjTauri.*
import stdx.encoding.json.*

/*
 * 事件合并示例（`emitLatest` 与 `emit` 的对照）。
 *
 * 页面侧挂一个 'progress' 监听器，再让后端**连发 50 条**同名事件（一串事件会落进同一个空闲回调窗口），
 * 两种走法各一轮：
 *   1) `ipc.emitLatest`：同一批刷窗口内的同名事件只投**最后一次** payload（中间值丢弃，尾值必达）→
 *      监听器命中次数 = 这串事件落进了几个批刷窗口（实测 1–2，**不要断言恰好 1**）；
 *   2) `ipc.emit`（默认路径，对照组）：逐条投递 → 命中 50 次。
 * 另外单发一条 `emitLatest`，验证「走合并路径的单条事件也不丢」。
 * 结论由页面经 `report` 命令回传到仓颉侧 stderr——凭证是日志行，不是页面上显示的东西。
 *
 * 跑法（工作目录必须是本工程根，`capabilities/` 按相对路径读）：
 *   bash ../../native/build_linux.sh                 # 先有 native/libcjtbridge.so
 *   xvfb-run -a ./target/release/bin/main 2>&1 | grep '\[probe\]'
 * 直接 `cjpm run` 也可以，但要按 `scripts/test.sh` 的方式补上 LD_LIBRARY_PATH（Linux 上找不到
 * 运行时会静默退出）。
 */

/**
 * 把页面结论打回 stderr：本次取证的凭证就是日志行，不许只在页面上显示。
 */
public class ReportCommand <: CommandHandler {
    public init() {}

    public func handle(cmd: String, args: JsonObject, ipc: IpcContext): JsonValue {
        if (let Some(line) <- args.get("line")) {
            match (line.kind()) {
                case JsonKind.JsString => eprintln("[probe] " + line.asString().getValue())
                case _ => ()
            }
        }
        return JsonBool(true)
    }
}

/** 取顶层 int 参数（缺失 / 类型不对用缺省值） */
func intArg(args: JsonObject, key: String, dflt: Int64): Int64 {
    if (let Some(v) <- args.get(key)) {
        match (v.kind()) {
            case JsonKind.JsInt => return v.asInt().getValue()
            case _ => ()
        }
    }
    return dflt
}

/** 取顶层 bool 参数 */
func boolArg(args: JsonObject, key: String, dflt: Bool): Bool {
    if (let Some(v) <- args.get(key)) {
        match (v.kind()) {
            case JsonKind.JsBool => return v.asBool().getValue()
            case _ => ()
        }
    }
    return dflt
}

/**
 * 突发推送：`latest=true` 走 `emitLatest`（合并），否则走 `emit`（逐条）。
 *
 * 循环里连发是有意的：桥按空闲回调批刷（一次最多拼 64 条），连发才能让这串事件落进同一个窗口，
 * 「同帧合并」的语义才测得出来。
 */
public class BurstCommand <: CommandHandler {
    public init() {}

    public func handle(cmd: String, args: JsonObject, ipc: IpcContext): JsonValue {
        let n = intArg(args, "n", 0)
        let latest = boolArg(args, "latest", false)
        var i: Int64 = 0
        while (i < n) {
            var p = JsonObject()
            p.put("n", JsonInt(i + 1))
            if (latest) {
                ipc.emitLatest("progress", p)
            } else {
                ipc.emit("progress", p)
            }
            i += 1
        }
        eprintln("[probe] burst dispatched: n=${n} latest=${latest}")
        return JsonInt(n)
    }
}

main(): Int64 {
    eprintln("[probe-coalesce] main start")
    let app = TauriApp()
        .window(WindowConfig("cj-tauri 事件合并示例", 760, 440))
        .register("report", ReportCommand())
        .register("burst", BurstCommand())

    let html = """
<!DOCTYPE html>
<html>
<head><meta charset="utf-8"><title>cj-tauri emitLatest probe</title>
<style>body { font-family: ui-monospace, monospace; background: #16161d; color: #ddd; padding: 24px; }</style>
</head>
<body>
<div id="status">waiting for bridge...</div>
<script>
var tauri = window.__CJ_TAURI__;
function report(line) { return tauri.invoke('report', { line: line }); }
function delay(ms) { return new Promise(function (r) { setTimeout(r, ms); }); }

async function probe() {
  document.getElementById('status').textContent = 'running';

  var hits = 0;
  var lastN = -1;
  tauri.listen('progress', function (p) { hits++; lastN = (p && p.n !== undefined) ? p.n : -1; });

  // 1) emitLatest × 50：同一批刷窗口内只该投一次，值是最新那条；跨窗口会各投一次（见文件头注释）
  hits = 0; lastN = -1;
  await tauri.invoke('burst', { n: 50, latest: true });
  await delay(600);
  await report('PROBE-1 coalesced: emitted=50 listener-hits=' + hits + ' last-n=' + lastN + ' (want hits<50 last-n=50)');

  // 2) 对照 emit × 50：默认路径不做合并，逐条投递
  hits = 0; lastN = -1;
  await tauri.invoke('burst', { n: 50, latest: false });
  await delay(600);
  await report('PROBE-2 plain-emit: emitted=50 listener-hits=' + hits + ' last-n=' + lastN + ' (want hits=50 last-n=50)');

  // 3) emitLatest × 1：走合并路径的单条事件也必须送达（尾值不丢）
  hits = 0; lastN = -1;
  await tauri.invoke('burst', { n: 1, latest: true });
  await delay(600);
  await report('PROBE-3 single-latest: emitted=1 listener-hits=' + hits + ' last-n=' + lastN + ' (want hits=1 last-n=1)');

  await report('PROBE-4 ALL DONE');
}

if (window.__CJ_TAURI__) { probe(); }
else { setTimeout(function () { tauri = window.__CJ_TAURI__; probe(); }, 100); }
</script>
</body>
</html>
"""
    app.run(html)
    eprintln("[probe-coalesce] after run")
    return 0
}
