import { createApp } from 'vue';
import { IonicVue } from '@ionic/vue';
import App from './App.vue';

/* Ionic 基础样式：core.css 必引（组件布局变量全在里面），
   ionicons 走 SVG 组件、不引它的 CSS。深色主题按需切换（见下）。 */
import '@ionic/vue/css/core.css';
import '@ionic/vue/css/normalize.css';
import '@ionic/vue/css/structure.css';
import '@ionic/vue/css/typography.css';

/* 深色主题：默认浅色，组件里用 ion-palette-dark 类按需切换——
   必须先引入这份 CSS，类名才有效果（只引 CSS 不挂类 = 浅色）。 */
import '@ionic/vue/css/palettes/dark.class.css';

const app = createApp(App).use(IonicVue);
app.mount('#app');

/* 等桥出现再放行页面：document-start 注入一般早于模块执行，但等一等没有代价。 */
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
