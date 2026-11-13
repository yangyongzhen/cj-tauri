import { createApp } from 'vue';
import { IonicVue } from '@ionic/vue';
import App from './App.vue';

/* Ionic 基础样式：core.css 是必引的（组件的布局变量全在里面），
   ionicons 的 CSS 只在用 <ion-icon> 的 CSS 变体时才需要——这里走 SVG 组件，不引。 */
import '@ionic/vue/css/core.css';
import '@ionic/vue/css/normalize.css';
import '@ionic/vue/css/structure.css';
import '@ionic/vue/css/typography.css';

/* 深色主题：音乐播放器用暗色更合适（与 music-next 的观感一致） */
import '@ionic/vue/css/palettes/dark.class.css';

const app = createApp(App).use(IonicVue);
app.mount('#app');

/* 等桥出现再放行页面自检：与模板的 waitForBridge 同款——document-start 注入
   一般早于模块执行，但等一等没有代价（千分位轮询，最多 5 秒）。 */
function waitForBridge() {
  return new Promise((resolve) => {
    const t0 = Date.now();
    const timer = setInterval(() => {
      if (window.__CJ_TAURI__ || Date.now() - t0 > 5000) {
        clearInterval(timer);
        resolve(window.__CJ_TAURI__);
      }
    }, 50);
  });
}
window.__bridgeReady = waitForBridge();
