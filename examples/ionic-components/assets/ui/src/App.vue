<script setup>
/* Ionic 组件 Gallery（信息架构参考 ionic-team/ionic-conference-app）
 * 4 个 tab：Schedule / Speakers / Components / About + 全局 drawer 菜单。
 * 纯前端静态 demo 数据（无后端依赖）；后端只留 system:version（About 页显示桥通了）。
 * 弹层全走稳健写法：alert / actionSheet / toast 用 controller（收按钮数组），
 * modal 用声明式 <ion-modal>（:is-open 切换）、popover 用声明式 <ion-popover>（trigger 锚定）
 * ——都不依赖运行时模板编译或 h() 渲染，单文件 SFC 里最不容易翻车。 */
import { ref, computed, onMounted } from 'vue';
import {
  IonApp, IonMenu, IonMenuToggle, IonContent, IonHeader, IonToolbar, IonTitle,
  IonButtons, IonBackButton, IonMenuButton, IonTabBar, IonTabButton, IonIcon,
  IonSearchbar, IonButton, IonBadge, IonCard, IonCardHeader, IonCardTitle,
  IonCardSubtitle, IonCardContent, IonItem, IonItemGroup, IonItemDivider,
  IonItemSliding, IonItemOptions, IonItemOption, IonList, IonListHeader, IonLabel,
  IonNote, IonText, IonAvatar, IonChip, IonToggle, IonRadio, IonRadioGroup,
  IonRange, IonProgressBar, IonSkeletonText, IonSegment,
  IonSegmentButton, IonFab, IonFabButton, IonFabList, IonSelect, IonSelectOption,
  IonDatetime, IonPopover, IonRippleEffect, IonModal,
  alertController, actionSheetController, toastController
} from '@ionic/vue';
import {
  calendarOutline, peopleOutline, appsOutline, informationCircleOutline,
  star, moonOutline, logoTwitter, logoGithub, logoInstagram, logoVimeo,
  logoFacebook, callOutline, mailOutline, shareOutline, timeOutline, ellipsisVertical,
  locationOutline, checkmarkOutline, heartOutline, personCircleOutline
} from 'ionicons/icons';

const $invoke = (...a) => window.__CJ_TAURI__.invoke(...a);

/* ---------------- 静态 demo 数据（实体参考 conference data.json） ---------------- */
const TRACKS = [
  { name: 'Ionic', color: 'ionic' },
  { name: 'Vue', color: 'vue' },
  { name: 'Tooling', color: 'tooling' },
  { name: 'Design', color: 'design' },
  { name: 'Workshop', color: 'workshop' },
  { name: 'Food', color: 'food' }
];
const trackColor = (n) => (TRACKS.find(t => t.name === n) || { color: 'ionic' }).color;

const SPEAKERS = [
  { id: 1, name: 'Ted Turtle',   title: '首席架构师',   about: '十年跨端经验，专注大仓颉应用的性能与工程化。',  twitter: '@tedturtle', github: 'tedturtle', location: '上海' },
  { id: 2, name: 'Rachel Rabbit', title: '设计负责人',  about: '把 Ionic 的设计语言落到每一个像素。',            twitter: '@rrabbit',   github: 'rrabbit',   location: '北京' },
  { id: 3, name: 'Mike Mouse',   title: '工具链工程师', about: '打包、签名、CI 一条龙，让构建稳定可复现。',      twitter: '@mmouse',    github: 'mmouse',    location: '深圳' },
  { id: 4, name: 'Doris Deer',   title: '前端专家',     about: 'Vue 3 组合式 API 与响应式的边界与误区。',        twitter: '@ddeer',     github: 'ddeer',     location: '杭州' },
  { id: 5, name: 'Katie Kangaroo', title: '性能工程师', about: '首屏、内存、渲染，把 60fps 当底线。',            twitter: '@kkangaroo', github: 'kkangaroo', location: '成都' },
  { id: 6, name: 'Oscar Octopus', title: '开源布道者',  about: '开源社区的搬运工，翻译与文档都来找我。',          twitter: '@ooctopus',  github: 'ooctopus',  location: '广州' }
];

const SCHEDULE = [
  { time: '9:15', sessions: [
    { id: 's1', name: 'Opening Keynote', location: 'Hall 1', timeStart: '09:15', timeEnd: '09:45', description: '大会开幕：为什么把跨端框架写进一门新的系统语言。', speakers: ['Ted Turtle'], tracks: ['Ionic'] },
    { id: 's2', name: '设计系统落地',     location: 'Hall 2', timeStart: '09:15', timeEnd: '09:45', description: '把一套 Design Token 同时喂给桌面与移动端。',       speakers: ['Rachel Rabbit'], tracks: ['Design'] }
  ]},
  { time: '10:00', sessions: [
    { id: 's3', name: '构建与签名流水线', location: 'Room A', timeStart: '10:00', timeEnd: '10:45', description: '从清单到多端产物的自动化，签名与证书不入库。',   speakers: ['Mike Mouse'], tracks: ['Tooling'] },
    { id: 's4', name: '响应式深蹲',       location: 'Room B', timeStart: '10:00', timeEnd: '10:45', description: 'ref / computed / watch 的边界与常见误区。',       speakers: ['Doris Deer'], tracks: ['Vue'] }
  ]},
  { time: '11:00', sessions: [
    { id: 's5', name: '60fps 实战',       location: 'Hall 1', timeStart: '11:00', timeEnd: '11:45', description: '长列表、图片懒加载与渲染合批。',                 speakers: ['Katie Kangaroo'], tracks: ['Ionic', 'Workshop'] }
  ]},
  { time: '12:30', sessions: [
    { id: 's6', name: '午餐 & 交流',      location: 'Cafe',   timeStart: '12:30', timeEnd: '13:30', description: '边吃边聊，主题不限。',                           speakers: [], tracks: ['Food'] }
  ]},
  { time: '14:00', sessions: [
    { id: 's7', name: '桥接层对比',       location: 'Hall 2', timeStart: '14:00', timeEnd: '14:45', description: 'JS 调原生：环节、语言、ABI 次数怎么算。',        speakers: ['Oscar Octopus'], tracks: ['Ionic'] }
  ]},
  { time: '15:30', sessions: [
    { id: 's8', name: '组件拆解工作坊',   location: 'Room A', timeStart: '15:30', timeEnd: '16:15', description: '现场拆一个复合组件，从 API 到无障碍。',          speakers: ['Rachel Rabbit', 'Doris Deer'], tracks: ['Workshop', 'Design'] }
  ]}
];

const VIEWS = [
  { key: 'schedule', title: 'Schedule', icon: calendarOutline, color: 'ionic' },
  { key: 'speakers', title: 'Speakers', icon: peopleOutline, color: 'vue' },
  { key: 'components', title: 'Components', icon: appsOutline, color: 'tooling' },
  { key: 'about', title: 'About', icon: informationCircleOutline, color: 'design' }
];

/* ---------------- 状态 ---------------- */
const tab = ref('schedule');
const dark = ref(false);
const appVersion = ref('…');
const searchQ = ref('');
const trackFilter = ref([]);
const favorites = ref([]);
const detailSession = ref(null);
const detailSpeaker = ref(null);
const city = ref('Shanghai');
const confDate = ref('2047-05-17');
const galleryModalOpen = ref(false);
const demoToggle = ref(true);
const demoToggle2 = ref(false);
const demoRadio = ref('vue');
const demoRange = ref(42);
const demoSeg = ref('ios');
const demoSelect = ref('vue');

/* ---------------- 计算属性 ---------------- */
const pageTitle = computed(() => {
  if (detailSession.value) return 'Session';
  if (detailSpeaker.value) return 'Speaker';
  const v = VIEWS.find(x => x.key === tab.value);
  return v ? v.title : 'Components';
});
const pageIcon = computed(() => {
  if (detailSession.value) return timeOutline;
  if (detailSpeaker.value) return peopleOutline;
  const v = VIEWS.find(x => x.key === tab.value);
  return v ? v.icon : appsOutline;
});
const favSet = computed(() => new Set(favorites.value));
const sessionsGrouped = computed(() => {
  const q = (searchQ.value || '').toLowerCase().trim();
  return SCHEDULE.map(g => {
    const sessions = g.sessions.filter(s => {
      if (trackFilter.value.length && !s.tracks.some(t => trackFilter.value.includes(t))) return false;
      if (q) {
        const hay = (s.name + ' ' + s.location + ' ' + s.speakers.join(' ')).toLowerCase();
        if (!hay.includes(q)) return false;
      }
      return true;
    });
    return { time: g.time, sessions };
  }).filter(g => g.sessions.length);
});
const speakersFiltered = computed(() => {
  const q = (searchQ.value || '').toLowerCase().trim();
  if (!q) return SPEAKERS;
  return SPEAKERS.filter(s => (s.name + ' ' + s.title + ' ' + s.location).toLowerCase().includes(q));
});

/* ---------------- 工具 / 事件 ---------------- */
function initials(name) {
  const p = name.split(' ');
  return ((p[0] || '?')[0] + (p[1] ? p[1][0] : '')).toUpperCase();
}
const GRADS = [
  'linear-gradient(135deg,#3880ff,#3dc2ff)', 'linear-gradient(135deg,#69bb7b,#3bc7c4)',
  'linear-gradient(135deg,#fe4c52,#fd8b2d)', 'linear-gradient(135deg,#b16be3,#6600cc)',
  'linear-gradient(135deg,#34495e,#3880ff)', 'linear-gradient(135deg,#fed035,#fd8b2d)'
];
function gradOf(id) { return GRADS[(id - 1) % GRADS.length]; }

async function toast(msg) {
  const t = await toastController.create({ message: msg, duration: 1600, position: 'top' });
  await t.present();
}
function setTab(t) {
  detailSession.value = null;
  detailSpeaker.value = null;
  searchQ.value = '';
  tab.value = t;
}
function toggleFav(id) {
  const i = favorites.value.indexOf(id);
  if (i >= 0) favorites.value.splice(i, 1); else favorites.value.push(id);
}
function toggleTrack(t) {
  const i = trackFilter.value.indexOf(t);
  if (i >= 0) trackFilter.value.splice(i, 1); else trackFilter.value.push(t);
}
async function confirmFav(id) {
  const a = await alertController.create({
    header: '取消收藏？', message: '要把这场从收藏夹移除吗？',
    buttons: [
      { text: '取消', role: 'cancel' },
      { text: '移除', role: 'destructive', handler: () => { toggleFav(id); toast('已移除收藏'); } }
    ]
  });
  if (await a.present()) { /* shown */ }
}
function openSession(s) { detailSession.value = s; }
function openSpeaker(sp) { detailSpeaker.value = sp; }
function openGallery() { galleryModalOpen.value = true; }

async function presentShare() {
  const a = await actionSheetController.create({
    header: '分享这场 Session',
    buttons: [
      { icon: 'logoTwitter', text: 'Twitter', handler: () => toast('已分享到 Twitter') },
      { icon: 'logoVimeo', text: 'Vimeo', handler: () => toast('已分享到 Vimeo') },
      { icon: 'logoFacebook', text: 'Facebook', handler: () => toast('已分享到 Facebook') },
      { icon: 'shareOutline', text: '复制链接', handler: () => toast('链接已复制') },
      { text: '取消', role: 'cancel' }
    ]
  });
  if (await a.present()) { /* shown */ }
}
async function presentContact() {
  const a = await actionSheetController.create({
    header: '联系讲者',
    buttons: [
      { icon: 'callOutline', text: '拨打电话', handler: () => toast('拨号（demo 不真拨）') },
      { icon: 'mailOutline', text: '发送邮件', handler: () => toast('打开邮件（demo 不发）') },
      { icon: 'shareOutline', text: '分享名片', handler: () => toast('名片已分享') },
      { text: '取消', role: 'cancel' }
    ]
  });
  if (await a.present()) { /* shown */ }
}
function aboutMenuAction(label) { toast(label + '（demo 占位）'); }

async function loadVersion() {
  try {
    const v = await $invoke('system:version', {});
    appVersion.value = typeof v === 'string' ? v : (v.version || '');
  } catch (e) { appVersion.value = ''; }
}
onMounted(() => { window.__bridgeReady.then(() => loadVersion()); });
</script>

<template>
  <!-- 全局 drawer 菜单（参考 conference 的 Menu.vue：分组 + 选中态高亮 + 深色开关） -->
  <ion-menu content-id="main-content" :class="dark ? 'ion-palette-dark' : ''">
    <ion-header>
      <ion-toolbar>
        <ion-title class="brand">Ionic Gallery</ion-title>
      </ion-toolbar>
    </ion-header>
    <ion-content>
      <ion-list>
        <ion-list-header><ion-label>导航</ion-label></ion-list-header>
        <ion-menu-toggle v-for="v in VIEWS" :key="v.key">
          <ion-item button :color="tab === v.key ? v.color : undefined" @click="setTab(v.key)">
            <ion-icon slot="start" :icon="v.icon"></ion-icon>
            <ion-label>{{ v.title }}</ion-label>
            <ion-badge slot="end" v-if="v.key === 'schedule' && favorites.length">{{ favorites.length }}</ion-badge>
          </ion-item>
        </ion-menu-toggle>
      </ion-list>
      <ion-list>
        <ion-list-header><ion-label>外观</ion-label></ion-list-header>
        <ion-item button>
          <ion-icon slot="start" :icon="moonOutline"></ion-icon>
          <ion-label>深色模式</ion-label>
          <ion-toggle slot="end" :modelValue="dark" @ionChange="dark = $event.detail.checked"></ion-toggle>
        </ion-item>
      </ion-list>
    </ion-content>
  </ion-menu>

  <ion-app :class="dark ? 'ion-palette-dark' : ''">
    <ion-header>
      <ion-toolbar>
        <ion-menu-button slot="start"></ion-menu-button>
        <ion-buttons v-if="detailSession || detailSpeaker" slot="start">
          <ion-back-button @click="detailSession = null; detailSpeaker = null"></ion-back-button>
        </ion-buttons>
        <ion-icon :icon="pageIcon" class="title-icon"></ion-icon>
        <ion-title>{{ pageTitle }}</ion-title>
        <ion-buttons v-if="tab === 'about' && !detailSession && !detailSpeaker" slot="end">
          <ion-button id="about-more-btn" fill="clear" @click="presentShare">
            <ion-icon slot="icon-only" :icon="ellipsisVertical"></ion-icon>
          </ion-button>
        </ion-buttons>
      </ion-toolbar>
    </ion-header>

    <ion-content id="main-content" :class="dark ? 'ion-palette-dark' : ''">
      <!-- 声明式 popover：about 页右上角 ⋯ 菜单（trigger 锚定，内容是内联模板） -->
      <ion-popover trigger="about-more-btn">
        <template>
          <ion-content class="pop">
            <ion-list>
              <ion-item button @click="aboutMenuAction('文档')"><ion-label>文档</ion-label></ion-item>
              <ion-item button @click="aboutMenuAction('示例源码')"><ion-label>示例源码</ion-label></ion-item>
              <ion-item button @click="aboutMenuAction('关于 cj-tauri')"><ion-label>关于 cj-tauri</ion-label></ion-item>
            </ion-list>
          </ion-content>
        </template>
      </ion-popover>

      <!-- ============ Schedule：时间分组 + 轨道过滤 + 搜索 + 收藏 ============ -->
      <div v-if="tab === 'schedule' && !detailSession" class="page">
        <ion-searchbar :value="searchQ" placeholder="搜索日程 / 讲者 / 场地"
                       @ionInput="searchQ = $event.detail.value"></ion-searchbar>
        <div class="chip-row">
          <ion-chip v-for="t in TRACKS" :key="t.name"
                    :color="trackFilter.includes(t.name) ? trackColor(t.name) : undefined"
                    @click="toggleTrack(t.name)">
            <ion-icon slot="icon" :icon="trackFilter.includes(t.name) ? checkmarkOutline : undefined"></ion-icon>
            {{ t.name }}
          </ion-chip>
        </div>
        <div v-if="!sessionsGrouped.length" class="empty"><ion-note>没有匹配的 Session</ion-note></div>
        <ion-list v-for="g in sessionsGrouped" :key="g.time">
          <ion-item-divider sticky>
            <ion-note>{{ g.time }}</ion-note>
          </ion-item-divider>
          <ion-item v-for="s in g.sessions" :key="s.id" button class="session"
                    :data-track="trackColor(s.tracks[0] || 'Ionic')" @click="openSession(s)">
            <ion-icon v-if="favSet.has(s.id)" slot="start" :icon="star" color="favorite"></ion-icon>
            <ion-label>
              <h2>{{ s.name }}</h2>
              <p>{{ s.tracks.join(' / ') }} · {{ s.location }} · {{ s.timeStart }}</p>
            </ion-label>
            <ion-icon slot="end" :icon="heartOutline" :color="favSet.has(s.id) ? 'favorite' : 'medium'"></ion-icon>
          </ion-item>
        </ion-list>
      </div>

      <!-- ============ Session 详情 ============ -->
      <div v-if="detailSession" class="page">
        <ion-list>
          <ion-item-group>
            <ion-item>
              <ion-label>
                <h2>{{ detailSession.name }}</h2>
                <p><ion-icon :icon="timeOutline" class="inline-ic"></ion-icon>{{ detailSession.timeStart }} – {{ detailSession.timeEnd }}</p>
                <p><ion-icon :icon="locationOutline" class="inline-ic"></ion-icon>{{ detailSession.location }}</p>
              </ion-label>
            </ion-item>
          </ion-item-group>
        </ion-list>
        <div class="chip-row">
          <ion-chip v-for="t in detailSession.tracks" :key="t" :color="trackColor(t)">{{ t }}</ion-chip>
        </div>
        <ion-list>
          <ion-item-group>
            <ion-item-divider><ion-note>简介</ion-note></ion-item-divider>
            <ion-item><ion-label class="desc">{{ detailSession.description }}</ion-label></ion-item>
          </ion-item-group>
        </ion-list>
        <ion-list v-if="detailSession.speakers.length">
          <ion-item-group>
            <ion-item-divider><ion-note>讲者</ion-note></ion-item-divider>
            <ion-item v-for="nm in detailSession.speakers" :key="nm" button @click="openSpeaker(SPEAKERS.find(s => s.name === nm))">
              <ion-avatar slot="start" class="mini-av">
                <div class="ini" :style="{ background: gradOf(SPEAKERS.find(s => s.name === nm).id) }">{{ initials(nm) }}</div>
              </ion-avatar>
              <ion-label>{{ nm }}</ion-label>
            </ion-item>
            <ion-item v-if="!detailSession.speakers.length"><ion-note>（无讲者，如午餐环节）</ion-note></ion-item>
          </ion-item-group>
        </ion-list>
        <div class="actions">
          <ion-button fill="outline" :color="favSet.has(detailSession.id) ? 'favorite' : 'medium'"
                      @click="favSet.has(detailSession.id) ? confirmFav(detailSession.id) : (toggleFav(detailSession.id), toast('已加入收藏'))">
            <ion-icon slot="icon-only" :icon="favSet.has(detailSession.id) ? star : heartOutline"></ion-icon>
          </ion-button>
          <ion-button @click="presentShare">
            <ion-icon slot="start" :icon="shareOutline"></ion-icon>分享
          </ion-button>
        </div>
      </div>

      <!-- ============ Speakers：搜索 + 列表 + 详情 ============ -->
      <div v-if="tab === 'speakers' && !detailSpeaker" class="page">
        <ion-searchbar :value="searchQ" placeholder="搜索讲者 / 职位 / 城市"
                       @ionInput="searchQ = $event.detail.value"></ion-searchbar>
        <ion-list>
          <ion-item-group>
            <ion-item v-for="sp in speakersFiltered" :key="sp.id" button @click="openSpeaker(sp)">
              <ion-avatar slot="start">
                <div class="ini" :style="{ background: gradOf(sp.id) }">{{ initials(sp.name) }}</div>
              </ion-avatar>
              <ion-label>
                <h2>{{ sp.name }}</h2>
                <p>{{ sp.title }} · {{ sp.location }}</p>
              </ion-label>
            </ion-item>
          </ion-item-group>
        </ion-list>
        <div v-if="!speakersFiltered.length" class="empty"><ion-note>没有匹配的讲者</ion-note></div>
      </div>

      <!-- ============ Speaker 详情：头像 + 社交 chip + actionSheet 联系 ============ -->
      <div v-if="detailSpeaker" class="page spk-detail">
        <div class="spk-hero">
          <div class="spk-av" :style="{ background: gradOf(detailSpeaker.id) }">{{ initials(detailSpeaker.name) }}</div>
          <h1 class="spk-name">{{ detailSpeaker.name }}</h1>
          <p class="spk-title">{{ detailSpeaker.title }} · {{ detailSpeaker.location }}</p>
        </div>
        <div class="chip-row">
          <ion-chip color="twitter" @click="toast('打开 ' + detailSpeaker.twitter)">
            <ion-icon slot="icon" :icon="logoTwitter"></ion-icon>{{ detailSpeaker.twitter }}
          </ion-chip>
          <ion-chip color="github" @click="toast('打开 github.com/' + detailSpeaker.github)">
            <ion-icon slot="icon" :icon="logoGithub"></ion-icon>{{ detailSpeaker.github }}
          </ion-chip>
        </div>
        <ion-list>
          <ion-item-group>
            <ion-item-divider><ion-note>关于</ion-note></ion-item-divider>
            <ion-item><ion-label class="desc">{{ detailSpeaker.about }}</ion-label></ion-item>
          </ion-item-group>
        </ion-list>
        <div class="actions">
          <ion-button @click="presentContact">
            <ion-icon slot="start" :icon="callOutline"></ion-icon>联系
          </ion-button>
          <ion-button fill="outline" @click="toast('名片已分享')">
            <ion-icon slot="start" :icon="shareOutline"></ion-icon>分享名片
          </ion-button>
        </div>
      </div>
      <!-- ============ Components：纯组件陈列 ============ -->
      <div v-if="tab === 'components'" class="page">
        <!-- Buttons / Ripple -->
        <ion-list inset>
          <ion-item-group>
            <ion-item-divider><ion-note>Buttons & Ripple</ion-note></ion-item-divider>
            <ion-item class="demo-row">
              <ion-button size="small">Small</ion-button>
              <ion-button fill="outline">Outline</ion-button>
              <ion-button fill="ghost">Ghost</ion-button>
            </ion-item>
            <ion-item class="demo-row">
              <ion-button color="favorite" fill="solid">Favorite</ion-button>
              <ion-button color="danger" fill="clear">Danger</ion-button>
            </ion-item>
            <ion-item>
              <ion-button expand="block" @click="toast('Ripple 生效')">
                <ion-ripple-effect type="bounded"></ion-ripple-effect>带 Ripple
              </ion-button>
            </ion-item>
          </ion-item-group>
        </ion-list>

        <!-- Badges / Avatars / Chips -->
        <ion-list inset>
          <ion-item-group>
            <ion-item-divider><ion-note>Badges / Avatars / Chips</ion-note></ion-item-divider>
            <ion-item>
              <ion-badge>1</ion-badge>
              <ion-badge color="secondary">12</ion-badge>
              <ion-badge color="tertiary">NEW</ion-badge>
              <ion-badge color="success">Beta</ion-badge>
              <ion-badge color="warning">!</ion-badge>
            </ion-item>
            <ion-item class="demo-row">
              <ion-avatar><div class="ini" :style="{ background: gradOf(1) }">TT</div></ion-avatar>
              <ion-avatar><div class="ini" :style="{ background: gradOf(2) }">RR</div></ion-avatar>
              <ion-avatar><ion-icon :icon="personCircleOutline"></ion-icon></ion-avatar>
              <ion-note slot="end">ion-avatar（首字 / 图标）</ion-note>
            </ion-item>
            <ion-item class="demo-row">
              <ion-chip><ion-icon slot="icon" :icon="locationOutline"></ion-icon>上海</ion-chip>
              <ion-chip color="primary" outline><ion-icon slot="icon" :icon="calendarOutline"></ion-icon>05-17</ion-chip>
              <ion-chip color="favorite"><ion-icon slot="icon" :icon="star"></ion-icon>精选</ion-chip>
            </ion-item>
          </ion-item-group>
        </ion-list>

        <!-- Toggle / Radio / Range / Segmented -->
        <ion-list inset>
          <ion-item-group>
            <ion-item-divider><ion-note>表单控件</ion-note></ion-item-divider>
            <ion-item>
              <ion-label>Toggle</ion-label>
              <ion-toggle slot="end" :modelValue="demoToggle" @ionChange="demoToggle = $event.detail.checked"></ion-toggle>
            </ion-item>
            <ion-item>
              <ion-label>第二路开关</ion-label>
              <ion-toggle slot="end" color="favorite" :modelValue="demoToggle2" @ionChange="demoToggle2 = $event.detail.checked"></ion-toggle>
            </ion-item>
            <ion-item>
              <ion-radio-group :value="demoRadio" @ionChange="demoRadio = $event.detail.value">
                <ion-radio value="vue" label="Vue"></ion-radio>
                <ion-radio value="react" label="React"></ion-radio>
                <ion-radio value="angular" label="Angular"></ion-radio>
              </ion-radio-group>
            </ion-item>
            <ion-item>
              <ion-label>Range（{{ demoRange }}）</ion-label>
              <ion-range :value="demoRange" @ionChange="demoRange = $event.detail.value" min="0" max="100"></ion-range>
            </ion-item>
            <ion-item>
              <ion-segment :value="demoSeg" @ionChange="demoSeg = $event.detail.value">
                <ion-segment-button value="ios">iOS</ion-segment-button>
                <ion-segment-button value="md">MD</ion-segment-button>
                <ion-segment-button value="wp">WP</ion-segment-button>
              </ion-segment>
            </ion-item>
          </ion-item-group>
        </ion-list>

        <!-- Progress / Skeleton -->
        <ion-list inset>
          <ion-item-group>
            <ion-item-divider><ion-note>Progress / Skeleton</ion-note></ion-item-divider>
            <ion-item>
              <ion-progress-bar :value="0.4" color="primary"></ion-progress-bar>
              <ion-note>0.4</ion-note>
            </ion-item>
            <ion-item>
              <ion-progress-bar :value="0.85" color="favorite"></ion-progress-bar>
              <ion-note>0.85</ion-note>
            </ion-item>
            <ion-item>
              <ion-skeleton-text :animation="'pulse'"></ion-skeleton-text>
              <ion-skeleton-text :animation="'pulse'" style="max-width:60%"></ion-skeleton-text>
            </ion-item>
          </ion-item-group>
        </ion-list>

        <!-- Card -->
        <ion-card>
          <ion-card-header>
            <ion-card-title>Ion Card</ion-card-title>
            <ion-card-subtitle>卡片是复合组件：header / content / footer 各司其职</ion-card-subtitle>
          </ion-card-header>
          <ion-card-content>
            用 ion-card 把一段内容框起来，常用于列表项、详情块、模态里的分组。
          </ion-card-content>
        </ion-card>

        <!-- Sliding item（左滑出操作） -->
        <ion-list inset>
          <ion-item-group>
            <ion-item-divider><ion-note>Sliding Item（左滑）</ion-note></ion-item-divider>
            <ion-item-sliding>
              <ion-item><ion-label>左滑这条看操作</ion-label></ion-item>
              <ion-item-options side="end">
                <ion-item-option color="favorite" @click="toast('已收藏')"><ion-icon :icon="star"></ion-icon>收藏</ion-item-option>
                <ion-item-option color="danger" @click="toast('已删除')"><ion-icon :icon="closeOutline"></ion-icon>删除</ion-item-option>
              </ion-item-options>
            </ion-item-sliding>
          </ion-item-group>
        </ion-list>

        <!-- Select / Datetime -->
        <ion-list inset>
          <ion-item-group>
            <ion-item-divider><ion-note>Select / Datetime</ion-note></ion-item-divider>
            <ion-item>
              <ion-label>技术栈</ion-label>
              <ion-select :value="demoSelect" @ionChange="demoSelect = $event.detail.value" interface="action-sheet">
                <ion-select-option value="vue">Vue 3</ion-select-option>
                <ion-select-option value="react">React 18</ion-select-option>
                <ion-select-option value="angular">Angular</ion-select-option>
              </ion-select>
            </ion-item>
            <ion-item>
              <ion-label>会议日期</ion-label>
              <ion-datetime :value="confDate" presentation="date" @ionChange="confDate = $event.detail.value"></ion-datetime>
            </ion-item>
          </ion-item-group>
        </ion-list>

        <!-- Fab / overlays -->
        <ion-fab slot="fixed" vertical="bottom" horizontal="end">
          <ion-fab-button @click="openGallery">
            <ion-icon :icon="appsOutline"></ion-icon>
          </ion-fab-button>
          <ion-fab-list side="top">
            <ion-fab-button @click="presentShare"><ion-icon :icon="shareOutline"></ion-icon></ion-fab-button>
            <ion-fab-button color="favorite" @click="toast('Alert')"><ion-icon :icon="heartOutline"></ion-icon></ion-fab-button>
          </ion-fab-list>
        </ion-fab>
        <ion-list inset>
          <ion-item-group>
            <ion-item-divider><ion-note>弹层（controller + 声明式）</ion-note></ion-item-divider>
            <ion-item button @click="openGallery"><ion-label>打开 Modal（声明式 ion-modal）</ion-label></ion-item>
            <ion-item button @click="presentShare"><ion-label>打开 ActionSheet</ion-label></ion-item>
            <ion-item button @click="confirmFav('demo')"><ion-label>打开 Alert（确认框）</ion-label></ion-item>
            <ion-item button @click="toast('这是一条 Toast')"><ion-label>弹出 Toast</ion-label></ion-item>
          </ion-item-group>
        </ion-list>
      </div>

      <!-- ============ About ============ -->
      <div v-if="tab === 'about'" class="page">
        <ion-list inset>
          <ion-item-group>
            <ion-item-divider><ion-note>会议</ion-note></ion-item-divider>
            <ion-item>
              <ion-label>城市</ion-label>
              <ion-select :value="city" @ionChange="city = $event.detail.value" interface="popover">
                <ion-select-option v-for="c in ['Shanghai','Beijing','Shenzhen','Chengdu']" :key="c" :value="c">{{ c }}</ion-select-option>
              </ion-select>
            </ion-item>
            <ion-item>
              <ion-label>日期</ion-label>
              <ion-datetime :value="confDate" presentation="date" @ionChange="confDate = $event.detail.value"></ion-datetime>
            </ion-item>
          </ion-item-group>
        </ion-list>
        <ion-card>
          <ion-card-header>
            <ion-card-title>关于本示例</ion-card-title>
            <ion-card-subtitle>仓颉后端 · Ionic 前端 · cj-tauri 桥</ion-card-subtitle>
          </ion-card-header>
          <ion-card-content>
            这是一个纯前端的 Ionic 组件陈列，信息架构参考 ionic-conference-app，
            静态 demo 数据、不依赖后端。唯一用到的后端命令是 system:version——
            下面这行版本号就是前端经 window.__CJ_TAURI__ 从仓颉侧取回来的，
            说明桥是通的：
          </ion-card-content>
          <ion-item lines="none">
            <ion-note>cj-tauri 框架版本</ion-note>
            <ion-badge color="primary">{{ appVersion || '—' }}</ion-badge>
          </ion-item>
        </ion-card>
      </div>
    </ion-content>

    <!-- 底部 tab bar（详情页隐藏） -->
    <ion-footer v-if="!detailSession && !detailSpeaker">
      <ion-tab-bar>
        <ion-tab-button v-for="v in VIEWS" :key="v.key" :active="tab === v.key" @click="setTab(v.key)">
          <ion-icon :icon="v.icon"></ion-icon>
          <ion-label>{{ v.title }}</ion-label>
        </ion-tab-button>
      </ion-tab-bar>
    </ion-footer>

    <!-- 声明式 modal：Components 页「打开 Modal」按钮触发（:is-open 切换，内容内联） -->
    <ion-modal :is-open="galleryModalOpen" @didDismiss="galleryModalOpen = false">
      <template>
        <ion-header><ion-toolbar><ion-title>Modal 弹层</ion-title></ion-toolbar></ion-header>
        <ion-content>
          <ion-list>
            <ion-item>
              <ion-label>
                <h2>这是声明式 ion-modal</h2>
                <p>用 :is-open 切换开合，内容走内联 <code>&lt;template&gt;</code>，不依赖 modalController 或运行时模板编译——单文件 SFC 里最稳。</p>
              </ion-label>
            </ion-item>
          </ion-list>
        </ion-content>
        <ion-footer>
          <ion-button expand="block" @click="galleryModalOpen = false">关闭</ion-button>
        </ion-footer>
      </template>
    </ion-modal>
  </ion-app>
</template>

<style scoped>
/* 配色参考 ionic-conference-app 的 variables：基础用 Ionic 默认调色板，
   另加 6 个 track 色（列表左边界竖条的由来）+ 细体大标题。 */
ion-app, ion-menu {
  --ion-color-primary: #3880ff;   --ion-color-primary-rgb: 56,128,255;   --ion-color-primary-contrast: #fff;
  --ion-color-ionic: #3880ff;     --ion-color-ionic-rgb: 56,128,255;     --ion-color-ionic-contrast: #fff;
  --ion-color-vue: #34495e;       --ion-color-vue-rgb: 52,73,94;         --ion-color-vue-contrast: #fff;
  --ion-color-tooling: #fe4c52;   --ion-color-tooling-rgb: 254,76,82;    --ion-color-tooling-contrast: #fff;
  --ion-color-design: #fed035;    --ion-color-design-rgb: 254,208,53;    --ion-color-design-contrast: #000;
  --ion-color-workshop: #69bb7b;  --ion-color-workshop-rgb: 105,187,123; --ion-color-workshop-contrast: #000;
  --ion-color-food: #3bc7c4;      --ion-color-food-rgb: 59,199,196;      --ion-color-food-contrast: #000;
  --ion-color-favorite: #69bb7b;  --ion-color-favorite-rgb: 105,187,123; --ion-color-favorite-contrast: #000;
  --ion-headings-font-weight: 300;
}
ion-title { font-weight: 400; }
.brand { font-weight: 700; letter-spacing: 0.5px; }
.page { padding-bottom: 12px; }
.title-icon { margin-right: 8px; align-self: center; }
.chip-row { display: flex; flex-wrap: wrap; gap: 6px; padding: 6px 16px; }
.chip-row :deep(.ion-activatable) { cursor: pointer; }
.empty { padding: 32px; text-align: center; color: var(--ion-color-medium); }
.desc { white-space: normal; }
.inline-ic { margin-right: 6px; vertical-align: -2px; font-size: 16px; }
/* session 项：track 色左边界（conference 的标志性细节） */
.session[data-track="ionic"] :deep(ion-label) { border-left: 3px solid var(--ion-color-ionic); padding-left: 12px; }
.session[data-track="vue"] :deep(ion-label) { border-left: 3px solid var(--ion-color-vue); padding-left: 12px; }
.session[data-track="tooling"] :deep(ion-label) { border-left: 3px solid var(--ion-color-tooling); padding-left: 12px; }
.session[data-track="design"] :deep(ion-label) { border-left: 3px solid var(--ion-color-design); padding-left: 12px; }
.session[data-track="workshop"] :deep(ion-label) { border-left: 3px solid var(--ion-color-workshop); padding-left: 12px; }
.session[data-track="food"] :deep(ion-label) { border-left: 3px solid var(--ion-color-food); padding-left: 12px; }
/* 首字头像（不引外部图，离线可用） */
.ini, .mini-av .ini {
  width: 40px; height: 40px; border-radius: 50%;
  display: flex; align-items: center; justify-content: center;
  color: #fff; font-weight: 600; font-size: 15px; flex-shrink: 0;
}
.mini-av { width: 36px; height: 36px; }
.mini-av .ini { width: 36px; height: 36px; font-size: 13px; }
/* speaker 详情 */
.spk-hero { text-align: center; padding: 24px 16px 8px; }
.spk-av {
  width: 96px; height: 96px; border-radius: 50%; margin: 0 auto 12px;
  display: flex; align-items: center; justify-content: center;
  color: #fff; font-weight: 700; font-size: 34px;
}
.spk-name { font-size: 26px; font-weight: 300; margin: 0; }
.spk-title { color: var(--ion-color-medium); margin: 4px 0 12px; }
.actions { display: flex; gap: 8px; padding: 8px 16px; }
.actions ion-button { flex: 1; }
/* 组件陈列的辅助样式 */
.demo-row { display: flex; align-items: center; gap: 8px; flex-wrap: wrap; }
.pop ion-list { margin: 0; }
code { background: rgba(128,128,128,0.15); padding: 1px 5px; border-radius: 4px; font-size: 12px; }
/* drawer 菜单：MD 药丸选中态（conference 的标志性样式） */
ion-menu ion-item[aria-selected="true"] { --background: rgba(56,128,255,0.14); --border-radius: 0 50px 50px 0; }
</style>
