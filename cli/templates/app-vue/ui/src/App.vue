<script setup>
import { onMounted, ref } from 'vue';

const name = ref('world');
const result = ref('等待 invoke…');
const tick = ref('');
const href = ref('');
const bridgeOk = ref(false);

// 桥（window.__CJ_TAURI__）由宿主注入，注入时机随平台/页面来源而异：Linux 宿主注入在文档开始，
// 但发行态单文件里的内联 <script type="module"> 解析完就执行，谁先谁后与加载方式有关。
// 所以统一「等桥出现再初始化」，不要在模块作用域直接读。
let bridge = null;

function waitForBridge(timeoutMs = 3000) {
  return new Promise((resolve) => {
    const t0 = Date.now();
    const tick = () => {
      if (window.__CJ_TAURI__) return resolve(window.__CJ_TAURI__);
      if (Date.now() - t0 >= timeoutMs) return resolve(null);
      setTimeout(tick, 20);
    };
    tick();
  });
}

onMounted(async () => {
  href.value = location.href;
  bridge = await waitForBridge();
  if (!bridge) {
    result.value = '未找到 window.__CJ_TAURI__';
    return;
  }
  bridgeOk.value = true;
  bridge.listen('tick', (payload) => {
    tick.value = '事件 tick #' + payload.n + ' 来自仓颉后端';
  });
});

async function greet() {
  if (!bridge) {
    result.value = '桥未就绪';
    return;
  }
  try {
    const data = await bridge.invoke('greet', { name: name.value });
    result.value = 'invoke OK: ' + data;
  } catch (err) {
    result.value = 'invoke FAIL: ' + err.message;
  }
}

async function startTimer() {
  if (bridge) await bridge.invoke('timer');
}

function reload() {
  if (bridge) bridge.reload();
}
</script>

<template>
  <h1>cj-tauri · Vue 3 + Vite</h1>
  <p class="hint">
    页面来源：<code>{{ href }}</code><br />
    桥状态：{{ bridgeOk ? '已注入 __CJ_TAURI__' : '未注入' }}
  </p>

  <div class="card">
    <div class="row">
      <input v-model="name" placeholder="输入名字" />
      <button @click="greet">greet</button>
      <button class="ghost" @click="startTimer">timer</button>
      <button class="ghost" @click="reload">reload</button>
    </div>
    <div class="out">{{ result }}</div>
    <div class="tick">{{ tick }}</div>
    <p class="tip">
      改这个文件（<code>ui/src/App.vue</code>）保存，页面会在不重启应用的情况下更新。
    </p>
  </div>
</template>

<style scoped>
h1 {
  color: #7ce7ff;
}
.hint {
  font-size: 13px;
  opacity: 0.8;
}
.card {
  background: #16213e;
  border-radius: 12px;
  padding: 20px 24px;
  width: 560px;
  box-shadow: 0 8px 24px rgba(0, 0, 0, 0.4);
}
.row {
  display: flex;
  gap: 8px;
}
input {
  flex: 1;
  padding: 8px 12px;
  border: none;
  border-radius: 8px;
  background: #0f3460;
  color: #eee;
}
button {
  padding: 8px 14px;
  border: none;
  border-radius: 8px;
  background: #e94560;
  color: #fff;
  cursor: pointer;
}
button.ghost {
  background: #24476e;
}
button:hover {
  opacity: 0.85;
}
.out {
  margin-top: 14px;
  font-size: 16px;
}
.tick {
  margin-top: 6px;
  font-size: 13px;
  color: #8be9fd;
}
.tip {
  margin-top: 14px;
  font-size: 12px;
  opacity: 0.7;
}
</style>
