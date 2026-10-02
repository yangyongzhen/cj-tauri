/*
 * 前端桥接脚本（单份）：暴露 window.__CJ_TAURI__，对标 @tauri-apps/api。
 *
 * 为什么单份：Linux 与 Windows 两座桥原本各存一份同内容的 JS，任何修补都要改两处，
 * 极易漂移（"与 Windows 对齐"曾是反复出现的叮嘱）。这里抽成一份宏，纳入本文件即可。
 *
 * 用法（两平台唯一差异只有两条语句：post 通道 + reload 控制消息）：
 *   1) 先定义 CJ_LIT(x) —— 窄/宽字符串前缀：
 *        Linux   (bridge_linux.c)：#define CJ_LIT(s) s
 *        Windows (bridge_win.c)  ：#define CJ_LIT(s) L##s   （AddScriptToExecuteOnDocumentCreated 要 wchar_t）
 *   2) 提供两条自带缩进与分号的平台语句字面量；
 *   3) 展开 CJ_BRIDGE_JS(POST_STMT, RELOAD_STMT)。
 *
 * 注意：JS 源码里的块注释（斜杠星号）与单引号字符串都是**字符串内容**，不是 C 注释/字符——
 * 改本文件时别把它们挪出引号（仓颉侧内联 HTML 已踩过同类坑，见 AGENTS.md §4）。
 */
#ifndef CJ_LIT
#error "bridge_js.h: 请先定义 CJ_LIT(x)（Linux 原样 / Windows L##x）再 include"
#endif

#define CJ_BRIDGE_JS(POST_STMT, RELOAD_STMT) \
    CJ_LIT("window.__CJ_TAURI__ = (function () {") \
    CJ_LIT("  var seq = 0;") \
    CJ_LIT("  var pending = {};") \
    CJ_LIT("  var listeners = {};") \
    CJ_LIT("  var coalesceSlots = Object.create(null);  /* 本帧待投的事件：event -> 最新 payload */") \
    CJ_LIT("  var coalesceTimer = null;") \
    CJ_LIT("  var coalesceRaf = 0;") \
    CJ_LIT("  /* tick = 一帧：同一帧内同名事件只投最后一次 payload（中间值丢弃） */") \
    CJ_LIT("  function flushCoalesced() {") \
    CJ_LIT("    if (coalesceTimer !== null) { clearTimeout(coalesceTimer); coalesceTimer = null; }") \
    CJ_LIT("    if (coalesceRaf && typeof cancelAnimationFrame === 'function') cancelAnimationFrame(coalesceRaf);") \
    CJ_LIT("    coalesceRaf = 0;") \
    CJ_LIT("    var due = coalesceSlots;") \
    CJ_LIT("    coalesceSlots = Object.create(null);") \
    CJ_LIT("    for (var name in due) {") \
    CJ_LIT("      var arr = listeners[name] || [];") \
    CJ_LIT("      for (var i = 0; i < arr.length; i++) arr[i](due[name]);") \
    CJ_LIT("    }") \
    CJ_LIT("  }") \
    CJ_LIT("  function scheduleCoalesced() {") \
    CJ_LIT("    if (coalesceTimer !== null || coalesceRaf) return;") \
    CJ_LIT("    /* rAF 是帧边界；窗口不可见时它不来，用定时器兜底，保证尾值一定送达 */") \
    CJ_LIT("    if (typeof requestAnimationFrame === 'function') coalesceRaf = requestAnimationFrame(flushCoalesced);") \
    CJ_LIT("    coalesceTimer = setTimeout(flushCoalesced, 50);") \
    CJ_LIT("  }") \
    CJ_LIT("  /* 本页面所属窗口的 label：宿主在 document-start 注入 window.__CJ_TAURI_LABEL__ */") \
    CJ_LIT("  /* 懒读 + 缓存（首次用到才取值）：注入脚本与桥 JS 谁先执行都可能，默认 'main' 与老前端对齐 */") \
    CJ_LIT("  var cachedLabel = null;") \
    CJ_LIT("  function labelOf() {") \
    CJ_LIT("    if (cachedLabel === null) {") \
    CJ_LIT("      var v = (typeof window !== 'undefined') ? window.__CJ_TAURI_LABEL__ : null;") \
    CJ_LIT("      cachedLabel = (typeof v === 'string' && v.length > 0) ? v : 'main';") \
    CJ_LIT("    }") \
    CJ_LIT("    return cachedLabel;") \
    CJ_LIT("  }") \
    CJ_LIT("  function post(obj) {") \
    POST_STMT \
    CJ_LIT("  }") \
    CJ_LIT("  return {") \
    CJ_LIT("    invoke: function (cmd, args) {") \
    CJ_LIT("      var id = ++seq;") \
    CJ_LIT("      var p = new Promise(function (resolve, reject) { pending[id] = { resolve: resolve, reject: reject }; });") \
    CJ_LIT("      post({ type: 'invoke', id: id, cmd: cmd, args: args || {}, window: labelOf() });") \
    CJ_LIT("      return p;") \
    CJ_LIT("    },") \
    CJ_LIT("    listen: function (event, cb) {") \
    CJ_LIT("      if (!listeners[event]) listeners[event] = [];") \
    CJ_LIT("      listeners[event].push(cb);") \
    CJ_LIT("      return function () {") \
    CJ_LIT("        var arr = listeners[event] || [];") \
    CJ_LIT("        var i = arr.indexOf(cb);") \
    CJ_LIT("        if (i >= 0) arr.splice(i, 1);") \
    CJ_LIT("      };") \
    CJ_LIT("    },") \
    CJ_LIT("    emit: function (event, payload) {") \
    CJ_LIT("      /* 带 id 才有回执：后端能把「事件未授权 / 报文非法」reject 回来（对齐 Tauri 的 emit 返回 Promise） */") \
    CJ_LIT("      var id = ++seq;") \
    CJ_LIT("      var p = new Promise(function (resolve, reject) { pending[id] = { resolve: resolve, reject: reject }; });") \
    CJ_LIT("      post({ type: 'emit', id: id, event: event, payload: payload === undefined ? {} : payload, window: labelOf() });") \
    CJ_LIT("      return p;") \
    CJ_LIT("    },") \
    CJ_LIT("    reload: function () {") \
    CJ_LIT("      /* 与 CJT_RELOAD_MSG 保持一致：宿主拦截后不会进 IPC hub */") \
    RELOAD_STMT \
    CJ_LIT("    },") \
    CJ_LIT("    _dispatch: function (msg) {") \
    CJ_LIT("      if (!msg) return;") \
    CJ_LIT("      if (msg.type === 'resolve') {") \
    CJ_LIT("        var p = pending[msg.id];") \
    CJ_LIT("        if (!p) return;") \
    CJ_LIT("        delete pending[msg.id];") \
    CJ_LIT("        if (msg.ok) p.resolve(msg.data); else p.reject(new Error(msg.error || 'invoke failed'));") \
    CJ_LIT("      } else if (msg.type === 'event') {") \
    CJ_LIT("        /* window 缺省 = 广播，放行；定向推送只投给 label 匹配的页面 */") \
    CJ_LIT("        if (msg.window && msg.window !== labelOf()) return;") \
    CJ_LIT("        if (msg.coalesce) {") \
    CJ_LIT("          /* emitLatest：只记最新值，一帧后统一投（同一帧内同名事件合成一条） */") \
    CJ_LIT("          coalesceSlots[msg.event] = msg.payload;") \
    CJ_LIT("          scheduleCoalesced();") \
    CJ_LIT("          return;") \
    CJ_LIT("        }") \
    CJ_LIT("        var arr = listeners[msg.event] || [];") \
    CJ_LIT("        for (var i = 0; i < arr.length; i++) arr[i](msg.payload);") \
    CJ_LIT("      }") \
    CJ_LIT("    }") \
    CJ_LIT("  };") \
    CJ_LIT("})();")
