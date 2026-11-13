<script setup>
/* Ionic Vue 音乐播放器（移动端形态）：热门 / 搜索 / 收藏 三个页签 + 底部播放条 + 歌词页。
   与 music-next 共用同一套仓颉后端命令（music:hot / music:search / music:lyric / music:image / fav:*），
   前端只经 window.__CJ_TAURI__ 的 invoke 说话——这是框架的契约，页面不自己 fetch。 */
import { ref, computed, onMounted } from 'vue';
import {
  IonApp, IonContent, IonHeader, IonToolbar, IonTitle, IonFooter, IonTabBar, IonTabButton,
  IonIcon, IonList, IonItem, IonThumbnail, IonLabel, IonSearchbar, IonButton, IonButtons,
  IonRange, IonSpinner, IonNote, IonRefresher, IonRefresherContent, toastController
} from '@ionic/vue';
import { heart, heartOutline, searchOutline, flameOutline, libraryOutline,
         playOutline, pauseOutline, playSkipForwardOutline, playSkipBackOutline,
        musicalNotesOutline } from 'ionicons/icons';

const $invoke = (...a) => window.__CJ_TAURI__.invoke(...a);

/* ---------------- 页签与数据 ---------------- */
const tab = ref('hot');
const songs = ref([]);          // 热门榜
const results = ref([]);        // 搜索结果
const favorites = ref([]);      // 收藏（fav:get 的 songs 数组）
const loading = ref(false);
const searchQ = ref('');
const searchLabel = ref('');
const netError = ref('');

async function notify(msg) {
  const t = await toastController.create({ message: msg, duration: 1800, position: 'top' });
  await t.present();
}

/* 后台返回 {code, message, data}：code!=0 是业务失败（HTTP 仍是 200，仓颉层不抛） */
function unwrapSongs(resp, fallbackLabel) {
  if (resp.code !== 0) { throw new Error(resp.message || '后台返回失败'); }
  const arr = Array.isArray(resp.data) ? resp.data : [];
  return arr.map(s => ({
    sid: String(s.sid ?? ''), song: s.song || '未知曲目', sing: s.sing || '未知歌手',
    url: s.url || '', cover: s.cover || ''
  })).filter(s => s.sid && s.url);
}

async function loadHot(refresher) {
  loading.value = true; netError.value = '';
  try {
    const resp = await $invoke('music:hot', { start: 0, count: 20 });
    songs.value = unwrapSongs(resp, '热门');
  } catch (e) {
    netError.value = String(e && e.message ? e.message : e);
    songs.value = [];
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
    const resp = await $invoke('music:search', { q, start: 0, count: 30 });
    /* 后台的 title 字段是 GBK 乱码（已知后台缺陷），页面不显示它，自己拼标题 */
    results.value = unwrapSongs(resp, q);
    searchLabel.value = `“${q}” 的搜索结果`;
    if (!results.value.length) await notify('没搜到，换个关键词试试');
  } catch (e) {
    netError.value = String(e && e.message ? e.message : e);
    results.value = [];
  } finally {
    loading.value = false;
  }
}

async function loadFavorites() {
  try {
    const resp = await $invoke('fav:get', {});
    favorites.value = Array.isArray(resp.songs) ? resp.songs : [];
  } catch (e) {
    favorites.value = [];
  }
}

/* ---------------- 播放器 ---------------- */
const player = ref(null);       // HTMLAudioElement
const current = ref(null);      // 正在播的那首
const playing = ref(false);
const position = ref(0);
const duration = ref(0);
const covers = ref({});         // sid -> dataURL（封面经宿主侧取，防盗链）

const progress = computed(() => (duration.value > 0 ? position.value / duration.value : 0));
const posText = computed(() => fmt(position.value));
const durText = computed(() => fmt(duration.value));
function fmt(sec) {
  if (!Number.isFinite(sec) || sec < 0) return '0:00';
  const m = Math.floor(sec / 60), s = Math.floor(sec % 60);
  return `${m}:${String(s).padStart(2, '0')}`;
}

async function play(song) {
  current.value = song;
  if (!player.value) {
    player.value = new Audio();
    player.value.addEventListener('timeupdate', () => { position.value = player.value.currentTime; });
    player.value.addEventListener('durationchange', () => { duration.value = player.value.duration; });
    player.value.addEventListener('ended', () => { playing.value = false; nextSong(); });
    player.value.addEventListener('error', () => { playing.value = false; notify('这条播放地址取不到音频'); });
  }
  player.value.src = song.url;
  player.value.play().then(() => { playing.value = true; }).catch(() => { playing.value = false; });
  loadLyric(song.sid);
  loadCover(song);
}

function toggle() {
  if (!player.value || !current.value) return;
  if (playing.value) { player.value.pause(); playing.value = false; }
  else { player.value.play().then(() => { playing.value = true; }); }
}

function seek(ratio) {
  if (player.value && duration.value > 0) player.value.currentTime = ratio * duration.value;
}

function nextSong() {
  const list = currentList.value;
  const i = list.findIndex(s => s.sid === current.value?.sid);
  if (i >= 0 && i + 1 < list.length) play(list[i + 1]);
}

function prevSong() {
  const list = currentList.value;
  const i = list.findIndex(s => s.sid === current.value?.sid);
  if (i > 0) play(list[i - 1]);
}

const currentList = computed(() => {
  if (tab.value === 'search') return results.value;
  if (tab.value === 'fav') return favorites.value;
  return songs.value;
});

/* ---------------- 歌词 ---------------- */
const lyricLines = ref([]);
const lyricOpen = ref(false);
async function loadLyric(sid) {
  lyricLines.value = [];
  try {
    const r = await $invoke('music:lyric', { sid });
    if (r.found) lyricLines.value = r.lines;
  } catch (e) { /* 没歌词不是错误，页面显示空态 */ }
}
const activeLyric = computed(() => {
  let idx = -1;
  for (let i = 0; i < lyricLines.value.length; i++) {
    if (lyricLines.value[i].at <= Math.floor(position.value * 1000)) idx = i;
  }
  return idx;
});

/* ---------------- 封面与收藏 ---------------- */
async function loadCover(song) {
  if (!song.cover || covers.value[song.sid]) return;
  try {
    const dataUrl = await $invoke('music:image', { url: song.cover, size: 200 });
    covers.value = { ...covers.value, [song.sid]: dataUrl };
  } catch (e) { /* 封面取不到就显示占位，不打断播放 */ }
}

function isFav(sid) { return favorites.value.some(s => s.sid === sid); }
async function toggleFav(song) {
  /* fav:set 是整表替换：把收藏数组按 op 增删后整体发回（后端不收 {op, song} 的增量语义） */
  const adding = !isFav(song.sid);
  const next = adding ? [...favorites.value, song] : favorites.value.filter(s => s.sid !== song.sid);
  try {
    const resp = await $invoke('fav:set', { songs: next });
    if (resp.code === undefined || resp.code === 0) {
      await loadFavorites();
      await notify(adding ? '已收藏' : '已取消收藏');
    } else {
      await notify(resp.message || '收藏失败');
    }
  } catch (e) { await notify(String(e && e.message ? e.message : e)); }
}

onMounted(async () => {
  await window.__bridgeReady;
  await loadHot(null);
  await loadFavorites();
});
</script>

<template>
  <ion-app>
    <ion-header>
      <ion-toolbar>
        <ion-title>仓颉爱音乐 · Ionic</ion-title>
        <ion-buttons slot="end">
          <ion-button @click="tab === 'fav' ? loadFavorites() : loadHot(null)">
            <ion-icon slot="icon-only" :icon="searchOutline" v-if="false" />
            <ion-spinner name="dots" v-if="loading" />
          </ion-button>
        </ion-buttons>
      </ion-toolbar>
      <!-- 搜索页签下才有搜索条：移动端形态里搜索是页签而非弹层 -->
      <ion-toolbar v-if="tab === 'search'">
        <ion-searchbar v-model="searchQ" placeholder="歌名 / 歌手" @keyup.enter="doSearch" @ionClear="results = []" />
        <ion-buttons slot="end"><ion-button @click="doSearch">搜</ion-button></ion-buttons>
      </ion-toolbar>
    </ion-header>

    <ion-content>
      <ion-refresher slot="fixed" @ionRefresh="tab === 'fav' ? loadFavorites().then(() => null) : loadHot($event)">
        <ion-refresher-content />
      </ion-refresher>

      <div v-if="netError" class="err-note">{{ netError }}（后台接口可达性见桥日志 [music] 行）</div>

      <!-- 热门 / 搜索结果 / 收藏 共用同一种列表渲染 -->
      <ion-list v-if="(tab === 'hot' ? songs : tab === 'search' ? results : favorites).length">
        <ion-item v-for="s in (tab === 'hot' ? songs : tab === 'search' ? results : favorites)" :key="s.sid"
                  button detail @click="play(s)" :class="{ playing: current?.sid === s.sid }">
          <ion-thumbnail slot="start">
            <img v-if="covers[s.sid]" :src="covers[s.sid]" :alt="s.song" />
            <div v-else class="cover-ph"><ion-icon :icon="musicalNotesOutline" /></div>
          </ion-thumbnail>
          <ion-label>
            <h3>{{ s.song }}</h3>
            <p>{{ s.sing }}</p>
          </ion-label>
          <ion-icon slot="end" :icon="isFav(s.sid) ? heart : heartOutline"
                    :color="isFav(s.sid) ? 'danger' : 'medium'"
                    @click.stop="toggleFav(s)" />
        </ion-item>
      </ion-list>

      <div v-else-if="!loading && !netError" class="empty-note">
        {{ tab === 'search' ? '搜一首试试' : tab === 'fav' ? '还没有收藏' : '热门榜加载中…' }}
      </div>

      <!-- 歌词浮层：正在播放时点标题展开 -->
      <div v-if="lyricOpen" class="lyric-mask" @click="lyricOpen = false">
        <div class="lyric-cover" v-if="current && covers[current.sid]">
          <img :src="covers[current.sid]" alt="cover" />
        </div>
        <div class="lyric-box">
          <template v-if="lyricLines.length">
            <p v-for="(l, i) in lyricLines" :key="i" :class="{ on: i === activeLyric }">{{ l.text }}</p>
          </template>
          <p v-else class="off">暂无歌词</p>
        </div>
        <ion-note>{{ current ? current.song : '' }}</ion-note>
      </div>
    </ion-content>

    <!-- 底部播放条：移动端形态的固定元素 -->
    <ion-footer v-if="current" class="player-bar">
      <ion-toolbar>
        <div class="now" @click="lyricOpen = !lyricOpen">
          <ion-icon :icon="lyricOpen ? pauseOutline : musicalNotesOutline" />
          <span class="title">{{ current.song }} — {{ current.sing }}</span>
        </div>
        <ion-range :value="progress" :min="0" :max="1" :step="0.01" @ionInput="seek($event.detail.value)" />
        <div class="ctr">
          <span class="t">{{ posText }}</span>
          <ion-button fill="clear" @click="prevSong"><ion-icon slot="icon-only" :icon="playSkipBackOutline" /></ion-button>
          <ion-button fill="clear" class="pp" @click="toggle">
            <ion-icon slot="icon-only" :icon="playing ? pauseOutline : playOutline" />
          </ion-button>
          <ion-button fill="clear" @click="nextSong"><ion-icon slot="icon-only" :icon="playSkipForwardOutline" /></ion-button>
          <span class="t">{{ durText }}</span>
        </div>
      </ion-toolbar>
    </ion-footer>

    <ion-tab-bar slot="bottom" :selected-tab="tab" v-if="!current || true">
      <ion-tab-button tab="hot" :selected="tab === 'hot'" @click="tab = 'hot'">
        <ion-icon :icon="flameOutline" /><ion-label>热门</ion-label>
      </ion-tab-button>
      <ion-tab-button tab="search" :selected="tab === 'search'" @click="tab = 'search'">
        <ion-icon :icon="searchOutline" /><ion-label>搜索</ion-label>
      </ion-tab-button>
      <ion-tab-button tab="fav" :selected="tab === 'fav'" @click="tab = 'fav'; loadFavorites()">
        <ion-icon :icon="libraryOutline" /><ion-label>收藏</ion-label>
      </ion-tab-button>
    </ion-tab-bar>
  </ion-app>
</template>

<style scoped>
.err-note, .empty-note { padding: 24px 16px; text-align: center; color: var(--ion-color-medium); font-size: 14px; }
.err-note { color: var(--ion-color-danger); }
ion-item.playing { --background: rgba(80, 120, 255, 0.12); }
.cover-ph { width: 48px; height: 48px; display: flex; align-items: center; justify-content: center;
            background: var(--ion-color-light-shade); border-radius: 6px; }
.player-bar ion-toolbar { --padding-start: 12px; --padding-end: 12px; padding-bottom: 2px; }
.now { display: flex; align-items: center; gap: 8px; padding: 6px 2px; cursor: pointer; }
.now .title { font-size: 14px; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
.ctr { display: flex; align-items: center; justify-content: center; gap: 4px; margin-top: -12px; }
.ctr .t { font-size: 11px; color: var(--ion-color-medium); min-width: 34px; text-align: center; }
.pp ion-icon { font-size: 30px; }
.lyric-mask { position: fixed; inset: 0; background: rgba(8, 8, 14, 0.94); z-index: 99;
              display: flex; flex-direction: column; align-items: center; padding: 40px 20px; overflow: hidden; }
.lyric-cover img { width: 180px; height: 180px; border-radius: 12px; object-fit: cover; }
.lyric-box { flex: 1; overflow: auto; width: 100%; text-align: center; padding: 24px 0; }
.lyric-box p { color: var(--ion-color-medium); margin: 10px 0; transition: color .25s; }
.lyric-box p.on { color: #fff; font-weight: 600; }
.lyric-box p.off { color: var(--ion-color-medium); }
</style>
