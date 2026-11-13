<script setup>
/* Ionic Vue 观影应用（移动端形态）
 * 首页信息架构：轮播图（热映前 5）→ 每个榜单栏目一条横滑卡片行（点「查看更多」进分页列表页）。
 * 后端与 examples/movie 共用同一套命令（源码拷贝，仅改包名 ionic_movie_app）：
 *   movie:list {kind: hot|new|soon|top|week|us, start, count, city?}
 *   movie:search {q} · movie:detail {id}
 *   movie:source {sid} · movie:sourceitem {sid, note, aid?} · movie:image {url}
 * 前端只经 window.__CJ_TAURI__ 的 invoke 说话——这是框架契约，页面不自己 fetch。 */
import { ref, computed, onMounted, onBeforeUnmount, watch, nextTick } from 'vue';
import {
  IonApp, IonContent, IonHeader, IonToolbar, IonTitle, IonTabBar, IonTabButton,
  IonIcon, IonSearchbar, IonButton, IonButtons, IonSpinner, IonChip, IonLabel,
  IonList, IonItem, IonRefresher, IonRefresherContent,
  IonInfiniteScroll, IonInfiniteScrollContent, toastController
} from '@ionic/vue';
import { searchOutline, filmOutline, settingsOutline, playCircleOutline, closeOutline,
         informationCircleOutline, arrowBackOutline, warningOutline, personCircleOutline,
         chevronForwardOutline } from 'ionicons/icons';
import Hls from 'hls.js';

const $invoke = (...a) => window.__CJ_TAURI__.invoke(...a);

/* ---------------- 榜单分类 ---------------- */
const KINDS = [
  { key: 'hot',  label: '正在热映' },
  { key: 'new',  label: '新片榜' },
  { key: 'soon', label: '即将上映' },
  { key: 'top',  label: 'Top250' },
  { key: 'week', label: '口碑周榜' },
  { key: 'us',   label: '北美票房' }
];
const netError = ref('');
const covers = ref({});            // key -> dataURL（封面全走宿主 movie:image，防盗链）
const appVersion = ref('…');

/* 首页横滑行的数据：每个栏目独立一份（首屏各取 12 条，并行预取） */
const sections = ref({});          // {kind: {label, list, loading}}
const homeLoading = ref(false);

async function notify(msg) {
  const t = await toastController.create({ message: msg, duration: 2000, position: 'top' });
  await t.present();
}

/* 列表项归一化：后台字段名以实机为准，这里做空值兜底 */
function unwrapMovies(resp) {
  if (resp.code !== undefined && resp.code !== 0) { throw new Error(resp.message || '后台返回失败'); }
  const arr = Array.isArray(resp.data) ? resp.data : [];
  return arr.map(m => ({
    id: String(m.id ?? m.movieId ?? ''),
    title: m.title || m.name || '未知影片',
    cover: m.cover || m.pic || '',
    rating: m.rating ?? m.score ?? '',
    year: m.year || '',
    pubdate: m.pubdate || ''
  })).filter(m => m.id);
}

/* 单栏目首页行：取 12 条（豆瓣限流友好，分页留给「查看更多」页） */
async function fetchKind(k, count) {
  const body = { kind: k, start: 0, count };
  if (k === 'hot') { body.city = '北京'; }
  const resp = await $invoke('movie:list', body);
  return unwrapMovies(resp);
}

async function loadHomeSections(refresher) {
  homeLoading.value = true; netError.value = '';
  try {
    const results = await Promise.all(KINDS.map(async ({ key, label }) => {
      try {
        return { key, label, list: await fetchKind(key, 12) };
      } catch (e) {
        return { key, label, list: [], error: String(e && e.message ? e.message : e) };
      }
    }));
    const next = {};
    let firstErr = '';
    for (const r of results) {
      next[r.key] = { label: r.label, list: r.list, loading: false };
      if (!firstErr && r.error) firstErr = r.error;
    }
    sections.value = next;
    if (firstErr && !homeRows.value.length) netError.value = firstErr;
    else netError.value = '';
    /* 轮播与各行的封面预取 */
    preloadCovers(carouselMovies.value, 500, 5);
    for (const r of results) preloadCovers(r.list, 200, 8);
  } finally {
    homeLoading.value = false;
    if (refresher) refresher.target.complete();
  }
}

const homeRows = computed(() => KINDS.map(({ key }) => ({ key, ...sections.value[key] })).filter(r => r.list));

/* 轮播图：热映（或第一个有数据的栏目）前 5 部 */
const carouselMovies = computed(() => {
  const first = homeRows.value[0];
  return first ? first.list.slice(0, 5) : [];
});

/* ---------------- 查看更多：栏目分页列表页 ---------------- */
const category = ref(null);        // {kind, label, list, start, done, loading}
const PAGE_SIZE = 20;

function openCategory(kind) {
  const cached = sections.value[kind]?.list || [];
  category.value = { kind, list: [...cached], start: cached.length, done: false, loading: false };
}
/* 分页：start 每页 PAGE_SIZE；返回不足一页即判尽（后端 count 上限 60 在命令层夹着） */
async function loadMoreCategory(ev) {
  const c = category.value;
  if (!c || c.done || c.loading) { if (ev) ev.target.complete(); return; }
  c.loading = true;
  try {
    const body = { kind: c.kind, start: c.start, count: PAGE_SIZE };
    if (c.kind === 'hot') { body.city = '北京'; }
    const resp = await $invoke('movie:list', body);
    const page = unwrapMovies(resp);
    const ids = new Set(c.list.map(m => m.id));
    c.list.push(...page.filter(m => !ids.has(m.id)));
    c.start += PAGE_SIZE;
    c.done = page.length < PAGE_SIZE;
    preloadCovers(page, 200, 8);
  } catch (e) {
    c.done = true;
    await notify(String(e && e.message ? e.message : e));
  } finally {
    c.loading = false;
    if (ev) ev.target.complete();
  }
}

/* ---------------- 搜索 ---------------- */
const searchQ = ref('');
const results = ref([]);
const searching = ref(false);
const tab = ref('home');
async function doSearch() {
  const q = (searchQ.value || '').trim();
  if (!q) { await notify('先输入片名'); return; }
  searching.value = true; netError.value = '';
  try {
    /* 后台的 title 字段是 GBK 乱码（已知后台缺陷），页面不显示它 */
    const resp = await $invoke('movie:search', { q, start: 0, count: 30 });
    results.value = unwrapMovies(resp);
    if (!results.value.length) await notify('没搜到，换个片名试试');
  } catch (e) {
    netError.value = String(e && e.message ? e.message : e);
    results.value = [];
  } finally { searching.value = false; }
}

/* ---------------- 详情与播放 ---------------- */
const detail = ref(null);          // {base, summary, genres, sources, tvurls, sourceNote}
const detailLoading = ref(false);
const playUrl = ref('');
const playLoading = ref(false);
const videoEl = ref(null);
let hls = null;

async function openDetail(m) {
  detail.value = { base: m, summary: '', genres: '', sources: [], tvurls: [], sourceNote: '' };
  playUrl.value = '';
  detailLoading.value = true;
  loadCover(m, 500);
  try {
    const [d, src] = await Promise.all([
      $invoke('movie:detail', { id: m.id }).catch(() => null),
      $invoke('movie:source', { sid: m.id }).catch(() => null)
    ]);
    if (d && d.code === 0 && d.data) {
      const dd = d.data;
      detail.value.summary = dd.summary || '';
      detail.value.genres = Array.isArray(dd.genres) ? dd.genres.join(' / ') : (dd.genres || '');
    }
    if (src && src.code === 0 && src.data) {
      const sd = src.data;
      detail.value.tvurls = Array.isArray(sd.tvurls) ? sd.tvurls : [];
      detail.value.sources = Array.isArray(sd.sources) ? sd.sources : [];
      detail.value.sourceNote = sd.note || '';
    }
    if (detail.value.tvurls.length) {
      startPlay(detail.value.tvurls[0].url || detail.value.tvurls[0]);
    } else if (detail.value.sources.length) {
      pickSource(detail.value.sources[0]);
    }
  } catch (e) {
    notify(String(e && e.message ? e.message : e));
  } finally { detailLoading.value = false; }
}

/* 切源：movie:sourceitem {sid, note, aid?} → tvurls → 从头播 */
async function pickSource(s) {
  if (!detail.value) return;
  playLoading.value = true;
  try {
    const note = s.note || s.name || '';
    const aid = s.items && s.items.length ? (s.items[0].aid || '') : (s.aid || '');
    const resp = await $invoke('movie:sourceitem', { sid: detail.value.base.id, note, aid });
    const urls = resp && resp.data && Array.isArray(resp.data.tvurls) ? resp.data.tvurls : [];
    if (!urls.length) { await notify('这个源没有取到播放地址'); return; }
    detail.value.tvurls = urls;
    detail.value.sourceNote = note;
    startPlay(urls[0].url || urls[0]);
  } catch (e) {
    await notify(String(e && e.message ? e.message : e));
  } finally { playLoading.value = false; }
}

/* m3u8 走 hls.js（WebKitGTK 的 <video> 不原生支持 HLS），直链 mp4 直接 src */
async function startPlay(url) {
  if (!url) { await notify('播放地址为空'); return; }
  playUrl.value = url;
  await nextTick();
  const v = videoEl.value;
  if (!v) return;
  if (hls) { hls.destroy(); hls = null; }
  if (url.includes('.m3u8') && Hls.isSupported()) {
    hls = new Hls();
    hls.loadSource(url);
    hls.attachMedia(v);
    hls.on(Hls.Events.MANIFEST_PARSED, () => { v.play().catch(() => {}); });
    hls.on(Hls.Events.ERROR, (_e, data) => {
      if (data.fatal) notify('视频流加载失败（' + data.type + '），换个源试试');
    });
  } else {
    v.src = url;
    v.play().catch(() => {});
  }
}
onBeforeUnmount(() => { if (hls) { hls.destroy(); hls = null; } });

/* ---------------- 封面与杂项 ---------------- */
async function loadCover(m, size) {
  if (!m.cover) return;
  const key = `${m.key || m.sid || m.id}@${size}`;
  if (covers.value[key]) return;
  try {
    const dataUrl = await $invoke('movie:image', { url: m.cover, size });
    covers.value = { ...covers.value, [key]: dataUrl };
  } catch (e) { /* 取不到显示占位 */ }
}
function coverOf(m, size) { return covers.value[`${m.key || m.sid || m.id}@${size}`]; }
function preloadCovers(list, size, n) { list.slice(0, n).forEach(m => loadCover(m, size)); }

async function loadVersion() {
  try {
    const v = await $invoke('system:version', {});
    appVersion.value = typeof v === 'string' ? v : (v.version || '');
  } catch (e) { appVersion.value = ''; }
}

/* 轮播自动翻页（纯 CSS scroll-snap + 定时器，不引 swiper） */
const carousel = ref(null);
const carouselIdx = ref(0);
let carouselTimer = null;
function startCarousel() {
  stopCarousel();
  carouselTimer = setInterval(() => {
    const el = carousel.value;
    if (!el || !carouselMovies.value.length || detail.value || category.value) return;
    const n = carouselMovies.value.length;
    carouselIdx.value = (carouselIdx.value + 1) % n;
    el.scrollTo({ left: el.clientWidth * carouselIdx.value, behavior: 'smooth' });
  }, 3500);
}
function stopCarousel() { if (carouselTimer) { clearInterval(carouselTimer); carouselTimer = null; } }
function onCarouselScroll() {
  const el = carousel.value;
  if (el) carouselIdx.value = Math.round(el.scrollLeft / el.clientWidth);
}

watch(tab, (t) => {
  if (t === 'home' && !Object.keys(sections.value).length) loadHomeSections(null);
});

onMounted(async () => {
  await window.__bridgeReady;
  await loadVersion();
  await loadHomeSections(null);
  startCarousel();
});
</script>

<template>
  <ion-app>
    <ion-header class="ion-no-border">
      <ion-toolbar>
        <ion-buttons slot="start" v-if="detail || category">
          <ion-button @click="detail ? (detail = null, playUrl = '') : (category = null)">
            <ion-icon slot="icon-only" :icon="arrowBackOutline" />
          </ion-button>
        </ion-buttons>
        <ion-title class="app-title">
          <ion-icon :icon="filmOutline" class="logo" />
          {{ detail ? detail.base.title : (category ? category.label : '仓颉观影') }}
        </ion-title>
        <ion-buttons slot="end">
          <ion-spinner v-if="homeLoading || detailLoading || playLoading || (category && category.loading)" name="crescent" />
        </ion-buttons>
      </ion-toolbar>
      <ion-toolbar v-if="!detail && !category && tab === 'search'">
        <ion-searchbar v-model="searchQ" placeholder="片名" @keyup.enter="doSearch"
                       @ionClear="results = []" show-clear-button="focus" />
        <ion-buttons slot="end"><ion-button @click="doSearch" class="go">搜索</ion-button></ion-buttons>
      </ion-toolbar>
    </ion-header>

    <ion-content :fullscreen="true">
      <ion-refresher slot="fixed"
                     @ionRefresh="detail || category ? $event.target.complete() : loadHomeSections($event)">
        <ion-refresher-content />
      </ion-refresher>

      <div v-if="netError && !detail && !category" class="err-note">
        <ion-icon :icon="informationCircleOutline" />
        <span>{{ netError }}</span>
        <span class="sub">后台接口可达性见桥日志 [movie] 行；用 CJ_MOVIE_API 可指向自建后端</span>
      </div>

      <!-- ================= 栏目分页列表页（查看更多） ================= -->
      <template v-if="category">
        <div v-for="m in category.list" :key="m.id" class="row-item" @click="openDetail(m)">
          <div class="row-cover">
            <img v-if="coverOf(m, 200)" :src="coverOf(m, 200)" :alt="m.title" />
            <ion-icon v-else :icon="filmOutline" />
          </div>
          <div class="row-meta">
            <div class="row-title">{{ m.title }}</div>
            <div class="row-sub">
              <span v-if="m.rating" class="rate-text">{{ m.rating }} 分</span>
              <span>{{ m.year || m.pubdate || '&nbsp;' }}</span>
            </div>
          </div>
          <ion-icon :icon="chevronForwardOutline" class="row-arrow" />
        </div>
        <!-- 分页：滚到底自动加载下一页，返回不足一页即尽 -->
        <ion-infinite-scroll v-if="!category.done" @ionInfinite="loadMoreCategory" threshold="120px">
          <ion-infinite-scroll-content loading-spinner="crescent" loading-text="加载更多…" />
        </ion-infinite-scroll>
        <div v-else-if="category.list.length" class="list-end">— 到底了，共 {{ category.list.length }} 部 —</div>
      </template>

      <!-- ================= 首页：轮播 + 每栏目横滑行 ================= -->
      <template v-if="!category && !detail && tab === 'home'">
        <!-- 轮播图：置顶大图（热映前 5） -->
        <div v-if="carouselMovies.length" class="carousel" ref="carousel" @scroll.passive="onCarouselScroll">
          <div v-for="(m, i) in carouselMovies" :key="i" class="car-card" @click="openDetail(m)">
            <img :src="coverOf(m, 500) || coverOf(m, 200) || ''" alt="" />
            <div class="car-cap">
              <div class="t">{{ m.title }}</div>
              <div class="u">{{ [m.rating ? m.rating + ' 分' : '', m.year || m.pubdate].filter(Boolean).join(' · ') }}</div>
            </div>
            <div class="dots">
              <i v-for="(d, j) in carouselMovies" :key="j" :class="{ on: j === carouselIdx }" />
            </div>
          </div>
        </div>

        <!-- 每个栏目一条横滑卡片行 + 查看更多 -->
        <div v-for="row in homeRows" :key="row.key" class="sec">
          <div class="sec-head">
            <span class="sec-title">{{ row.label }}</span>
            <span class="sec-more" @click="openCategory(row.key)">查看更多 <ion-icon :icon="chevronForwardOutline" /></span>
          </div>
          <div class="h-row">
            <div v-for="m in row.list" :key="m.id" class="h-card" @click="openDetail(m)">
              <div class="poster">
                <img v-if="coverOf(m, 200)" :src="coverOf(m, 200)" :alt="m.title" />
                <ion-icon v-else :icon="filmOutline" />
                <span v-if="m.rating" class="rate">{{ m.rating }}</span>
              </div>
              <div class="n">{{ m.title }}</div>
            </div>
          </div>
        </div>
        <div v-if="!homeRows.length && !homeLoading && !netError" class="empty-note">下拉刷新试试</div>
      </template>

      <!-- ================= 搜索 ================= -->
      <template v-if="!category && !detail && tab === 'search'">
        <div v-if="results.length" class="sec-head" style="padding-top: 14px;">
          <span class="sec-title">搜索结果 · {{ results.length }} 部</span>
        </div>
        <div v-for="m in results" :key="m.id" class="row-item" @click="openDetail(m)">
          <div class="row-cover">
            <img v-if="coverOf(m, 200)" :src="coverOf(m, 200)" :alt="m.title" />
            <ion-icon v-else :icon="filmOutline" />
          </div>
          <div class="row-meta">
            <div class="row-title">{{ m.title }}</div>
            <div class="row-sub">
              <span v-if="m.rating" class="rate-text">{{ m.rating }} 分</span>
              <span>{{ m.year || m.pubdate || '&nbsp;' }}</span>
            </div>
          </div>
          <ion-icon :icon="chevronForwardOutline" class="row-arrow" />
        </div>
        <div v-if="!results.length && !searching" class="empty-note">搜一部想看的片子</div>
      </template>

      <!-- ================= 详情页 ================= -->
      <div v-if="detail">
        <div class="player-wrap">
          <video ref="videoEl" controls playsinline :poster="coverOf(detail.base, 500) || ''" />
          <div v-if="!playUrl" class="player-ph">
            <ion-icon :icon="playCircleOutline" />
            <span>{{ playLoading ? '正在取播放地址…' : '选择播放源开始观看' }}</span>
          </div>
        </div>
        <div v-if="detail.sources.length" class="src-row">
          <span class="src-label">播放源</span>
          <ion-chip v-for="(s, i) in detail.sources" :key="i" outline
                    :class="{ sel: detail.sourceNote && (s.note || s.name) === detail.sourceNote }"
                    @click="pickSource(s)">
            <ion-label>{{ s.note || s.name || ('源' + (i + 1)) }}</ion-label>
          </ion-chip>
        </div>
        <div v-else-if="!detail.tvurls.length" class="src-row">
          <span class="src-label"><ion-icon :icon="warningOutline" /> 暂无可用的播放源</span>
        </div>
        <div class="d-title">{{ detail.base.title }}</div>
        <div class="d-meta">
          <span v-if="detail.base.rating">{{ detail.base.rating }} 分</span>
          <span v-if="detail.base.year">{{ detail.base.year }}</span>
          <span v-if="detail.base.pubdate">{{ detail.base.pubdate }}</span>
          <span v-if="detail.genres">{{ detail.genres }}</span>
        </div>
        <div class="d-summary" v-if="detail.summary">{{ detail.summary }}</div>
        <div class="d-summary dim" v-else>简介暂缺（豆瓣源偶发）</div>
      </div>

      <!-- ================= 设置 ================= -->
      <div v-if="!category && !detail && tab === 'settings'">
        <div class="settings-note">通用</div>
        <ion-list inset>
          <ion-item detail="false">
            <ion-icon slot="start" :icon="personCircleOutline" color="primary" />
            <ion-label><h2>框架版本</h2><p>{{ appVersion }}</p></ion-label>
          </ion-item>
          <ion-item detail="false">
            <ion-icon slot="start" :icon="filmOutline" color="tertiary" />
            <ion-label>
              <h2>影视数据</h2>
              <p>榜单与播放源来自在线影视接口（CJ_MOVIE_API 可指向自建后端）</p>
            </ion-label>
          </ion-item>
          <ion-item detail="false">
            <ion-icon slot="start" :icon="warningOutline" color="warning" />
            <ion-label>
              <h2>播放说明</h2>
              <p>m3u8 流经 hls.js 播放；上游源站偶尔抽风，换一个播放源即可</p>
            </ion-label>
          </ion-item>
        </ion-list>
        <div class="settings-note">关于</div>
        <ion-list inset>
          <ion-item detail="false">
            <ion-icon slot="start" :icon="informationCircleOutline" color="medium" />
            <ion-label class="ion-text-wrap">
              <h2>cj-tauri · Ionic 示例</h2>
              <p>仓颉静态编译后端 + 系统 WebView 前端；本页用 @ionic/vue 构建，
                 封面经宿主命令取回（防盗链），命令走能力白名单。</p>
            </ion-label>
          </ion-item>
        </ion-list>
      </div>
    </ion-content>

    <ion-tab-bar class="ion-no-border">
      <ion-tab-button tab="home" :selected="tab === 'home'" @click="detail = null; category = null; tab = 'home'">
        <ion-icon :icon="filmOutline" /><ion-label>首页</ion-label>
      </ion-tab-button>
      <ion-tab-button tab="search" :selected="tab === 'search'" @click="detail = null; category = null; tab = 'search'">
        <ion-icon :icon="searchOutline" /><ion-label>搜索</ion-label>
      </ion-tab-button>
      <ion-tab-button tab="settings" :selected="tab === 'settings'" @click="detail = null; category = null; tab = 'settings'">
        <ion-icon :icon="settingsOutline" /><ion-label>设置</ion-label>
      </ion-tab-button>
    </ion-tab-bar>
  </ion-app>
</template>

<style scoped>
.app-title { font-weight: 700; letter-spacing: .5px; display: flex; align-items: center; gap: 8px; }
.app-title .logo { color: var(--ion-color-primary); font-size: 22px; }
.go { font-weight: 600; }

/* 轮播：置顶大图 */
.carousel { display: flex; overflow-x: auto; scroll-snap-type: x mandatory; padding: 10px 0 2px;
            scrollbar-width: none; }
.carousel::-webkit-scrollbar { display: none; }
.car-card { flex: 0 0 100%; scroll-snap-align: center; position: relative; height: 212px;
            overflow: hidden; }
.car-card img { width: 100%; height: 100%; object-fit: cover; display: block;
                background: linear-gradient(135deg, rgba(93, 135, 255, 0.12), rgba(128, 128, 160, 0.06)); }
.car-cap { position: absolute; left: 0; right: 0; bottom: 0; padding: 28px 16px 18px;
           background: linear-gradient(transparent, rgba(0, 0, 0, 0.82)); }
.car-cap .t { color: #fff; font-weight: 700; font-size: 18px; }
.car-cap .u { color: rgba(255, 255, 255, 0.8); font-size: 12px; margin-top: 3px; }
.dots { position: absolute; bottom: 8px; right: 14px; display: flex; gap: 5px; }
.dots i { width: 6px; height: 6px; border-radius: 3px; background: rgba(255, 255, 255, 0.4);
          transition: all .25s; }
.dots i.on { background: #fff; width: 16px; }

/* 栏目区块：标题行（含查看更多）+ 横滑海报行 */
.sec { margin-top: 10px; }
.sec-head { display: flex; align-items: center; justify-content: space-between;
            padding: 12px 16px 8px; }
.sec-title { font-size: 16px; font-weight: 700; }
.sec-more { font-size: 12px; color: var(--ion-color-medium); display: flex; align-items: center;
            gap: 2px; cursor: pointer; }
.sec-more ion-icon { font-size: 14px; }
.h-row { display: flex; gap: 11px; overflow-x: auto; padding: 2px 16px 4px; scrollbar-width: none; }
.h-row::-webkit-scrollbar { display: none; }
.h-card { flex: 0 0 108px; cursor: pointer; }
.h-card .poster { position: relative; width: 108px; height: 152px; border-radius: 10px;
                  overflow: hidden; background: linear-gradient(160deg, rgba(93, 135, 255, 0.10),
                  rgba(128, 128, 160, 0.10)); display: flex; align-items: center;
                  justify-content: center; color: var(--ion-color-medium); }
.h-card .poster img { width: 100%; height: 100%; object-fit: cover; }
.h-card .rate { position: absolute; right: 5px; bottom: 5px; font-size: 11px; font-weight: 700;
                color: #ffd54a; text-shadow: 0 1px 4px rgba(0, 0, 0, 0.85); }
.h-card .n { font-size: 12px; margin-top: 6px; line-height: 1.3; height: 31px; overflow: hidden;
             display: -webkit-box; -webkit-line-clamp: 2; -webkit-box-orient: vertical; }

/* 栏目分页列表页：横向行卡片 */
.row-item { display: flex; align-items: center; gap: 12px; padding: 8px 16px; cursor: pointer; }
.row-item:active { background: rgba(128, 128, 160, 0.1); }
.row-cover { width: 46px; height: 64px; border-radius: 8px; overflow: hidden; flex: 0 0 auto;
             background: linear-gradient(160deg, rgba(93, 135, 255, 0.10), rgba(128, 128, 160, 0.10));
             display: flex; align-items: center; justify-content: center;
             color: var(--ion-color-medium); }
.row-cover img { width: 100%; height: 100%; object-fit: cover; }
.row-meta { flex: 1; min-width: 0; }
.row-title { font-size: 14px; font-weight: 500; overflow: hidden; text-overflow: ellipsis;
             white-space: nowrap; }
.row-sub { display: flex; gap: 8px; font-size: 12px; color: var(--ion-color-medium); margin-top: 2px; }
.rate-text { color: #ffd54a; font-weight: 600; }
.row-arrow { color: var(--ion-color-medium); font-size: 16px; flex: 0 0 auto; }
.list-end { text-align: center; color: var(--ion-color-medium); font-size: 12px; padding: 18px 0 26px; }

/* 播放器 */
.player-wrap { position: relative; width: 100%; aspect-ratio: 16 / 9; background: #000; }
.player-wrap video { width: 100%; height: 100%; display: block; }
.player-ph { position: absolute; inset: 0; display: flex; flex-direction: column; gap: 8px;
             align-items: center; justify-content: center; color: var(--ion-color-medium);
             font-size: 13px; }
.player-ph ion-icon { font-size: 44px; }
.src-row { display: flex; align-items: center; gap: 6px; flex-wrap: wrap; padding: 10px 12px 0; }
.src-label { font-size: 12px; color: var(--ion-color-medium); padding-left: 6px; display: flex;
             align-items: center; gap: 4px; }

/* 详情信息 */
.d-title { font-size: 20px; font-weight: 700; padding: 12px 16px 0; }
.d-meta { display: flex; flex-wrap: wrap; gap: 8px; padding: 6px 16px 0;
          font-size: 12px; color: var(--ion-color-medium); }
.d-summary { padding: 12px 16px 24px; font-size: 13px; line-height: 1.7; opacity: .92; }
.d-summary.dim { color: var(--ion-color-medium); }

.err-note { margin: 20px 16px; padding: 14px; border-radius: 12px; font-size: 13px;
            color: var(--ion-color-danger); background: rgba(var(--ion-color-danger-rgb), 0.08);
            display: flex; flex-direction: column; gap: 6px; }
.err-note .sub { color: var(--ion-color-medium); font-size: 12px; }
.empty-note { padding: 48px 24px; text-align: center; color: var(--ion-color-medium); font-size: 14px; }

/* 设置页 */
.settings-note { padding: 14px 16px 4px; font-size: 13px; color: var(--ion-color-medium);
                 letter-spacing: 1px; }
</style>
