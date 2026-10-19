package cjTauri

/**
 * 鸿蒙 ArkWeb 侧的页面桥脚本与注入片段
 *
 * ## 为什么要另存一份（而不是复用 `native/core/bridge_js.h`）
 *
 * 那一份是 **C 宏**（`CJ_BRIDGE_JS(POST_STMT, RELOAD_STMT)`），只有编 C 桥的平台能用；
 * 鸿蒙没有 C 桥（宿主在仓颉侧直接驱动 ArkWeb），拿不到宏展开结果。所以这里按同一份语义
 * 落成仓颉常量——**改动要两边同步**，判断「哪边漏了」的判据是：页面上 `invoke` / `emit` /
 * `listen` / `reload` / `_dispatch` 五个入口的行为是否与桌面一致（桥只负责路由与回执匹配，
 * 不含业务）。
 *
 * ## 与桌面版的唯一差异
 *
 * `post`：桌面走 `window.chrome.webview.postMessage` / `window.webkit.messageHandlers`，
 * 鸿蒙走 `javaScriptProxy` 注入的同步方法（`window.__CJ_TAURI_HOST__.post(json)`）。
 * 同步调用不携带返回值语义——它是「投递即返回」，回执仍由 `_dispatch` 从仓颉侧推回来。
 *
 * ## 转义口径
 *
 * 用 raw string（`#"..."#`）：三引号字符串会先处理反斜杠转义（AGENTS §4 踩过，内联 JS 会被
 * 拆断而 stderr 一行提示都没有），raw string 原样保留。因此本文件里的 JS **不要**出现 `"#`
 * 这个序列（那是 raw string 的收尾）。
 */
@When[env == "ohos"]
import std.collection.*

@When[env == "ohos"]
public let ARKWEB_PROXY_NAME: String = "__CJ_TAURI_HOST__"

@When[env == "ohos"]
let ARKWEB_BRIDGE_JS: String = #"window.__CJ_TAURI__ = (function () {
  var seq = 0;
  var pending = {};
  var listeners = {};
  var coalesceSlots = Object.create(null);
  var coalesceTimer = null;
  var coalesceRaf = 0;
  function flushCoalesced() {
    if (coalesceTimer !== null) { clearTimeout(coalesceTimer); coalesceTimer = null; }
    coalesceRaf = 0;
    var due = coalesceSlots;
    coalesceSlots = Object.create(null);
    for (var name in due) {
      var arr = listeners[name] || [];
      for (var i = 0; i < arr.length; i++) arr[i](due[name]);
    }
  }
  function scheduleCoalesced() {
    if (coalesceTimer !== null || coalesceRaf) return;
    coalesceTimer = setTimeout(flushCoalesced, 50);
  }
  var cachedLabel = null;
  function labelOf() {
    if (cachedLabel === null) {
      var v = (typeof window !== 'undefined') ? window.__CJ_TAURI_LABEL__ : null;
      cachedLabel = (typeof v === 'string' && v.length > 0) ? v : 'main';
    }
    return cachedLabel;
  }
  function post(obj) {
    try {
      var host = window.__CJ_TAURI_HOST__;
      if (host && typeof host.post === 'function') host.post(JSON.stringify(obj));
    } catch (e) { }
  }
  /*
   * 原生 -> 页面的推送：页面**只负责叫一声**，脚本由原生在 post 回调里用
   * `controller.runJavaScript` 推回来。
   *
   * 为什么不是「页面 poll 取返回值」：2026-10-19 真机实测，`javaScriptProxy` 的
   * funcList 返回值**传不回 JS**（换上无条件返回固定串的桩，页面拿到的仍是 null），
   * 而 post 方向一切正常。所以同步取数模型不成立，只能反过来推。
   * 心跳周期的代价只是一次同步调用；队列空时原生什么都不做。
   */
  var pumping = false;
  function pump() {
    if (pumping) return;
    pumping = true;
    try {
      var host = window.__CJ_TAURI_HOST__;
      if (host && typeof host.post === 'function') {
        host.post('{"type":"pull","window":' + JSON.stringify(labelOf()) + '}');
      }
    } catch (e2) { } finally { pumping = false; }
  }
  try { setInterval(pump, 50); } catch (e3) { }
  return {
    invoke: function (cmd, args) {
      var id = ++seq;
      var p = new Promise(function (resolve, reject) { pending[id] = { resolve: resolve, reject: reject }; });
      post({ type: 'invoke', id: id, cmd: cmd, args: args || {}, window: labelOf() });
      return p;
    },
    listen: function (event, cb) {
      if (!listeners[event]) listeners[event] = [];
      listeners[event].push(cb);
      return function () {
        var arr = listeners[event] || [];
        var i = arr.indexOf(cb);
        if (i >= 0) arr.splice(i, 1);
      };
    },
    emit: function (event, payload) {
      var id = ++seq;
      var p = new Promise(function (resolve, reject) { pending[id] = { resolve: resolve, reject: reject }; });
      post({ type: 'emit', id: id, event: event, payload: payload === undefined ? {} : payload, window: labelOf() });
      return p;
    },
    reload: function () {
      post({ type: 'reload', window: labelOf() });
    },
    _dispatch: function (msg) {
      if (!msg) return;
      if (msg.type === 'resolve') {
        var p = pending[msg.id];
        if (!p) return;
        delete pending[msg.id];
        if (msg.ok) p.resolve(msg.data); else p.reject(new Error(msg.error || 'invoke failed'));
      } else if (msg.type === 'event') {
        if (msg.window && msg.window !== labelOf()) return;
        if (msg.coalesce) {
          coalesceSlots[msg.event] = msg.payload;
          scheduleCoalesced();
          return;
        }
        var arr = listeners[msg.event] || [];
        for (var i = 0; i < arr.length; i++) arr[i](msg.payload);
      }
    }
  };
})();"#

/**
 * 窗口 label 注入片段（等价于桌面 C 侧的 document-start 注入）
 *
 * 单引号包住 JSON 字符串：label 由应用给定，实际取值来自 `WindowConfig.label` / 默认 label，
 * 里层用 JSON 转义保证引号与反斜杠安全（不做手工拼接转义）。
 */
@When[env == "ohos"]
public func arkWebLabelScript(label: String): String {
    return "window.__CJ_TAURI_LABEL__ = ${jsonQuote(label)};"
}

/**
 * 把一段「已经是 JSON」的报文推给页面（不经 JSON 二次解析）
 *
 * 桌面两平台由 C 桥拼 `_dispatch(报文)` 并 ExecuteScript；这里产出同形状的脚本字符串，
 * 由 UI 线程的组件交给 `controller.runJavaScript`。报文本身来自 `IpcHub` 的序列化结果，
 * 所以这里**只包一层括号**、不做转义（做了会变成字符串字面量，页面收到的是文本而非对象）。
 */
@When[env == "ohos"]
func arkWebDispatchScript(payloadJson: String): String {
    return "window.__CJ_TAURI__ && window.__CJ_TAURI__._dispatch(${payloadJson});"
}

/**
 * 包成 JS 双引号字符串字面量
 *
 * 只转义两样：反斜杠与双引号——label 是应用给定的短标识（默认 `main`），不承载换行等控制字符；
 * 但引号必须转义，否则 `arkWebLabelScript` 生成的脚本当场语法错误，页面里 label 永远是默认值
 * （这种错不报错、只让事件过滤失灵，属于最难查的一类）。
 */
@When[env == "ohos"]
private func jsonQuote(text: String): String {
    var out = ArrayList<UInt8>()
    for (b in text.toArray()) {
        if (b == 0x5Cu8 || b == 0x22u8) {
            out.add(0x5Cu8)
        }
        out.add(b)
    }
    return "\"${String.fromUtf8(out.toArray())}\""
}
