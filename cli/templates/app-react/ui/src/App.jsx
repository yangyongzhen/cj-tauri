import { useEffect, useState } from 'react';
import './App.css';   // 与 app-vue 模板等价的样式（React 没有 SFC，样式走独立的 css）

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

export default function App() {
  const [name, setName] = useState('world');
  const [result, setResult] = useState('等待 invoke…');
  const [tick, setTick] = useState('');
  const [href, setHref] = useState('');
  const [bridgeOk, setBridgeOk] = useState(false);

  useEffect(() => {
    let alive = true;   // 等桥是异步的：组件卸载后不要再回写状态
    (async () => {
      setHref(location.href);
      const t = await waitForBridge();
      if (!alive) return;
      bridge = t;
      if (!t) {
        setResult('未找到 window.__CJ_TAURI__');
        return;
      }
      setBridgeOk(true);
      t.listen('tick', (payload) => {
        setTick('事件 tick #' + payload.n + ' 来自仓颉后端');
      });
    })();
    return () => {
      alive = false;
    };
  }, []);

  async function greet() {
    if (!bridge) {
      setResult('桥未就绪');
      return;
    }
    try {
      const data = await bridge.invoke('greet', { name });
      setResult('invoke OK: ' + data);
    } catch (err) {
      setResult('invoke FAIL: ' + err.message);
    }
  }

  async function startTimer() {
    if (bridge) await bridge.invoke('timer');
  }

  function reload() {
    if (bridge) bridge.reload();
  }

  return (
    <>
      <h1>cj-tauri · React + Vite</h1>
      <p className="hint">
        页面来源：<code>{href}</code>
        <br />
        桥状态：{bridgeOk ? '已注入 __CJ_TAURI__' : '未注入'}
      </p>

      <div className="card">
        <div className="row">
          <input
            value={name}
            placeholder="输入名字"
            onChange={(e) => setName(e.target.value)}
          />
          <button onClick={greet}>greet</button>
          <button className="ghost" onClick={startTimer}>timer</button>
          <button className="ghost" onClick={reload}>reload</button>
        </div>
        <div className="out">{result}</div>
        <div className="tick">{tick}</div>
        <p className="tip">
          改这个文件（<code>ui/src/App.jsx</code>）保存，页面会在不重启应用的情况下更新。
        </p>
      </div>
    </>
  );
}
