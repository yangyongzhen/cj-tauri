/* ===========================================================================
   cj-tauri 官网交互脚本 —— 纯原生、无依赖、无网络请求
   1) 中英切换：以 HTML 里的中文为默认内容，英文放在 data-en* 属性上
   2) 滚动进场：IntersectionObserver
   3) 代码标签页、移动端菜单、导航滚动状态
   4) 示例大轮播：轨道是原生 scroll-snap，箭头 / 圆点 / 序号 / 自动播放由脚本补
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
    current = lang;
    apply(lang);
    try { window.localStorage.setItem(STORE_KEY, lang); } catch (e) { /* 隐私模式忽略 */ }
  }

  var current = initialLang();
  collect();
  apply(current);

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

  /* ---------- 5. 示例轮播（渐进增强） --------------------------------------- */
  // 轨道本身是原生 scroll-snap：这段脚本不跑，页面照样能拖能滚（提示行还留在原地）。
  // 它只补四样——悬浮箭头、圆点、序号、自动播放；自动播放跟随系统「减少动态效果」，
  // 悬停 / 聚焦时暂停（有人正看着，别把内容从眼皮底下挪走）。
  function carouselLabel(el, zhText, enText) {
    // JS 后建的节点也要跟着切语言：collect() 已经跑过，所以自己补一份 data-zh-aria
    // 再登记进语言切换表——否则英文态下屏幕阅读器念出来的还是中文。
    el.setAttribute('aria-label', zhText);
    el.setAttribute('data-zh-aria', zhText);
    el.setAttribute('data-en-aria', enText);
    nodes.push(el);
  }

  function initCarousel(root) {
    var viewport = root.querySelector('.carousel__viewport');
    var track = root.querySelector('.carousel__track');
    var stage = root.querySelector('.carousel__stage') || root;
    var foot = root.querySelector('.carousel__foot') || root;
    var hint = root.querySelector('.carousel__hint');
    if (!viewport || !track) { return; }

    var slides = Array.prototype.slice.call(track.children);
    if (slides.length < 2) { return; }

    var SWITCH_MS = 6500;
    var dotButtons = [];
    var timer = null;
    var at = 0;

    var counter = document.createElement('p');
    counter.className = 'carousel__count';
    counter.setAttribute('aria-live', 'polite');

    var dots = document.createElement('div');
    dots.className = 'carousel__dots';

    function offsetOf(slide) { return slide.offsetLeft - track.offsetLeft; }

    function setActive(idx) {
      at = idx;
      for (var i = 0; i < dotButtons.length; i++) {
        dotButtons[i].setAttribute('aria-current', i === idx ? 'true' : 'false');
      }
      counter.textContent = (idx + 1) + ' / ' + slides.length;
    }

    function goTo(idx, smooth) {
      var to = ((idx % slides.length) + slides.length) % slides.length;
      var left = offsetOf(slides[to]);
      // jsdom 与老浏览器没有 Element.scrollTo：退回直接赋 scrollLeft（结果一样，只是不平滑）
      if (typeof viewport.scrollTo === 'function') {
        try {
          viewport.scrollTo({ left: left, behavior: smooth ? 'smooth' : 'auto' });
        } catch (e) {
          viewport.scrollLeft = left;   // 只认坐标两参形式的实现会走到这里
        }
      } else {
        viewport.scrollLeft = left;
      }
      setActive(to);
    }

    function stop() { if (timer) { window.clearInterval(timer); timer = null; } }
    var reduce = !!(window.matchMedia && window.matchMedia('(prefers-reduced-motion: reduce)').matches);
    function restart() {
      stop();
      if (reduce || document.hidden) { return; }
      timer = window.setInterval(function () { goTo(at + 1, true); }, SWITCH_MS);
    }

    function step(delta) { goTo(at + delta, true); restart(); }

    function mkNav(mod, glyph, zhLabel, enLabel) {
      var b = document.createElement('button');
      b.type = 'button';
      b.className = 'carousel__nav carousel__nav--' + mod;
      b.textContent = glyph;
      carouselLabel(b, zhLabel, enLabel);
      b.addEventListener('click', function () { step(mod === 'prev' ? -1 : 1); });
      stage.appendChild(b);
    }

    for (var s = 0; s < slides.length; s++) {
      (function (idx) {
        var b = document.createElement('button');
        b.type = 'button';
        b.className = 'carousel__dot';
        b.addEventListener('click', function () { goTo(idx, true); restart(); });
        // 圆点的名字用序号，不抄各页标题：标题会随语言切换而变，序号不会说谎
        carouselLabel(b, '第 ' + (idx + 1) + ' 个示例', 'Example ' + (idx + 1));
        dots.appendChild(b);
        dotButtons.push(b);
      })(s);
    }
    mkNav('prev', '\u2039', '上一个示例', 'Previous example');
    mkNav('next', '\u203a', '下一个示例', 'Next example');
    foot.appendChild(dots);
    foot.appendChild(counter);
    root.classList.add('is-ready');
    if (hint) { hint.setAttribute('hidden', ''); }

    // 拖 / 滚轮 / 触控之后圆点与序号要跟上；rAF 合并高频 scroll 事件
    var pending = false;
    function syncFromScroll() {
      var best = 0;
      var bestDist = Infinity;
      for (var i = 0; i < slides.length; i++) {
        var d = Math.abs(offsetOf(slides[i]) - viewport.scrollLeft);
        if (d < bestDist) { bestDist = d; best = i; }
      }
      setActive(best);
    }
    viewport.addEventListener('scroll', function () {
      if (pending) { return; }
      pending = true;
      if (window.requestAnimationFrame) {
        window.requestAnimationFrame(function () { pending = false; syncFromScroll(); });
      } else {
        pending = false;
        syncFromScroll();
      }
    }, { passive: true });

    // 键盘：视口可聚焦，方向键 / Home / End 都能翻（没开鼠标也能读完这一条）
    viewport.addEventListener('keydown', function (ev) {
      if (ev.key === 'ArrowRight') { step(1); }
      else if (ev.key === 'ArrowLeft') { step(-1); }
      else if (ev.key === 'Home') { goTo(0, true); restart(); }
      else if (ev.key === 'End') { goTo(slides.length - 1, true); restart(); }
      else { return; }
      ev.preventDefault();
    });

    if (!reduce) {
      restart();
      root.addEventListener('mouseenter', stop);
      root.addEventListener('mouseleave', restart);
      root.addEventListener('focusin', stop);
      root.addEventListener('focusout', restart);
      document.addEventListener('visibilitychange', function () {
        if (document.hidden) { stop(); } else { restart(); }
      });
    }

    goTo(0, false);
  }

  var carouselRoot = document.querySelector('.carousel');
  if (carouselRoot) { initCarousel(carouselRoot); }
  apply(current);   // 控件是后建的：上面登记过中英两份，这里补一次语言

  /* ---------- 6. 兜底 ------------------------------------------------------ */
  // 万一有节点在 JS 之后才出现（或上面任何一步抛错），保证内容不会停在 opacity:0。
  window.addEventListener('load', function () {
    var left = document.querySelectorAll('.reveal:not(.is-in)');
    for (var i = 0; i < left.length; i++) {
      var box = left[i].getBoundingClientRect();
      if (box.top < window.innerHeight) { left[i].classList.add('is-in'); }
    }
  });
})();
