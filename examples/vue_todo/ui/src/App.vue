<script setup>
import { computed, onMounted, ref } from 'vue';

// 桥（window.__CJ_TAURI__）由宿主的用户脚本注入，**不要**在模块作用域直接读它：
// Linux 宿主是在文档末尾注入的（bridge_linux.c 的 WEBKIT_USER_SCRIPT_INJECT_AT_DOCUMENT_END），
// 而 `npm run build` 产出的单文件把 <script type="module"> 内联进 HTML —— 解析完就执行，
// 会跑在注入之前，直接读会拿到 undefined（开发态从 URL 加载、模块要现下载，反而看不出来）。
// 所以这里统一「等桥出现」再初始化。
const bridge = ref(null);

const items = ref([]);          // 待办列表，由后端命令/事件填充
const draft = ref('');          // 输入框
const error = ref('');          // 后端抛 CommandException 时显示它
const href = ref('');
const version = ref('…');
const eventCount = ref(0);
const lastAction = ref('等待操作');

// 条数用 computed 算：这正是 Vue 相对手写 DOM 的差别——列表一变，界面自己跟着变
const count = computed(() => items.value.length);
const bridgeState = computed(() => {
  if (bridge.value) return '已注入 __CJ_TAURI__';
  return error.value ? '未注入' : '等待注入…';
});

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
  const t = await waitForBridge();
  if (!t) {
    error.value = '未找到 window.__CJ_TAURI__：请用 cj-tauri 启动，而不是浏览器直接打开 index.html';
    return;
  }
  bridge.value = t;

  // 后端每改一次列表就广播一次，前端不轮询
  t.listen('todo:changed', (payload) => {
    items.value = payload.items;
    eventCount.value += 1;
    lastAction.value = '收到 todo:changed（count=' + payload.count + '）';
  });

  try {
    const data = await t.invoke('todo:list');
    items.value = data.items;
    lastAction.value = 'todo:list 返回 ' + data.count + ' 条';
  } catch (err) {
    error.value = err.message;
  }

  try {
    version.value = await t.invoke('system:version');
  } catch (err) {
    version.value = '取版本失败：' + err.message;
  }
});

async function add() {
  const t = bridge.value;
  if (!t) return;
  const text = draft.value.trim();
  if (!text) {
    error.value = '空内容不会提交（后端也会拒绝）';
    return;
  }
  try {
    const n = await t.invoke('todo:add', { text });
    draft.value = '';
    error.value = '';
    lastAction.value = 'todo:add 返回 ' + n;
  } catch (err) {
    error.value = err.message;      // 后端 CommandException 的原话
  }
}

async function remove(index) {
  const t = bridge.value;
  if (!t) return;
  const ok = await t.invoke('todo:remove', { index });
  lastAction.value = 'todo:remove 返回 ' + ok;
}

function reload() {
  if (bridge.value) bridge.value.reload();
}
</script>

<template>
  <h1>待办清单 · Vue 3 + Vite + 仓颉后端</h1>

  <p class="hint">
    页面来源：<code>{{ href }}</code><br />
    桥状态：{{ bridgeState }} ｜ 后端版本：<code>{{ version }}</code>
  </p>

  <div class="card">
    <div class="row">
      <input v-model="draft" placeholder="要做点什么？回车或点「添加」" @keyup.enter="add" />
      <button @click="add">添加</button>
      <button class="ghost" @click="reload">重载页面</button>
    </div>

    <p v-if="error" class="error">{{ error }}</p>

    <ul v-if="count">
      <li v-for="(item, i) in items" :key="i">
        <span class="text">{{ item }}</span>
        <button class="del" @click="remove(i)">删除</button>
      </li>
    </ul>
    <p v-else class="empty">列表为空 —— 写一条试试，数据由仓颉后端保管。</p>

    <p class="foot">
      共 <b>{{ count }}</b> 条 ｜ 收到事件 <b>{{ eventCount }}</b> 次 ｜ {{ lastAction }}
    </p>
    <p class="tip">
      命令与事件都由 <code>capabilities/default.json</code> 授权；改
      <code>ui/src/App.vue</code> 保存即热更新（应用不重启）。
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
  width: 620px;
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
button.del {
  background: transparent;
  color: #ff9db0;
  font-size: 12px;
  padding: 2px 8px;
}
button:hover {
  opacity: 0.85;
}
ul {
  list-style: none;
  margin: 16px 0 0;
  padding: 0;
}
li {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 12px;
  padding: 8px 12px;
  margin-bottom: 6px;
  border-radius: 8px;
  background: #0f3460;
}
.text {
  word-break: break-all;
}
.error {
  margin-top: 12px;
  color: #ff9db0;
  font-size: 13px;
}
.empty {
  margin-top: 16px;
  font-size: 13px;
  opacity: 0.7;
}
.foot {
  margin-top: 14px;
  font-size: 13px;
  color: #8be9fd;
}
.tip {
  margin-top: 10px;
  font-size: 12px;
  opacity: 0.7;
}
</style>
