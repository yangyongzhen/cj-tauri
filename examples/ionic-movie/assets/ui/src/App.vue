<script setup>
/* Ionic Vue 观影应用（移动端形态）：首页轮播 + 六个榜单分类 + 搜索 + 详情 + 在线播放。
 * 后端与 examples/movie 共用同一套命令（源码拷贝，仅改包名 ionic_movie_app）：
 *   movie:list {kind: hot|new|soon|top|week|us, start, count, city?}
 *   movie:search {q} · movie:detail {id}
 *   movie:source {sid}（主源 tvurls + 全部源元信息）· movie:sourceitem {sid, note, aid?}（切源取播放地址）
 *   movie:image {url}（防盗链封面，宿主侧取回转 data: URL）
 * 前端只经 window.__CJ_TAURI__ 的 invoke 说话——这是框架契约，页面不自己 fetch。 */
import { ref, computed, onMounted, onBeforeUnmount, watch, nextTick } from 'vue';
import {
  IonApp, IonContent, IonHeader, IonToolbar, IonTitle, IonFooter, IonTabBar, IonTabButton,
  IonIcon, IonSearchbar, IonButton, IonButtons, IonSpinner, IonNote, IonBadge, IonChip,
  IonList, IonItem, IonLabel,
  IonRefresher, IonRefresherContent, toastController
} from '@ionic/vue';
import { searchOutline, filmOutline, settingsOutline, playCircleOutline, closeOutline,
         informationCircleOutline, arrowBackOutline, warningOutline, personCircleOutline } from 'ionicons/icons';
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
const kind = ref('hot');
const movies = ref([]);          // 当前榜单
const loading = ref(false);
const netError = ref('');
const covers = ref({});          // key -> dataURL（封面全走宿主 movie:image，防盗链）
const appVersion = ref('…');

/* 每个榜单各自缓存：切分类不用重新请求 */
const cacheByKind = ref({});

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

async function loadKind(k, refresher) {
  if (cacheByKind.value[k]?.length) { movies.value = cacheByKind.value[k]; if (refresher) refresher.target.complete(); return; }
  loading.value = true; netError.value = '';
  try {
    const body = k === 'hot' ? { kind: k, start: 0, count: 30, city: '北京' } : { kind: k, start: 0, count: 30 };
    const resp = await $invoke('movie:list', body);
    const list = unwrapMovies(resp);
    cacheByKind.value = { ...cacheByKind.value, [k]: list };
    movies.value = list;
    preloadCovers(list, 200, 12);
  } catch (e) {
    netError.value = String(e && e.message ? e.message : e);
    movies.value = [];
  } finally {
    loading.value = false;
    if (refresher) refresher.target.complete();
  }
}

/* ---------------- 搜索 ---------------- */
const searchQ = ref('');
const results = ref([]);
const searching = ref(false);
async function doSearch() {
  const q = (searchQ.value || '').trim();
  if (!q) { await notify('先输入片名'); return; }
  searching.value = true; netError.value = '';
  try {
    const resp = await $invoke('movie:search', { q, start: 0, count: 30 });
    results.value = unwrapMovies(resp);
    if (!results.value.length) await notify('没搜到，换个片名试试');
  } catch (e) {
    netError.value = String(e && e.message ? e.message : e);
    results.value = [];
  } finally { searching.value = false; }
}

/* ---------------- 详情与播放 ---------------- */
const detail = ref(null);        // {base(列表项), summary, sources:[{note,label,items}], tvurls:[{url,name?}], sourceNote}
const detailLoading = ref(false);
const playUrl = ref('');
const playLoading = ref(false);
const videoEl = ref(null);
let hls = null;

const currentCovers = computed(() => (detail.value ? null : movies.value));

async function openDetail(m) {
  detail.value = { base: m, summary: '', genres: '', sources: [], tvurls: [], sourceNote: '' };
  playUrl.value = '';
  detailLoading.value = true;
  loadCover({ sid: `d${m.id}`, cover: m.cover }, 500);
  try {
    /* 详情与播放源并行取；详情失败不拦播放源（简介空态即可） */
    const [d, src] = await Promise.all([
      $invoke('movie:detail', { id: m.id }).catch(() => null),
      $invoke('movie:source', { sid: m.id }).catch(() => null)
    ]);
    if (d && d.code === 0 && d.data) {
      const dd = d.data;
      detail.value.summary = dd.summary || '';
      const g = Array.isArray(dd.genres) ? dd.genres.join(' / ') : (dd.genres || '');
      detail.value.genres = g;
    }
    if (src && src.code === 0 && src.data) {
      const sd = src.data;
      detail.value.tvurls = Array.isArray(sd.tvurls) ? sd.tvurls : [];
      detail.value.sources = Array.isArray(sd.sources) ? sd.sources : [];
      detail.value.sourceNote = sd.note || '';
    }
    /* 有主源播放地址就直接播 */
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
  nextTick(() => {
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
  });
}
onBeforeUnmount(() => { if (hls) { hls.destroy(); hls = null; } });

/* ---------------- 封面与杂项 ---------------- */
async function loadCover(m, size) {
  if (!m.cover) return;
  const key = `${m.sid || m.id}@${size}`;
  if (covers.value[key]) return;
  try {
    const dataUrl = await $invoke('movie:image', { url: m.cover, size });
    covers.value = { ...covers.value, [key]: dataUrl };
  } catch (e) { /* 取不到显示占位 */ }
}
function coverOf(m, size) { return covers.value[`${m.sid || m.id}@${size}`]; }
function preloadCovers(list, size, n) { list.slice(0, n).forEach(m => loadCover(m, size)); }

async function loadVersion() {
  try {
    const v = await $invoke('system:version', {});
    appVersion.value = typeof v === 'string' ? v : (v.version || '');
  } catch (e) { appVersion.value = ''; }
}

const tab = ref('home');
watch(kind, (k) => loadKind(k));
watch(movies, (l) => preloadCovers(l, 200, 12));
watch(tab, (t) => { if (t === 'home' && !movies.value.length) loadKind(kind.value); });

/* 轮播图自动翻页（纯 CSS scroll-snap + 定时器） */
const carousel = ref(null);
const carouselIdx = ref(0);
let carouselTimer = null;
function startCarousel() {
  stopCarousel();
  carouselTimer = setInterval(() => {
    const el = carousel.value;
    if (!el || !movies.value.length || detail.value) return;
    const n = Math.min(5, movies.value.length);
    carouselIdx.value = (carouselIdx.value + 1) % n;
    el.scrollTo({ left: el.clientWidth * carouselIdx.value, behavior: 'smooth' });
  }, 3500);
}
function stopCarousel() { if (carouselTimer) { clearInterval(carouselTimer); carouselTimer = null; } }
function onCarouselScroll() {
  const el = carousel.value;
  if (el) carouselIdx.value = Math.round(el.scrollLeft / el.clientWidth);
}
const carouselMovies = computed(() => movies.value.slice(0, 5));

onMounted(async () => {
  await window.__bridgeReady;
  await loadVersion();
  await loadKind('hot');
  startCarousel();
});
</script>

<template>
  <ion-app>
    <ion-header class="ion-no-border">
      <ion-toolbar>
        <ion-buttons slot="start" v-if="detail">
          <ion-button @click="detail = null; playUrl = ''">
            <ion-icon slot="icon-only" :icon="arrowBackOutline" />
          </ion-button>
        </ion-buttons>
        <ion-title class="app-title">
          <ion-icon :icon="filmOutline" class="logo" />
          {{ detail ? detail.base.title : '仓颉观影' }}
        </ion-title>
        <ion-buttons slot="end">
          <ion-spinner v-if="loading || detailLoading || playLoading" name="crescent" />
        </ion-buttons>
      </ion-toolbar>
      <!-- 首页的榜单分类 chips -->
      <ion-toolbar v-if="!detail && tab === 'home'">
        <div class="chips">
          <ion-chip v-for="k in KINDS" :key="k.key" :class="{ sel: kind === k.key }"
                    @click="kind = k.key" outline>
            <ion-label>{{ k.label }}</ion-label>
          </ion-chip>
        </div>
      </ion-toolbar>
      <ion-toolbar v-if="!detail && tab === 'search'">
        <ion-searchbar v-model="searchQ" placeholder="片名" @keyup.enter="doSearch"
                       @ionClear="results = []" show-clear-button="focus" />
        <ion-buttons slot="end"><ion-button @click="doSearch" class="go">搜索</ion-button></ion-buttons>
      </ion-toolbar>
    </ion-header>

    <ion-content :fullscreen="true">
      <ion-refresher slot="fixed" @ionRefresh="detail ? $event.target.complete() : loadKind(kind, $event)">
        <ion-refresher-content />
      </ion-refresher>

      <div v-if="netError && !detail" class="err-note">
        <ion-icon :icon="informationCircleOutline" />
        <span>{{ netError }}</span>
        <span class="sub">后台接口可达性见桥日志 [movie] 行；用 CJ_MOVIE_API 可指向自建后端</span>
      </div>

      <!-- ================= 详情页 ================= -->
      <div v-if="detail">
        <!-- 播放器 -->
        <div class="player-wrap">
          <video ref="videoEl" controls playsinline :poster="coverOf(detail.base, 500) || ''" />
          <div v-if="!playUrl" class="player-ph">
            <ion-icon :icon="playCircleOutline" />
            <span>{{ playLoading ? '正在取播放地址…' : '选择播放源开始观看' }}</span>
          </div>
        </div>

        <!-- 播放源 chips -->
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

        <!-- 影片信息 -->
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

      <!-- ================= 首页 ================= -->
      <template v-if="!detail && tab === 'home'">
        <!-- 轮播图：榜单前 5 部的大封面横滑 -->
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

        <!-- 影片网格 -->
        <div class="sec-label">{{ KINDS.find(k => k.key === kind)?.label }} · {{ movies.length }} 部</div>
        <div class="grid">
          <div v-for="m in movies" :key="m.id" class="m-card" @click="openDetail(m)">
            <div class="poster">
              <img v-if="coverOf(m, 200)" :src="coverOf(m, 200)" :alt="m.title" />
              <ion-icon v-else :icon="filmOutline" />
              <span v-if="m.rating" class="rate">{{ m.rating }}</span>
            </div>
            <div class="n">{{ m.title }}</div>
            <div class="y">{{ m.year || m.pubdate }}</div>
          </div>
        </div>
      </template>

      <!-- ================= 搜索 ================= -->
      <template v-if="!detail && tab === 'search'">
        <div v-if="results.length" class="sec-label" style="padding-top: 14px;">
          搜索结果 · {{ results.length }} 部
        </div>
        <div class="grid" v-if="results.length">
          <div v-for="m in results" :key="m.id" class="m-card" @click="openDetail(m)">
            <div class="poster">
              <img v-if="coverOf(m, 200)" :src="coverOf(m, 200)" :alt="m.title" />
              <ion-icon v-else :icon="filmOutline" />
              <span v-if="m.rating" class="rate">{{ m.rating }}</span>
            </div>
            <div class="n">{{ m.title }}</div>
            <div class="y">{{ m.year || m.pubdate }}</div>
          </div>
        </div>
        <div v-else-if="!searching" class="empty-note">搜一部想看的片子</div>
      </template>

      <!-- ================= 设置 ================= -->
      <div v-if="!detail && tab === 'settings'">
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
      <ion-tab-button tab="home" :selected="tab === 'home'" @click="detail = null; tab = 'home'">
        <ion-icon :icon="filmOutline" /><ion-label>首页</ion-label>
      </ion-tab-button>
      <ion-tab-button tab="search" :selected="tab === 'search'" @click="detail = null; tab = 'search'">
        <ion-icon :icon="searchOutline" /><ion-label>搜索</ion-label>
      </ion-tab-button>
      <ion-tab-button tab="settings" :selected="tab === 'settings'" @click="detail = null; tab = 'settings'">
        <ion-icon :icon="settingsOutline" /><ion-label>设置</ion-label>
      </ion-tab-button>
    </ion-tab-bar>
  </ion-app>
</template>

<style scoped>
.app-title { font-weight: 700; letter-spacing: .5px; display: flex; align-items: center; gap: 8px; }
.app-title .logo { color: var(--ion-color-primary); font-size: 22px; }
.go { font-weight: 600; }

.chips { display: flex; gap: 6px; overflow-x: auto; padding: 0 8px; scrollbar-width: none; }
.chips::-webkit-scrollbar { display: none; }
ion-chip { margin: 2px 0; --background: rgba(128, 128, 160, 0.08); }
ion-chip.sel { --background: var(--ion-color-primary); }
ion-chip.sel ion-label { color: #fff; font-weight: 600; }

/* 轮播 */
.carousel { display: flex; overflow-x: auto; scroll-snap-type: x mandatory; padding: 8px 0 2px;
            scrollbar-width: none; }
.carousel::-webkit-scrollbar { display: none; }
.car-card { flex: 0 0 100%; scroll-snap-align: center; position: relative; height: 190px;
            overflow: hidden; }
.car-card img { width: 100%; height: 100%; object-fit: cover; display: block;
                background: rgba(128, 128, 160, 0.15); }
.car-cap { position: absolute; left: 0; right: 0; bottom: 0; padding: 26px 16px 18px;
           background: linear-gradient(transparent, rgba(0, 0, 0, 0.82)); }
.car-cap .t { color: #fff; font-weight: 700; font-size: 18px; }
.car-cap .u { color: rgba(255, 255, 255, 0.8); font-size: 12px; margin-top: 3px; }
.dots { position: absolute; bottom: 8px; right: 14px; display: flex; gap: 5px; }
.dots i { width: 6px; height: 6px; border-radius: 3px; background: rgba(255, 255, 255, 0.4);
          transition: all .25s; }
.dots i.on { background: #fff; width: 16px; }

/* 影片网格 */
.sec-label { padding: 14px 16px 6px; font-size: 13px; color: var(--ion-color-medium);
             letter-spacing: 1px; }
.grid { display: grid; grid-template-columns: repeat(3, 1fr); gap: 14px 12px; padding: 4px 16px 20px; }
.m-card { cursor: pointer; }
.m-card .poster { position: relative; width: 100%; aspect-ratio: 2 / 3; border-radius: 10px;
                  overflow: hidden; background: rgba(128, 128, 160, 0.15); display: flex;
                  align-items: center; justify-content: center; color: var(--ion-color-medium); }
.m-card .poster img { width: 100%; height: 100%; object-fit: cover; }
.m-card .rate { position: absolute; right: 6px; bottom: 6px; font-size: 11px; font-weight: 700;
                color: #ffd54a; text-shadow: 0 1px 4px rgba(0, 0, 0, 0.8); }
.m-card .n { font-size: 13px; font-weight: 500; margin-top: 6px; overflow: hidden;
             text-overflow: ellipsis; white-space: nowrap; }
.m-card .y { font-size: 11px; color: var(--ion-color-medium); margin-top: 1px; }

/* 播放器 */
.player-wrap { position: relative; width: 100%; aspect-ratio: 16 / 9; background: #000; }
.player-wrap video { width: 100%; height: 100%; display: block; }
.player-ph { position: absolute; inset: 0; display: flex; flex-direction: column; gap: 8px;
             align-items: center; justify-content: center; color: var(--ion-color-medium);
             font-size: 13px; }
.player-ph ion-icon { font-size: 44px; }
.src-row { display: flex; align-items: center; gap: 6px; flex-wrap: wrap; padding: 10px 12px 0;
           scrollbar-width: none; }
.src-row::-webkit-scrollbar { display: none; }
.src-label { font-size: 12px; color: var(--ion-color-medium); padding-left: 6px; display: flex;
             align-items: center; gap: 4px; }

/* 详情信息 */
.d-title { font-size: 20px; font-weight: 700; padding: 12px 16px 0; }
.d-meta { display: flex; flex-wrap: wrap; gap: 8px; padding: 6px 16px 0;
          font-size: 12px; color: var(--ion-color-medium); }
.d-summary { padding: 12px 16px 24px; font-size: 13px; line-height: 1.7;
             color: var(--ion-text-color, #e8e8ef); opacity: .92; }
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
