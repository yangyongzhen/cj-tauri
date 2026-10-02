package ipc_bench

import cjTauri.*
import stdx.encoding.json.*

/**
 * 最小往返：只回一个整数。
 * 把「协议本身的开销」与「业务逻辑开销」分开量——这一条里仓颉侧几乎没干活。
 */
public class PingCommand <: CommandHandler {
    public init() {}

    public func handle(cmd: String, args: JsonObject, ipc: IpcContext): JsonValue {
        return JsonInt(1)
    }
}

/**
 * 原样回显：量 payload 大小对往返的影响。
 * 回显意味着这份数据在链路上真的走了两趟（JS 序列化 → 仓颉解析 → 仓颉序列化 → JS 解析）。
 */
public class EchoCommand <: CommandHandler {
    public init() {}

    public func handle(cmd: String, args: JsonObject, ipc: IpcContext): JsonValue {
        if (let Some(d) <- args.get("data")) {
            return d
        }
        return JsonString("")
    }
}

/**
 * 连发 N 个事件：量「仓颉 → JS」这条只推不回的路径的单位成本。
 * 与 invoke 的差别在于没有 id 配对、没有 promise，只有一次投递 + 一次 JS 执行。
 */
public class EmitCommand <: CommandHandler {
    public init() {}

    public func handle(cmd: String, args: JsonObject, ipc: IpcContext): JsonValue {
        var count: Int64 = 0
        if (let Some(c) <- args.get("count")) {
            match (c.kind()) {
                case JsonKind.JsInt => count = c.asInt().getValue()
                case _ => ()
            }
        }
        for (i in 0..count) {
            var payload = JsonObject()
            payload.put("n", JsonInt(i))
            ipc.emit("bench:tick", payload)
        }
        return JsonInt(count)
    }
}

/** 把前端算好的结果打回 stderr：基准结果必须落在日志里才算证据 */
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
    eprintln("[ipc-bench] main start")
    var winCfg = WindowConfig("cj-tauri IPC 基准", 900, 620)
    let app = TauriApp()
        .window(winCfg)
        .register("bench:ping", PingCommand())
        .register("bench:echo", EchoCommand())
        .register("bench:emit", EmitCommand())
        .register("report", ReportCommand())

    // 页面只负责跑基准 + 显示进度，结果一律经 report 打回仓颉侧 stderr
    let html = """
<!DOCTYPE html>
<html>
<head>
<meta charset="utf-8">
<title>cj-tauri IPC bench</title>
<style>
  body { font-family: ui-monospace, monospace; background: #16161d; color: #ddd;
         display: flex; flex-direction: column; align-items: center; padding-top: 40px; }
  h1 { color: #7ce7ff; font-size: 20px; }
  .card { background: #1f1f29; border-radius: 12px; padding: 20px 28px; width: 560px; }
  #status { color: #50fa7b; }
  #log { white-space: pre-wrap; font-size: 12px; color: #9aa0b5; margin-top: 12px; }
</style>
</head>
<body>
  <h1>cj-tauri IPC 基准</h1>
  <div class="card">
    <div>状态: <span id="status">等待桥…</span></div>
    <div id="log"></div>
  </div>
  <script>
    var tauri = window.__CJ_TAURI__;
    var lines = [];

    function say(text) {
      lines.push(text);
      document.getElementById('log').textContent = lines.join(' | ');
    }
    function report(text) {
      say(text);
      return tauri.invoke('report', { line: text });
    }
    function fmt(n) { return Math.round(n * 1000) / 1000; }
    function stats(arr) {
      var s = arr.slice().sort(function (a, b) { return a - b; });
      var sum = 0;
      for (var i = 0; i < s.length; i++) { sum += s[i]; }
      return {
        min: s[0],
        p50: s[Math.floor(s.length * 0.5)],
        p95: s[Math.floor(s.length * 0.95)],
        max: s[s.length - 1],
        mean: sum / s.length
      };
    }
    function summary(tag, st) {
      return tag + ' min=' + fmt(st.min) + 'ms p50=' + fmt(st.p50) + 'ms p95=' + fmt(st.p95) +
             'ms max=' + fmt(st.max) + 'ms mean=' + fmt(st.mean) + 'ms';
    }

    // 1) 顺序往返延迟：一次一条，await 回来再发下一条
    async function benchLatency() {
      var N = 200, i, t0;
      for (i = 0; i < 20; i++) { await tauri.invoke('bench:ping'); }   // 预热
      var t = [];
      for (i = 0; i < N; i++) {
        t0 = performance.now();
        await tauri.invoke('bench:ping');
        t.push(performance.now() - t0);
      }
      await report('BENCH latency n=' + N + ' ' + summary('ping', stats(t)));
    }

    // 1b) 大批量顺序往返：逐条计时会被 performance.now() 的粒度限制（WebKitGTK 常是 1ms），
    //     所以量总墙钟再除——这条给出可信的微秒级均值。deny 那条用未授权命令，量「同步拒绝」快路径。
    async function benchScaled(tag, cmd, n) {
      var i;
      for (i = 0; i < 20; i++) { try { await tauri.invoke(cmd); } catch (e) { } }
      var t0 = performance.now();
      for (i = 0; i < n; i++) { try { await tauri.invoke(cmd); } catch (e) { } }
      var dt = performance.now() - t0;
      await report('BENCH ' + tag + ' n=' + n + ' wall=' + fmt(dt) + 'ms mean=' +
                   fmt(dt * 1000 / n) + 'us ops/s=' + Math.round(n / (dt / 1000)));
    }

    // 2) 吞吐：一次性发 N 条不等回，量总墙钟（含桥队列、worker、回投排队）
    async function benchThroughput() {
      var N = 500, i;
      var ps = [];
      for (i = 0; i < N; i++) { ps.push(tauri.invoke('bench:ping')); }
      var t0 = performance.now();
      await Promise.all(ps);
      var dt = performance.now() - t0;
      await report('BENCH throughput n=' + N + ' wall=' + fmt(dt) + 'ms ops/s=' + Math.round(N / (dt / 1000)));
    }

    // 3) payload 放大：不同大小的字符串回显，看单位成本与吞吐（MB/s）
    async function benchPayload(bytes, iters) {
      var data = 'x'.repeat(bytes), i;
      for (i = 0; i < 3; i++) { await tauri.invoke('bench:echo', { data: data }); }
      var t0 = performance.now();
      for (i = 0; i < iters; i++) { await tauri.invoke('bench:echo', { data: data }); }
      var dt = performance.now() - t0;
      var mbps = (bytes * iters) / (dt / 1000) / 1048576;
      await report('BENCH payload bytes=' + bytes + ' iters=' + iters +
                   ' mean=' + fmt(dt / iters) + 'ms MB/s=' + fmt(mbps));
    }

    // 4) 事件推送：仓颉连发 N 条，量从调用起到最后一条到达的墙钟（单位成本 = 只推不回）
    function benchEvents() {
      return new Promise(function (resolve, reject) {
        var N = 200, got = 0, t0 = 0, last = 0;
        var off = tauri.listen('bench:tick', function (payload) {
          got++;
          last = performance.now();
          if (got >= N) {
            off();
            var dt = last - t0;
            report('BENCH events n=' + N + ' received=' + got + ' wall=' + fmt(dt) +
                   'ms per=' + fmt(dt / N) + 'ms').then(resolve).catch(reject);
          }
        });
        setTimeout(function () {
          t0 = performance.now();
          tauri.invoke('bench:emit', { count: N }).catch(reject);
        }, 100);
      });
    }

    async function main() {
      if (!tauri) { document.getElementById('status').textContent = '未注入 __CJ_TAURI__'; return; }
      try {
        document.getElementById('status').textContent = 'running';
        await report('BENCH start ua=' + navigator.userAgent.slice(0, 48));
        await benchLatency();
        await benchScaled('latency_scaled', 'bench:ping', 2000);
        await benchScaled('deny_scaled', 'bench:nope', 2000);
        await benchThroughput();
        await benchPayload(1024, 100);
        await benchPayload(65536, 40);
        await benchPayload(1048576, 10);
        await benchEvents();
        await report('BENCH done');
        document.getElementById('status').textContent = 'done（结果见 stderr 日志）';
      } catch (e) {
        document.getElementById('status').textContent = 'FAIL';
        await report('BENCH FAIL ' + e.message);
      }
    }

    if (window.__CJ_TAURI__) { main(); }
    else { setTimeout(function () { tauri = window.__CJ_TAURI__; main(); }, 100); }
  </script>
</body>
</html>
"""
    app.run(html)
    eprintln("[ipc-bench] after run")
    return 0
}
