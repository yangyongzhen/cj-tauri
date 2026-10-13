/* ===========================================================================
   cj-tauri 官网交互脚本 —— 纯原生、无依赖、无网络请求
   1) 中英切换：以 HTML 里的中文为默认内容，英文放在 data-en* 属性上
   2) 滚动进场：IntersectionObserver
   3) 代码标签页、移动端菜单、导航滚动状态
   设计取舍：语言切换不走 fetch / 不拆两份 HTML —— 页面在断网、file:// 直开、
   甚至 JS 关掉时都必须是完整的（见文件末尾的兜底）。
   =========================================================================== */
(function () {
  'use strict';

  var STORE_KEY = 'cj-tauri-lang';

  /* ---------- 1. 语言切换 -------------------------------------------------- */
  // 采集原文：中文（页面初始内容）留在 data-zh 上，英文来自 data-en* 属性。
  // 用 innerHTML 记中文，是因为部分节点里带 <code>/<strong>；英文一律按纯文本写入。
  var nodes = [];

  function collect() {
    var sel = '[data-en],[data-en-html]';
    var list = document.querySelectorAll(sel);
    for (var i = 0; i < list.length; i++) {
      var el = list[i];
      el.setAttribute('data-zh', el.innerHTML);
      nodes.push(el);
    }
    // 图片 alt、链接 title 这类属性单独走一批
    var alts = document.querySelectorAll('[data-en-alt]');
    for (var j = 0; j < alts.length; j++) {
      alts[j].setAttribute('data-zh-alt', alts[j].getAttribute('alt') || '');
      nodes.push(alts[j]);
    }
    var titles = document.querySelectorAll('[data-en-title]');
    for (var k = 0; k < titles.length; k++) {
      titles[k].setAttribute('data-zh-title', titles[k].getAttribute('title') || '');
      nodes.push(titles[k]);
    }
    // aria-label：读屏用户也要跟着语言走，否则界面是英文、读出来还是中文
    var arias = document.querySelectorAll('[data-en-aria]');
    for (var m = 0; m < arias.length; m++) {
      arias[m].setAttribute('data-zh-aria', arias[m].getAttribute('aria-label') || '');
      nodes.push(arias[m]);
    }
    var root = document.querySelector('title[data-en]');
    if (root) { nodes.push(root); }
  }

  function apply(lang) {
    var en = lang === 'en';

    for (var i = 0; i < nodes.length; i++) {
      var el = nodes[i];
      if (el.tagName === 'IMG') {
        el.setAttribute('alt', en ? (el.getAttribute('data-en-alt') || '') : (el.getAttribute('data-zh-alt') || ''));
        continue;
      }
      if (el.hasAttribute('data-en-aria')) {
        el.setAttribute('aria-label', en ? el.getAttribute('data-en-aria') : (el.getAttribute('data-zh-aria') || ''));
      }
      if (el.hasAttribute('data-en-title')) {
        if (en) { el.setAttribute('title', el.getAttribute('data-en-title')); }
        else { el.setAttribute('title', el.getAttribute('data-zh-title') || ''); }
      }
      if (el.hasAttribute('data-en-html')) {
        el.innerHTML = en ? el.getAttribute('data-en-html') : (el.getAttribute('data-zh') || '');
        continue;
      }
      if (el.hasAttribute('data-en')) {
        var zh = el.getAttribute('data-zh');
        if (en) { el.textContent = el.getAttribute('data-en'); }
        else if (zh !== null) { el.innerHTML = zh; }
      }
    }

    document.documentElement.setAttribute('lang', en ? 'en' : 'zh-CN');
    var btns = document.querySelectorAll('.lang__btn');
    for (var b = 0; b < btns.length; b++) {
      btns[b].setAttribute('aria-pressed', String(btns[b].getAttribute('data-lang') === (en ? 'en' : 'zh')));
    }
  }

  function initialLang() {
    // ?lang=en / ?lang=zh 可指定语言：分享链接与无头抓图都需要一个确定的状态。
    // 只在「本次访问」生效，不写回 localStorage——别人给的英文链接不该改你的偏好。
    var m = /[?&]lang=(zh|en)(?:&|$|\b)/.exec(window.location.search);
    if (m) { return m[1]; }
    var saved = null;
    try { saved = window.localStorage.getItem(STORE_KEY); } catch (e) { saved = null; }
    if (saved === 'zh' || saved === 'en') { return saved; }
    // 首次访问按浏览器语言猜：非中文环境给英文
    var nav = (navigator.language || 'zh').toLowerCase();
    return nav.indexOf('zh') === 0 ? 'zh' : 'en';
  }

  function setLang(lang) {
    apply(lang);
    try { window.localStorage.setItem(STORE_KEY, lang); } catch (e) { /* 隐私模式忽略 */ }
  }

  collect();
  apply(initialLang());

  var langBtns = document.querySelectorAll('.lang__btn');
  for (var lb = 0; lb < langBtns.length; lb++) {
    langBtns[lb].addEventListener('click', function () {
      setLang(this.getAttribute('data-lang'));
    });
  }

  /* ---------- 2. 滚动进场 -------------------------------------------------- */
  var reveals = document.querySelectorAll('.reveal');
  if ('IntersectionObserver' in window) {
    var io = new IntersectionObserver(function (entries) {
      for (var i = 0; i < entries.length; i++) {
        var e = entries[i];
        if (!e.isIntersecting) { continue; }
        // 同一批子项按序错开一点，整块一起滑进来会显得很呆
        var sibs = e.target.parentNode ? e.target.parentNode.children : [];
        var idx = 0;
        for (var s = 0; s < sibs.length; s++) { if (sibs[s] === e.target) { idx = s; } }
        e.target.style.transitionDelay = Math.min(idx, 6) * 45 + 'ms';
        e.target.classList.add('is-in');
        io.unobserve(e.target);
      }
    }, { rootMargin: '0px 0px -8% 0px', threshold: 0.06 });
    for (var r = 0; r < reveals.length; r++) { io.observe(reveals[r]); }
  } else {
    for (var r2 = 0; r2 < reveals.length; r2++) { reveals[r2].classList.add('is-in'); }
  }

  /* ---------- 3. 导航状态与移动端菜单 -------------------------------------- */
  var nav = document.querySelector('.nav');
  function onScroll() {
    if (!nav) { return; }
    if (window.scrollY > 8) { nav.classList.add('is-scrolled'); }
    else { nav.classList.remove('is-scrolled'); }
  }
  window.addEventListener('scroll', onScroll, { passive: true });
  onScroll();

  var burger = document.getElementById('burger');
  var links = document.getElementById('navLinks');
  if (burger && links) {
    burger.addEventListener('click', function () {
      var open = links.classList.toggle('is-open');
      burger.setAttribute('aria-expanded', String(open));
    });
    links.addEventListener('click', function (ev) {
      // 点了跳转就收起菜单，免得盖住刚滚到的内容
      if (ev.target && ev.target.classList.contains('nav__link')) {
        links.classList.remove('is-open');
        burger.setAttribute('aria-expanded', 'false');
      }
    });
  }

  /* ---------- 4. 代码标签页 ------------------------------------------------ */
  var tabs = document.querySelectorAll('.tab[data-tab]');
  function selectTab(tab) {
    for (var i = 0; i < tabs.length; i++) {
      var on = tabs[i] === tab;
      tabs[i].setAttribute('aria-selected', String(on));
      var panel = document.getElementById(tabs[i].getAttribute('data-tab'));
      if (panel) {
        if (on) { panel.removeAttribute('hidden'); }
        else { panel.setAttribute('hidden', ''); }
      }
    }
  }
  for (var t = 0; t < tabs.length; t++) {
    tabs[t].addEventListener('click', function () { selectTab(this); });
    // 键盘左右键在标签间移动（role=tablist 的基本礼貌）
    tabs[t].addEventListener('keydown', function (ev) {
      if (ev.key !== 'ArrowRight' && ev.key !== 'ArrowLeft') { return; }
      var arr = Array.prototype.slice.call(tabs);
      var at = arr.indexOf(this);
      var next = arr[(at + (ev.key === 'ArrowRight' ? 1 : arr.length - 1)) % arr.length];
      if (next) { next.focus(); selectTab(next); }
      ev.preventDefault();
    });
  }

  /* ---------- 5. 兜底 ------------------------------------------------------ */
  // 万一有节点在 JS 之后才出现（或上面任何一步抛错），保证内容不会停在 opacity:0。
  window.addEventListener('load', function () {
    var left = document.querySelectorAll('.reveal:not(.is-in)');
    for (var i = 0; i < left.length; i++) {
      var box = left[i].getBoundingClientRect();
      if (box.top < window.innerHeight) { left[i].classList.add('is-in'); }
    }
  });
})();
