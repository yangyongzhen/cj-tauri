<script setup>
/* Ionic Vue 音乐播放器（移动端形态）：热门 / 搜索 / 收藏 / 设置 四页签 + 底部播放条 + 歌词页。
   与 music-next 共用同一套仓颉后端命令（music:hot / music:search / music:lyric / music:image /
   fav:get / fav:set / music:quit），前端只经 window.__CJ_TAURI__ 的 invoke 说话。 */
import { ref, computed, onMounted, watch } from 'vue';
import {
  IonApp, IonContent, IonHeader, IonToolbar, IonTitle, IonFooter, IonTabBar, IonTabButton,
  IonIcon, IonList, IonItem, IonThumbnail, IonLabel, IonSearchbar, IonButton, IonButtons,
  IonRange, IonSpinner, IonNote, IonRefresher, IonRefresherContent, IonBadge,
  toastController, alertController
} from '@ionic/vue';
import { heart, heartOutline, searchOutline, flameOutline, libraryOutline, settingsOutline,
         playOutline, pauseOutline, playSkipForwardOutline, playSkipBackOutline,
         musicalNotesOutline, trashOutline, informationCircleOutline, personCircleOutline,
         closeOutline } from 'ionicons/icons';

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
const appVersion = ref('…');

async function notify(msg) {
  const t = await toastController.create({ message: msg, duration: 1800, position: 'top' });
  await t.present();
}

/* 后台返回 {code, message, data}：code!=0 是业务失败（HTTP 仍是 200，仓颉层不抛） */
function unwrapSongs(resp) {
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
    const resp = await $invoke('music:hot', { start: 0, count: 30 });
    songs.value = unwrapSongs(resp);
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
    results.value = unwrapSongs(resp);
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

async function loadVersion() {
  try {
    const v = await $invoke('system:version', {});
    appVersion.value = typeof v === 'string' ? v : (v.version || JSON.stringify(v));
  } catch (e) { appVersion.value = '未知'; }
}

/* ---------------- 播放器 ---------------- */
const player = ref(null);
const current = ref(null);
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

function ensurePlayer() {
  if (player.value) return;
  player.value = new Audio();
  player.value.addEventListener('timeupdate', () => { position.value = player.value.currentTime; });
  player.value.addEventListener('durationchange', () => { duration.value = player.value.duration; });
  player.value.addEventListener('ended', () => { playing.value = false; nextSong(); });
  player.value.addEventListener('error', () => { playing.value = false; notify('这条播放地址取不到音频'); });
}

async function play(song) {
  ensurePlayer();
  current.value = song;
  position.value = 0; duration.value = 0;
  player.value.src = song.url;
  player.value.play().then(() => { playing.value = true; }).catch(() => { playing.value = false; });
  loadLyric(song.sid);
  loadCover(song, 500);   // 正在播放的要大图
}

function toggle() {
  if (!player.value || !current.value) return;
  if (playing.value) { player.value.pause(); playing.value = false; }
  else { player.value.play().then(() => { playing.value = true; }); }
}

function seek(ratio) {
  if (player.value && duration.value > 0) player.value.currentTime = ratio * duration.value;
}

const currentList = computed(() => {
  if (tab.value === 'search') return results.value;
  if (tab.value === 'fav') return favorites.value;
  return songs.value;
});

function step(delta) {
  const list = currentList.value.length ? currentList.value : songs.value;
  const i = list.findIndex(s => s.sid === current.value?.sid);
  const n = list[i + delta];
  if (n) play(n);
}
const nextSong = () => step(1);
const prevSong = () => step(-1);

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
async function loadCover(song, size) {
  if (!song.cover) return;
  const key = `${song.sid}@${size}`;
  if (covers.value[key]) return;
  try {
    const dataUrl = await $invoke('music:image', { url: song.cover, size });
    covers.value = { ...covers.value, [key]: dataUrl };
  } catch (e) { /* 封面取不到就显示占位，不打断播放 */ }
}
function coverOf(song, size) { return covers.value[`${song.sid}@${size}`]; }

function isFav(sid) { return favorites.value.some(s => s.sid === sid); }
async function toggleFav(song) {
  /* fav:set 是整表替换：把收藏数组按 op 增删后整体发回（后端不收 {op, song} 的增量语义） */
  const adding = !isFav(song.sid);
  const next = adding ? [...favorites.value, song] : favorites.value.filter(s => s.sid !== song.sid);
  try {
    const resp = await $invoke('fav:set', { songs: next });
    if (resp.code === undefined || resp.code === 0) {
      await loadFavorites();
      await notify(adding ? '已加入收藏' : '已取消收藏');
    } else {
      await notify(resp.message || '收藏失败');
    }
  } catch (e) { await notify(String(e && e.message ? e.message : e)); }
}

async function clearFavorites() {
  const alert = await alertController.create({
    header: '清空收藏',
    message: `将删除全部 ${favorites.value.length} 首收藏，且不可恢复。`,
    buttons: [
      { text: '取消', role: 'cancel' },
      {
        text: '清空', role: 'destructive',
        handler: async () => {
          try {
            await $invoke('fav:set', { songs: [] });
            await loadFavorites();
            await notify('收藏已清空');
          } catch (e) { await notify(String(e && e.message ? e.message : e)); }
        }
      }
    ]
  });
  await alert.present();
}

/* 列表缩略图懒加载：进入页签时给可见歌曲取 200px 封面（宿主侧带 Referer） */
watch(tab, (t) => {
  if (t === 'fav') loadFavorites();
  const list = t === 'search' ? results.value : t === 'hot' ? songs.value : favorites.value;
  list.slice(0, 12).forEach(s => loadCover(s, 200));
});
watch(songs, (l) => l.slice(0, 12).forEach(s => loadCover(s, 200)));
watch(results, (l) => l.slice(0, 12).forEach(s => loadCover(s, 200)));

onMounted(async () => {
  await window.__bridgeReady;
  await loadVersion();
  await loadHot(null);
  await loadFavorites();
});
</script>

<template>
  <ion-app>
    <ion-header class="ion-no-border">
      <ion-toolbar>
        <ion-title class="app-title">
          <ion-icon :icon="musicalNotesOutline" class="logo" />
          仓颉爱音乐
        </ion-title>
        <ion-buttons slot="end">
          <ion-spinner v-if="loading" name="crescent" />
        </ion-buttons>
      </ion-toolbar>
      <!-- 搜索页签下才有搜索条：移动端形态里搜索是页签而非弹层 -->
      <ion-toolbar v-if="tab === 'search'">
        <ion-searchbar v-model="searchQ" placeholder="歌名 / 歌手" @keyup.enter="doSearch"
                       @ionClear="results = []" show-clear-button="focus" />
        <ion-buttons slot="end"><ion-button @click="doSearch" class="go">搜索</ion-button></ion-buttons>
      </ion-toolbar>
    </ion-header>

    <ion-content :fullscreen="true">
      <ion-refresher slot="fixed" @ionRefresh="tab === 'fav' ? loadFavorites().then(() => $event.target.complete()) : loadHot($event)">
        <ion-refresher-content />
      </ion-refresher>

      <div v-if="netError" class="err-note">
        <ion-icon :icon="informationCircleOutline" />
        <span>{{ netError }}</span>
        <span class="sub">后台接口可达性见桥日志 [music] 行；用 CJ_MUSIC_API 可指向自建后端</span>
      </div>

      <!-- 热门 / 搜索结果 / 收藏 共用同一种列表渲染 -->
      <div v-if="currentList.length" class="list-wrap">
        <div v-if="tab === 'search' && searchLabel" class="sec-label">{{ searchLabel }}</div>
        <div v-if="tab === 'hot'" class="sec-label">热歌榜 · {{ songs.length }} 首</div>
        <div v-if="tab === 'fav'" class="sec-label">我的收藏 · {{ favorites.length }} 首</div>
        <div v-for="s in currentList" :key="s.sid" class="song-row" :class="{ on: current?.sid === s.sid }"
             @click="play(s)">
          <div class="cover">
            <img v-if="coverOf(s, 200)" :src="coverOf(s, 200)" :alt="s.song" />
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

      <div v-else-if="!loading && !netError" class="empty-note">
        {{ tab === 'search' ? '搜一首试试' : tab === 'fav' ? '还没有收藏，去热门页点心形收一首' : '加载中…' }}
      </div>

      <!-- 设置页：版本 / 收藏管理 / 关于 -->
      <div v-if="tab === 'settings'">
        <div class="settings-note">通用</div>
        <ion-list inset>
          <ion-item detail="false">
            <ion-icon slot="start" :icon="personCircleOutline" color="primary" />
            <ion-label>
              <h2>框架版本</h2>
              <p>{{ appVersion }}</p>
            </ion-label>
          </ion-item>
          <ion-item detail="false">
            <ion-icon slot="start" :icon="musicalNotesOutline" color="tertiary" />
            <ion-label>
              <h2>音乐数据</h2>
              <p>来自在线音乐接口（CJ_MUSIC_API 可指向自建后端）</p>
            </ion-label>
          </ion-item>
        </ion-list>

        <div class="settings-note">收藏</div>
        <ion-list inset>
          <ion-item detail="false">
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
          <ion-item detail="false">
            <ion-icon slot="start" :icon="informationCircleOutline" color="medium" />
            <ion-label class="ion-text-wrap">
              <h2>cj-tauri · Ionic 示例</h2>
              <p>仓颉静态编译后端 + 系统 WebView 前端；本页用 @ionic/vue 构建，
                 经统一 IPC 桥（invoke / listen / emit）与后端通信，命令走能力白名单。
                 歌词 / 封面 / 收藏等能力见 examples/music-next 的 README。</p>
            </ion-label>
          </ion-item>
        </ion-list>
      </div>

      <!-- 歌词浮层：点播放条展开 -->
      <transition name="lyric">
        <div v-if="lyricOpen" class="lyric-mask">
          <div class="lyric-head">
            <ion-button fill="clear" @click="lyricOpen = false"><ion-icon slot="icon-only" :icon="closeOutline" /></ion-button>
            <span>正在播放</span>
          </div>
          <div class="lyric-cover" v-if="current">
            <img v-if="coverOf(current, 500)" :src="coverOf(current, 500)" alt="cover" />
            <ion-icon v-else :icon="musicalNotesOutline" />
          </div>
          <div class="lyric-title">{{ current ? current.song : '' }}</div>
          <div class="lyric-artist">{{ current ? current.sing : '' }}</div>
          <div class="lyric-box" ref="lyricBox">
            <template v-if="lyricLines.length">
              <p v-for="(l, i) in lyricLines" :key="i" :class="{ on: i === activeLyric }">{{ l.text }}</p>
            </template>
            <p v-else class="off">暂无歌词</p>
          </div>
        </div>
      </transition>
    </ion-content>

    <!-- 底部播放条 -->
    <ion-footer v-if="current" class="ion-no-border player-bar">
      <ion-toolbar>
        <div class="now" @click="lyricOpen = !lyricOpen">
          <div class="mini-cover">
            <img v-if="coverOf(current, 200)" :src="coverOf(current, 200)" alt="" />
            <ion-icon v-else :icon="musicalNotesOutline" />
          </div>
          <div class="meta">
            <div class="name">{{ current.song }}</div>
            <div class="artist">{{ current.sing }}</div>
          </div>
          <ion-button fill="clear" size="small" @click.stop="prevSong">
            <ion-icon slot="icon-only" :icon="playSkipBackOutline" />
          </ion-button>
          <ion-button fill="clear" class="pp" @click.stop="toggle">
            <ion-icon slot="icon-only" :icon="playing ? pauseOutline : playOutline" />
          </ion-button>
          <ion-button fill="clear" size="small" @click.stop="nextSong">
            <ion-icon slot="icon-only" :icon="playSkipForwardOutline" />
          </ion-button>
        </div>
        <ion-range class="seek" :value="progress" :min="0" :max="1" :step="0.01"
                   @ionInput="seek($event.detail.value)" />
        <div class="times"><span>{{ posText }}</span><span>{{ durText }}</span></div>
      </ion-toolbar>
    </ion-footer>

    <ion-tab-bar class="ion-no-border">
      <ion-tab-button tab="hot" :selected="tab === 'hot'" @click="tab = 'hot'">
        <ion-icon :icon="flameOutline" /><ion-label>热门</ion-label>
      </ion-tab-button>
      <ion-tab-button tab="search" :selected="tab === 'search'" @click="tab = 'search'">
        <ion-icon :icon="searchOutline" /><ion-label>搜索</ion-label>
      </ion-tab-button>
      <ion-tab-button tab="fav" :selected="tab === 'fav'" @click="tab = 'fav'">
        <ion-icon :icon="libraryOutline" />
        <ion-label>收藏</ion-label>
        <ion-badge v-if="favorites.length" color="danger">{{ favorites.length }}</ion-badge>
      </ion-tab-button>
      <ion-tab-button tab="settings" :selected="tab === 'settings'" @click="tab = 'settings'">
        <ion-icon :icon="settingsOutline" /><ion-label>设置</ion-label>
      </ion-tab-button>
    </ion-tab-bar>
  </ion-app>
</template>

<style scoped>
.app-title { font-weight: 700; letter-spacing: .5px; display: flex; align-items: center; gap: 8px; }
.app-title .logo { color: var(--ion-color-primary); font-size: 22px; }
.go { font-weight: 600; }

.sec-label { padding: 14px 16px 6px; font-size: 13px; color: var(--ion-color-medium);
             letter-spacing: 1px; }
.list-wrap { padding-bottom: 16px; }
.song-row { display: flex; align-items: center; gap: 12px; padding: 10px 16px; cursor: pointer;
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

/* 歌词浮层 */
.lyric-mask { position: fixed; inset: 0; z-index: 99;
              background: linear-gradient(180deg, #10101c 0%, #17172a 60%, #10101c 100%);
              display: flex; flex-direction: column; align-items: center; padding: 8px 24px 32px; }
.lyric-head { width: 100%; display: flex; align-items: center; gap: 8px;
              color: var(--ion-color-medium); font-size: 13px; letter-spacing: 2px; }
.lyric-cover { width: 200px; height: 200px; border-radius: 16px; overflow: hidden; margin: 12px 0;
               box-shadow: 0 12px 40px rgba(0, 0, 0, 0.6); display: flex; align-items: center;
               justify-content: center; background: rgba(128, 128, 160, 0.1);
               color: var(--ion-color-medium); font-size: 48px; }
.lyric-cover img { width: 100%; height: 100%; object-fit: cover; }
.lyric-title { font-size: 20px; font-weight: 700; margin-top: 8px; }
.lyric-artist { font-size: 13px; color: var(--ion-color-medium); margin-top: 4px; }
.lyric-box { flex: 1; overflow: auto; width: 100%; text-align: center; padding: 20px 0; }
.lyric-box p { color: var(--ion-color-medium); margin: 12px 0; transition: all .25s; font-size: 14px; }
.lyric-box p.on { color: #fff; font-weight: 700; font-size: 16px; }
.lyric-box p.off { color: var(--ion-color-medium); }
.lyric-enter-active, .lyric-leave-active { transition: opacity .22s, transform .22s; }
.lyric-enter-from, .lyric-leave-to { opacity: 0; transform: translateY(24px); }

/* 设置页 */
.settings-note { padding: 14px 16px 4px; font-size: 13px; color: var(--ion-color-medium);
                 letter-spacing: 1px; }
</style>
