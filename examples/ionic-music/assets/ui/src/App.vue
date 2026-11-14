<script setup>
/* Ionic Vue 音乐播放器（移动端形态）
 * 首页 = 轮播图（歌单封面）+ 歌单横滑 + 热歌榜；歌单详情页；播放条 + 同步歌词页。
 * 后端命令与 music-next 共用：music:hot / music:menus / music:search / music:lyric /
 * music:image / fav:get / fav:set / music:quit；前端只经 window.__CJ_TAURI__ 说话。 */
import { ref, computed, onMounted, onBeforeUnmount, watch, nextTick } from 'vue';
import {
  IonApp, IonContent, IonHeader, IonToolbar, IonTitle, IonFooter, IonTabBar, IonTabButton,
  IonIcon, IonSearchbar, IonButton, IonButtons, IonRange, IonSpinner, IonNote, IonBadge,
  IonRefresher, IonRefresherContent, IonBackButton, toastController, alertController
} from '@ionic/vue';
import { heart, heartOutline, searchOutline, flameOutline, libraryOutline, settingsOutline,
         playOutline, pauseOutline, playSkipForwardOutline, playSkipBackOutline,
         musicalNotesOutline, trashOutline, informationCircleOutline,
         chevronForwardOutline, arrowBackOutline, personCircleOutline } from 'ionicons/icons';

const $invoke = (...a) => window.__CJ_TAURI__.invoke(...a);

/* ---------------- 数据 ---------------- */
const tab = ref('home');
const songs = ref([]);           // 热歌榜
const menus = ref([]);           // 歌单（music:menus，每单自带 songs[]）
const results = ref([]);
const favorites = ref([]);
const loading = ref(false);
const searchQ = ref('');
const searchLabel = ref('');
const netError = ref('');
const appVersion = ref('…');
const detail = ref(null);        // 歌单详情：{title, cover, note, user, songs}
const covers = ref({});          // key -> dataURL（封面全走宿主 music:image，防盗链）

/* 工具栏标题与图标随当前页签/歌单详情切换——设置页此前一直顶着「仓颉爱音乐」+ 音符 logo */
const pageTitle = computed(() => {
  if (detail.value) return '歌单';
  switch (tab.value) {
    case 'search': return '搜索';
    case 'fav': return '收藏';
    case 'settings': return '设置';
    default: return '仓颉爱音乐';
  }
});
const pageIcon = computed(() =>
  (!detail.value && tab.value === 'settings') ? settingsOutline : musicalNotesOutline);

async function notify(msg) {
  const t = await toastController.create({ message: msg, duration: 1800, position: 'top' });
  await t.present();
}

function unwrapSongs(resp) {
  if (resp.code !== 0) { throw new Error(resp.message || '后台返回失败'); }
  const arr = Array.isArray(resp.data) ? resp.data : [];
  return arr.map(s => ({
    sid: String(s.sid ?? ''), song: s.song || '未知曲目', sing: s.sing || '未知歌手',
    url: s.url || '', cover: s.cover || ''
  })).filter(s => s.sid && s.url);
}

async function loadHome(refresher) {
  loading.value = true; netError.value = '';
  try {
    const [hot, ms] = await Promise.all([
      $invoke('music:hot', { start: 0, count: 30 }),
      $invoke('music:menus', { start: 0, count: 10 }).catch(() => null)
    ]);
    songs.value = unwrapSongs(hot);
    if (ms && ms.code === 0 && Array.isArray(ms.data)) {
      menus.value = ms.data.filter(m => Array.isArray(m.songs) && m.songs.length);
      /* 轮播与歌单卡的封面：缓存键统一为 menu<i>@<size>（与模板 coverOf 的键一致） */
      menus.value.forEach((m, i) => {
        loadCover({ sid: `menu${i}`, cover: m.cover || '' }, 500);
        loadCover({ sid: `menu${i}`, cover: m.cover || '' }, 200);
      });
    }
  } catch (e) {
    netError.value = String(e && e.message ? e.message : e);
  } finally {
    loading.value = false;
    if (refresher) refresher.target.complete();
  }
}

async function doSearch() {
  const q = (searchQ.value || '').trim();
  if (!q) { await notify('先输入要搜的歌名或歌手'); return; }
  loading.value = true; netError.value = '';
  try {
    /* 后台的 title 字段是 GBK 乱码（已知后台缺陷），页面不显示它，自己拼标题 */
    const resp = await $invoke('music:search', { q, start: 0, count: 30 });
    results.value = unwrapSongs(resp);
    searchLabel.value = `“${q}” 的搜索结果`;
    if (!results.value.length) await notify('没搜到，换个关键词试试');
  } catch (e) {
    netError.value = String(e && e.message ? e.message : e);
    results.value = [];
  } finally { loading.value = false; }
}

async function loadFavorites() {
  try {
    const resp = await $invoke('fav:get', {});
    favorites.value = Array.isArray(resp.songs) ? resp.songs : [];
  } catch (e) { favorites.value = []; }
}

async function loadVersion() {
  try {
    const v = await $invoke('system:version', {});
    appVersion.value = typeof v === 'string' ? v : (v.version || '');
  } catch (e) { appVersion.value = ''; }
}

function openDetail(menu) {
  detail.value = {
    title: menu.title || '歌单',
    cover: menu.cover || '',
    user: menu.user || '',
    note: menu.note || '',
    songs: (menu.songs || []).map(s => ({
      sid: String(s.sid ?? ''), song: s.song || '', sing: s.sing || '',
      url: s.url || '', cover: s.cover || ''
    })).filter(s => s.sid && s.url)
  };
  loadCover({ sid: 'detail', cover: detail.value.cover }, 500, detail.value.cover);
}

/* ---------------- 播放器 ---------------- */
const player = ref(null);
const current = ref(null);
const playing = ref(false);
const position = ref(0);
const duration = ref(0);

const progress = computed(() => (duration.value > 0 ? position.value / duration.value : 0));
const posText = computed(() => fmt(position.value));
const durText = computed(() => fmt(duration.value));
function fmt(sec) {
  if (!Number.isFinite(sec) || sec < 0) return '0:00';
  const m = Math.floor(sec / 60), s = Math.floor(sec % 60);
  return `${m}:${String(s).padStart(2, '0')}`;
}

function ensurePlayer() {
  if (player.value) return;
  player.value = new Audio();
  player.value.addEventListener('timeupdate', () => { position.value = player.value.currentTime; });
  player.value.addEventListener('durationchange', () => { duration.value = player.value.duration; });
  player.value.addEventListener('ended', () => { playing.value = false; nextSong(); });
  player.value.addEventListener('error', () => { playing.value = false; notify('这条播放地址取不到音频'); });
}

async function play(song, list) {
  ensurePlayer();
  current.value = song;
  playContext.value = list || playContext.value;
  position.value = 0; duration.value = 0;
  player.value.src = song.url;
  player.value.play().then(() => { playing.value = true; }).catch(() => { playing.value = false; });
  loadLyric(song.sid);
  loadCover(song, 500);
  lyricOpen.value = true;   // 点歌直接进「正在播放」页（带控件），而不是只弹底部迷你条
}

const playContext = ref([]);     // 「正在播的那份列表」：上一首/下一首在它里面找
function step(delta) {
  const list = playContext.value.length ? playContext.value : songs.value;
  const i = list.findIndex(s => s.sid === current.value?.sid);
  const n = list[i + delta];
  if (n) play(n, list);
}
const nextSong = () => step(1);
const prevSong = () => step(-1);
function toggle() {
  if (!player.value || !current.value) return;
  if (playing.value) { player.value.pause(); playing.value = false; }
  else { player.value.play().then(() => { playing.value = true; }); }
}
function seek(ratio) {
  if (player.value && duration.value > 0) player.value.currentTime = ratio * duration.value;
}

/* ---------------- 歌词 ---------------- */
const lyricLines = ref([]);
const lyricOpen = ref(false);
const lyricBox = ref(null);
async function loadLyric(sid) {
  lyricLines.value = [];
  try {
    const r = await $invoke('music:lyric', { sid });
    if (r.found) lyricLines.value = r.lines;
  } catch (e) { /* 没歌词不是错误，显示空态 */ }
}
const activeLyric = computed(() => {
  let idx = -1;
  for (let i = 0; i < lyricLines.value.length; i++) {
    if (lyricLines.value[i].at <= Math.floor(position.value * 1000)) idx = i;
  }
  return idx;
});
/* 歌词自动滚动：活跃行始终滚到容器中间 */
watch(activeLyric, async (i) => {
  if (i < 0 || !lyricOpen.value) return;
  await nextTick();
  const box = lyricBox.value;
  const line = box && box.children[i];
  if (box && line) box.scrollTo({ top: line.offsetTop - box.clientHeight / 2, behavior: 'smooth' });
});
function openLyric() {
  lyricOpen.value = true;
  if (current.value) loadLyric(current.value.sid);
}
onBeforeUnmount(() => { if (player.value) player.value.pause(); });

/* ---------------- 封面与收藏 ---------------- */
async function loadCover(song, size, rawUrl) {
  const url = rawUrl || song.cover;
  if (!url) return;
  const key = `${song.sid}@${size}`;
  if (covers.value[key]) return;
  try {
    const dataUrl = await $invoke('music:image', { url, size });
    covers.value = { ...covers.value, [key]: dataUrl };
  } catch (e) { /* 取不到显示占位 */ }
}
function coverOf(sid, size, fallbackKey) {
  return covers.value[`${sid}@${size}`] || (fallbackKey ? covers.value[fallbackKey] : null);
}
function preloadCovers(list, size, n) {
  list.slice(0, n).forEach(s => loadCover(s, size));
}

function isFav(sid) { return favorites.value.some(s => s.sid === sid); }
async function toggleFav(song) {
  /* fav:set 是整表替换：收藏数组按 op 增删后整体发回 */
  const adding = !isFav(song.sid);
  const next = adding ? [...favorites.value, song] : favorites.value.filter(s => s.sid !== song.sid);
  try {
    const resp = await $invoke('fav:set', { songs: next });
    if (resp.code === undefined || resp.code === 0) {
      await loadFavorites();
      await notify(adding ? '已加入收藏' : '已取消收藏');
    } else { await notify(resp.message || '收藏失败'); }
  } catch (e) { await notify(String(e && e.message ? e.message : e)); }
}

async function clearFavorites() {
  const alert = await alertController.create({
    header: '清空收藏',
    message: `将删除全部 ${favorites.value.length} 首收藏，且不可恢复。`,
    buttons: [
      { text: '取消', role: 'cancel' },
      { text: '清空', role: 'destructive', handler: async () => {
          try {
            await $invoke('fav:set', { songs: [] });
            await loadFavorites();
            await notify('收藏已清空');
          } catch (e) { await notify(String(e && e.message ? e.message : e)); }
        } }
    ]
  });
  await alert.present();
}

/* 轮播图自动翻页：3 秒一张，触摸时不停（纯 CSS scroll-snap + 定时器，不引 swiper） */
const carousel = ref(null);
const carouselIdx = ref(0);
let carouselTimer = null;
function startCarousel() {
  stopCarousel();
  carouselTimer = setInterval(() => {
    const el = carousel.value;
    if (!el || !menus.value.length || detail.value) return;
    const n = menus.value.length;
    carouselIdx.value = (carouselIdx.value + 1) % n;
    el.scrollTo({ left: el.clientWidth * carouselIdx.value, behavior: 'smooth' });
  }, 3000);
}
function stopCarousel() { if (carouselTimer) { clearInterval(carouselTimer); carouselTimer = null; } }
function onCarouselScroll() {
  const el = carousel.value;
  if (el) carouselIdx.value = Math.round(el.scrollLeft / el.clientWidth);
}

watch(tab, (t) => {
  if (t === 'fav') loadFavorites();
  if (t === 'home') { preloadCovers(songs.value, 200, 12); preloadCovers(menus.value, 500, 4, ); }
});
watch(songs, () => preloadCovers(songs.value, 200, 12));

onMounted(async () => {
  await window.__bridgeReady;
  await loadVersion();
  await loadHome(null);
  startCarousel();
});
</script>

<template>
  <ion-app>
    <ion-header class="ion-no-border">
      <ion-toolbar>
        <ion-buttons slot="start" v-if="detail">
          <ion-button @click="detail = null"><ion-icon slot="icon-only" :icon="arrowBackOutline" /></ion-button>
        </ion-buttons>
        <ion-title class="app-title">
          <ion-icon :icon="pageIcon" class="logo" />
          {{ pageTitle }}
        </ion-title>
        <ion-buttons slot="end">
          <ion-spinner v-if="loading" name="crescent" />
        </ion-buttons>
      </ion-toolbar>
      <ion-toolbar v-if="tab === 'search' && !detail">
        <ion-searchbar v-model="searchQ" placeholder="歌名 / 歌手" @keyup.enter="doSearch"
                       @ionClear="results = []" show-clear-button="focus" />
        <ion-buttons slot="end"><ion-button @click="doSearch" class="go">搜索</ion-button></ion-buttons>
      </ion-toolbar>
    </ion-header>

    <ion-content :fullscreen="true">
      <ion-refresher slot="fixed" @ionRefresh="detail ? $event.target.complete() : loadHome($event)">
        <ion-refresher-content />
      </ion-refresher>

      <div v-if="netError && !detail" class="err-note">
        <ion-icon :icon="informationCircleOutline" />
        <span>{{ netError }}</span>
        <span class="sub">后台接口可达性见桥日志 [music] 行；用 CJ_MUSIC_API 可指向自建后端</span>
      </div>

      <!-- ================= 歌单详情页 ================= -->
      <div v-if="detail" class="detail-head">
        <img class="detail-cover" :src="covers[`detail@500`] || ''" alt="" />
        <div class="detail-title">{{ detail.title }}</div>
        <div class="detail-user" v-if="detail.user">投稿：{{ detail.user }}</div>
        <div class="detail-note" v-if="detail.note">{{ detail.note }}</div>
        <div class="sec-label">曲目 · {{ detail.songs.length }} 首</div>
        <div v-for="s in detail.songs" :key="s.sid" class="song-row"
             :class="{ on: current?.sid === s.sid }" @click="play(s, detail.songs)">
          <div class="cover">
            <img v-if="coverOf(s.sid, 200)" :src="coverOf(s.sid, 200)" :alt="s.song" />
            <ion-icon v-else :icon="musicalNotesOutline" />
            <div v-if="current?.sid === s.sid && playing" class="eq"><i></i><i></i><i></i></div>
          </div>
          <div class="meta">
            <div class="name">{{ s.song }}</div>
            <div class="artist">{{ s.sing }}</div>
          </div>
          <ion-icon class="fav" :icon="isFav(s.sid) ? heart : heartOutline"
                    :class="{ liked: isFav(s.sid) }" @click.stop="toggleFav(s)" />
        </div>
      </div>

      <!-- ================= 首页 ================= -->
      <template v-if="!detail && tab === 'home'">
        <!-- 轮播图：歌单封面横滑（scroll-snap + 自动翻页），点进歌单详情 -->
        <div v-if="menus.length" class="carousel" ref="carousel" @scroll.passive="onCarouselScroll">
          <div v-for="(m, i) in menus" :key="i" class="car-card" @click="openDetail(m)">
            <img :src="covers[`menu${i}@500`] || ''" alt="" />
            <div class="car-cap">
              <div class="t">{{ m.title }}</div>
              <div class="u" v-if="m.user">{{ m.user }} · {{ m.songs.length }} 首</div>
            </div>
            <div class="dots">
              <i v-for="(d, j) in menus" :key="j" :class="{ on: j === carouselIdx }" />
            </div>
          </div>
        </div>

        <!-- 歌单横滑 -->
        <div v-if="menus.length" class="h-section">
          <div class="h-title">推荐歌单 <ion-icon :icon="chevronForwardOutline" /></div>
          <div class="h-row">
            <div v-for="(m, i) in menus" :key="'p' + i" class="h-card" @click="openDetail(m)">
              <img :src="covers[`menu${i}@200`] || ''" alt="" />
              <div class="n">{{ m.title }}</div>
            </div>
          </div>
        </div>

        <!-- 热歌榜 -->
        <div class="h-section">
          <div class="h-title">热歌榜 <span class="cnt">{{ songs.length }} 首</span></div>
          <div v-for="s in songs" :key="s.sid" class="song-row" :class="{ on: current?.sid === s.sid }"
               @click="play(s, songs)">
            <div class="cover">
              <img v-if="coverOf(s.sid, 200)" :src="coverOf(s.sid, 200)" :alt="s.song" />
              <ion-icon v-else :icon="musicalNotesOutline" />
              <div v-if="current?.sid === s.sid && playing" class="eq"><i></i><i></i><i></i></div>
            </div>
            <div class="meta">
              <div class="name">{{ s.song }}</div>
              <div class="artist">{{ s.sing }}</div>
            </div>
            <ion-icon class="fav" :icon="isFav(s.sid) ? heart : heartOutline"
                      :class="{ liked: isFav(s.sid) }" @click.stop="toggleFav(s)" />
          </div>
        </div>
      </template>

      <!-- ================= 搜索 ================= -->
      <template v-if="!detail && tab === 'search'">
        <div v-if="searchLabel" class="sec-label" style="padding-top: 14px;">{{ searchLabel }}</div>
        <div v-for="s in results" :key="s.sid" class="song-row" :class="{ on: current?.sid === s.sid }"
             @click="play(s, results)">
          <div class="cover">
            <img v-if="coverOf(s.sid, 200)" :src="coverOf(s.sid, 200)" :alt="s.song" />
            <ion-icon v-else :icon="musicalNotesOutline" />
          </div>
          <div class="meta">
            <div class="name">{{ s.song }}</div>
            <div class="artist">{{ s.sing }}</div>
          </div>
          <ion-icon class="fav" :icon="isFav(s.sid) ? heart : heartOutline"
                    :class="{ liked: isFav(s.sid) }" @click.stop="toggleFav(s)" />
        </div>
        <div v-if="!results.length && !loading" class="empty-note">搜一首试试</div>
      </template>

      <!-- ================= 收藏 ================= -->
      <template v-if="!detail && tab === 'fav'">
        <div v-if="favorites.length" class="sec-label" style="padding-top: 14px;">
          我的收藏 · {{ favorites.length }} 首
        </div>
        <div v-for="s in favorites" :key="s.sid" class="song-row" :class="{ on: current?.sid === s.sid }"
             @click="play(s, favorites)">
          <div class="cover">
            <img v-if="coverOf(s.sid, 200)" :src="coverOf(s.sid, 200)" :alt="s.song" />
            <ion-icon v-else :icon="musicalNotesOutline" />
          </div>
          <div class="meta">
            <div class="name">{{ s.song }}</div>
            <div class="artist">{{ s.sing }}</div>
          </div>
          <ion-icon class="fav liked" :icon="heart" @click.stop="toggleFav(s)" />
        </div>
        <div v-if="!favorites.length" class="empty-note">还没有收藏，去热门页点心形收一首</div>
      </template>

      <!-- ================= 设置 ================= -->
      <div v-if="!detail && tab === 'settings'">
        <div class="settings-note">通用</div>
        <ion-list inset>
          <ion-item :detail="false">
            <ion-icon slot="start" :icon="personCircleOutline" color="primary" />
            <ion-label>
              <h2>框架版本</h2><p>{{ appVersion }}</p>
            </ion-label>
          </ion-item>
          <ion-item :detail="false">
            <ion-icon slot="start" :icon="musicalNotesOutline" color="tertiary" />
            <ion-label>
              <h2>音乐数据</h2>
              <p>来自在线音乐接口（CJ_MUSIC_API 可指向自建后端）</p>
            </ion-label>
          </ion-item>
        </ion-list>
        <div class="settings-note">收藏</div>
        <ion-list inset>
          <ion-item :detail="false">
            <ion-icon slot="start" :icon="heart" color="danger" />
            <ion-label>
              <h2>已收藏歌曲</h2>
              <p>{{ favorites.length }} 首 · 存于本机 music-library.local.json</p>
            </ion-label>
            <ion-button slot="end" fill="outline" size="small" :disabled="!favorites.length"
                        color="danger" @click="clearFavorites">
              <ion-icon slot="start" :icon="trashOutline" />清空
            </ion-button>
          </ion-item>
        </ion-list>
        <div class="settings-note">关于</div>
        <ion-list inset>
          <ion-item :detail="false">
            <ion-icon slot="start" :icon="informationCircleOutline" color="medium" />
            <ion-label class="ion-text-wrap">
              <h2>cj-tauri · Ionic 示例</h2>
              <p>仓颉静态编译后端 + 系统 WebView 前端；本页用 @ionic/vue 构建，
                 经统一 IPC 桥与后端通信，命令走能力白名单。</p>
            </ion-label>
          </ion-item>
        </ion-list>
      </div>

      <!-- ================= 正在播放页（Teleport 到 body 做真全屏，绕开 ion-content 的 transform 包含块） ================= -->
      <Teleport to="body">
      <transition name="lyric">
        <div v-if="lyricOpen" class="nowpage">
          <div class="nowpage-top">
            <ion-button fill="clear" @click="lyricOpen = false">
              <ion-icon slot="icon-only" :icon="arrowBackOutline" />
            </ion-button>
            <span class="nowpage-tag">正在播放</span>
            <span class="nowpage-spacer" />
          </div>

          <div class="nowpage-cover" v-if="current">
            <img :src="coverOf(current.sid, 500) || coverOf(current.sid, 200) || ''" alt="" />
            <ion-icon v-if="!coverOf(current.sid, 500) && !coverOf(current.sid, 200)"
                      :icon="musicalNotesOutline" />
          </div>

          <div class="nowpage-song" v-if="current">
            <div class="nowpage-name">{{ current.song }}</div>
            <div class="nowpage-artist">{{ current.sing }}</div>
          </div>

          <ion-range class="nowpage-seek" :value="progress" :min="0" :max="1" :step="0.01"
                     @ionInput="seek($event.detail.value)" />
          <div class="nowpage-times"><span>{{ posText }}</span><span>{{ durText }}</span></div>

          <div class="nowpage-controls">
            <ion-button fill="clear" @click="prevSong">
              <ion-icon slot="icon-only" :icon="playSkipBackOutline" />
            </ion-button>
            <ion-button fill="clear" class="nowpage-pp" @click="toggle">
              <ion-icon slot="icon-only" :icon="playing ? pauseOutline : playOutline" />
            </ion-button>
            <ion-button fill="clear" @click="nextSong">
              <ion-icon slot="icon-only" :icon="playSkipForwardOutline" />
            </ion-button>
          </div>

          <div class="nowpage-lyric-tag" v-if="lyricLines.length">歌词</div>
          <div class="nowpage-lyric" ref="lyricBox">
            <template v-if="lyricLines.length">
              <p v-for="(l, i) in lyricLines" :key="i" :class="{ on: i === activeLyric }">{{ l.text }}</p>
            </template>
            <p v-else class="off">暂无歌词</p>
          </div>
        </div>
      </transition>
      </Teleport>
    </ion-content>

    <!-- 底部播放条 -->
    <ion-footer v-if="current" class="ion-no-border player-bar">
      <ion-toolbar>
        <div class="now">
          <div class="mini-cover" @click="openLyric">
            <img :src="coverOf(current.sid, 200) || coverOf(current.sid, 500) || ''" alt="" />
            <ion-icon v-if="!coverOf(current.sid, 200) && !coverOf(current.sid, 500)"
                      :icon="musicalNotesOutline" />
          </div>
          <div class="meta" @click="openLyric">
            <div class="name">{{ current.song }}</div>
            <div class="artist">{{ current.sing }}</div>
          </div>
          <ion-button fill="clear" size="small" @click="prevSong">
            <ion-icon slot="icon-only" :icon="playSkipBackOutline" />
          </ion-button>
          <ion-button fill="clear" class="pp" @click="toggle">
            <ion-icon slot="icon-only" :icon="playing ? pauseOutline : playOutline" />
          </ion-button>
          <ion-button fill="clear" size="small" @click="nextSong">
            <ion-icon slot="icon-only" :icon="playSkipForwardOutline" />
          </ion-button>
        </div>
        <ion-range class="seek" :value="progress" :min="0" :max="1" :step="0.01"
                   @ionInput="seek($event.detail.value)" />
        <div class="times"><span>{{ posText }}</span><span>{{ durText }}</span></div>
      </ion-toolbar>
    </ion-footer>

    <ion-tab-bar class="ion-no-border">
      <ion-tab-button tab="home" :selected="tab === 'home'" @click="detail = null; tab = 'home'">
        <ion-icon :icon="flameOutline" /><ion-label>首页</ion-label>
      </ion-tab-button>
      <ion-tab-button tab="search" :selected="tab === 'search'" @click="detail = null; tab = 'search'">
        <ion-icon :icon="searchOutline" /><ion-label>搜索</ion-label>
      </ion-tab-button>
      <ion-tab-button tab="fav" :selected="tab === 'fav'" @click="detail = null; tab = 'fav'">
        <ion-icon :icon="libraryOutline" />
        <ion-label>收藏</ion-label>
        <ion-badge v-if="favorites.length" color="danger">{{ favorites.length }}</ion-badge>
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

.sec-label { padding: 14px 16px 6px; font-size: 13px; color: var(--ion-color-medium); letter-spacing: 1px; }
.sec-label .cnt { font-size: 12px; }
.h-section { margin-top: 4px; }
.h-title { display: flex; align-items: center; gap: 2px; padding: 14px 16px 8px;
           font-size: 15px; font-weight: 700; }
.h-title .cnt { font-size: 12px; font-weight: 400; color: var(--ion-color-medium); }

/* 轮播图：横向 scroll-snap，一屏一单 */
.carousel { display: flex; overflow-x: auto; scroll-snap-type: x mandatory; gap: 0;
            padding: 8px 0 2px; scrollbar-width: none; }
.carousel::-webkit-scrollbar { display: none; }
.car-card { flex: 0 0 100%; scroll-snap-align: center; position: relative; height: 168px;
            overflow: hidden; }
.car-card img { width: 100%; height: 100%; object-fit: cover; display: block; }
.car-cap { position: absolute; left: 0; right: 0; bottom: 0; padding: 22px 16px 18px;
           background: linear-gradient(transparent, rgba(0, 0, 0, 0.78)); }
.car-cap .t { color: #fff; font-weight: 700; font-size: 17px; }
.car-cap .u { color: rgba(255, 255, 255, 0.75); font-size: 12px; margin-top: 3px; }
.dots { position: absolute; bottom: 8px; right: 14px; display: flex; gap: 5px; }
.dots i { width: 6px; height: 6px; border-radius: 3px; background: rgba(255, 255, 255, 0.4);
          transition: all .25s; }
.dots i.on { background: #fff; width: 16px; }

/* 歌单横滑 */
.h-row { display: flex; gap: 12px; overflow-x: auto; padding: 2px 16px 8px; scrollbar-width: none; }
.h-row::-webkit-scrollbar { display: none; }
.h-card { flex: 0 0 104px; cursor: pointer; }
.h-card img { width: 104px; height: 104px; border-radius: 12px; object-fit: cover;
              background: rgba(128, 128, 160, 0.15); display: block; }
.h-card .n { font-size: 12px; margin-top: 6px; line-height: 1.35; height: 32px; overflow: hidden;
             display: -webkit-box; -webkit-line-clamp: 2; -webkit-box-orient: vertical; }

/* 歌曲行 */
.song-row { display: flex; align-items: center; gap: 12px; padding: 9px 16px; cursor: pointer;
            transition: background .2s; }
.song-row:active { background: rgba(128, 128, 160, 0.12); }
.song-row.on { background: linear-gradient(90deg, rgba(93, 135, 255, 0.16), transparent); }
.song-row .cover { width: 52px; height: 52px; border-radius: 10px; overflow: hidden; flex: 0 0 auto;
                   background: rgba(128, 128, 160, 0.15); display: flex; align-items: center;
                   justify-content: center; color: var(--ion-color-medium); position: relative; }
.song-row .cover img { width: 100%; height: 100%; object-fit: cover; }
.song-row .meta { flex: 1; min-width: 0; }
.song-row .name { font-size: 15px; font-weight: 500; overflow: hidden; text-overflow: ellipsis;
                  white-space: nowrap; }
.song-row.on .name { color: var(--ion-color-primary); }
.song-row .artist { font-size: 12px; color: var(--ion-color-medium); margin-top: 2px;
                    overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
.song-row .fav { font-size: 20px; color: var(--ion-color-medium); flex: 0 0 auto; padding: 8px; }
.song-row .fav.liked { color: var(--ion-color-danger); }
.eq { position: absolute; bottom: 3px; right: 3px; display: flex; gap: 2px; align-items: flex-end;
      height: 10px; }
.eq i { width: 3px; background: var(--ion-color-primary); border-radius: 1px;
        animation: eq 0.8s infinite ease-in-out; }
.eq i:nth-child(2) { animation-delay: .2s; } .eq i:nth-child(3) { animation-delay: .4s; }
@keyframes eq { 0%, 100% { height: 3px; } 50% { height: 10px; } }

/* 歌单详情头 */
.detail-head { padding-bottom: 12px; }
.detail-cover { width: 100%; height: 200px; object-fit: cover; display: block;
                background: rgba(128, 128, 160, 0.15); }
.detail-title { font-size: 20px; font-weight: 700; padding: 14px 16px 0; }
.detail-user { font-size: 12px; color: var(--ion-color-medium); padding: 4px 16px 0; }
.detail-note { font-size: 12px; color: var(--ion-color-medium); padding: 2px 16px 0;
               overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }

.err-note { margin: 20px 16px; padding: 14px; border-radius: 12px; font-size: 13px;
            color: var(--ion-color-danger); background: rgba(var(--ion-color-danger-rgb), 0.08);
            display: flex; flex-direction: column; gap: 6px; }
.err-note .sub { color: var(--ion-color-medium); font-size: 12px; }
.empty-note { padding: 48px 24px; text-align: center; color: var(--ion-color-medium); font-size: 14px; }

/* 播放条 */
.player-bar ion-toolbar { --padding-start: 10px; --padding-end: 10px; --min-height: 92px; }
.now { display: flex; align-items: center; gap: 10px; }
.now .mini-cover { width: 44px; height: 44px; border-radius: 8px; overflow: hidden; flex: 0 0 auto;
                   background: rgba(128, 128, 160, 0.15); display: flex; align-items: center;
                   justify-content: center; color: var(--ion-color-medium); cursor: pointer; }
.now .mini-cover img { width: 100%; height: 100%; object-fit: cover; }
.now .meta { flex: 1; min-width: 0; cursor: pointer; }
.now .name { font-size: 14px; font-weight: 600; overflow: hidden; text-overflow: ellipsis;
             white-space: nowrap; }
.now .artist { font-size: 11px; color: var(--ion-color-medium); overflow: hidden;
               text-overflow: ellipsis; white-space: nowrap; }
.pp ion-icon { font-size: 32px; }
.seek { --bar-height: 3px; margin: 0; height: 22px; }
.times { display: flex; justify-content: space-between; font-size: 10px;
         color: var(--ion-color-medium); margin-top: -10px; padding: 0 14px; }

/* 正在播放页（全屏：封面 + 进度 + 控件 + 同步歌词） */
.nowpage { position: fixed; inset: 0; z-index: 99;
           background: linear-gradient(180deg, #10101c 0%, #17172a 60%, #10101c 100%);
           display: flex; flex-direction: column; padding: 6px 24px 26px; }
.nowpage-top { display: flex; align-items: center; gap: 4px; }
.nowpage-top ion-button { margin: -8px -8px -8px 0; }
.nowpage-tag { color: var(--ion-color-medium); font-size: 13px; letter-spacing: 3px; }
.nowpage-spacer { flex: 1; }
.nowpage-cover { width: 210px; height: 210px; border-radius: 16px; overflow: hidden; align-self: center;
                 margin: 16px 0 6px; box-shadow: 0 12px 40px rgba(0, 0, 0, 0.6);
                 display: flex; align-items: center; justify-content: center;
                 background: rgba(128, 128, 160, 0.1); color: var(--ion-color-medium); font-size: 52px; }
.nowpage-cover img { width: 100%; height: 100%; object-fit: cover; }
.nowpage-song { text-align: center; margin: 8px 0 0; }
.nowpage-name { font-size: 20px; font-weight: 700; }
.nowpage-artist { font-size: 13px; color: var(--ion-color-medium); margin-top: 5px; }
.nowpage-seek { --bar-height: 4px; margin: 14px 0 0; }
.nowpage-times { display: flex; justify-content: space-between; font-size: 11px;
                 color: var(--ion-color-medium); margin-top: -6px; }
.nowpage-controls { display: flex; align-items: center; justify-content: center; gap: 38px;
                    margin-top: 12px; }
.nowpage-controls ion-button { --padding-start: 8px; --padding-end: 8px; }
.nowpage-controls ion-icon { font-size: 34px; color: #fff; }
.nowpage-pp ion-icon { font-size: 54px; }
.nowpage-lyric-tag { text-align: center; color: var(--ion-color-medium); font-size: 12px;
                     letter-spacing: 3px; margin-top: 16px; }
.nowpage-lyric { flex: 1; min-height: 0; overflow: auto; width: 100%; text-align: center;
                 padding: 16px 0 4px; scrollbar-width: none;
                 mask-image: linear-gradient(transparent, #000 10%, #000 88%, transparent);
                 -webkit-mask-image: linear-gradient(transparent, #000 10%, #000 88%, transparent); }
.nowpage-lyric::-webkit-scrollbar { display: none; }
.nowpage-lyric p { color: var(--ion-color-medium); margin: 12px 0; transition: all .25s; font-size: 14px; }
.nowpage-lyric p.on { color: #fff; font-weight: 700; font-size: 16px; }
.nowpage-lyric p.off { color: var(--ion-color-medium); }
.lyric-enter-active, .lyric-leave-active { transition: opacity .22s, transform .22s; }
.lyric-enter-from, .lyric-leave-to { opacity: 0; transform: translateY(24px); }

/* 设置页 */
.settings-note { padding: 14px 16px 4px; font-size: 13px; color: var(--ion-color-medium);
                 letter-spacing: 1px; }
</style>
