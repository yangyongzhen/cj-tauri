import { createApp } from 'vue';
import { IonicVue } from '@ionic/vue';
import App from './App.vue';

/* Ionic 基础样式（core.css 必引）；深色主题：dark.class.css 是 class 选择器，
   必须把 ion-palette-dark 挂到 <html> 上才生效（index.html 里已挂）。 */
import '@ionic/vue/css/core.css';
import '@ionic/vue/css/normalize.css';
import '@ionic/vue/css/structure.css';
import '@ionic/vue/css/typography.css';
import '@ionic/vue/css/palettes/dark.class.css';

const app = createApp(App).use(IonicVue);
app.mount('#app');

/* 等桥出现再放行页面（与模板的 waitForBridge 同款） */
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
