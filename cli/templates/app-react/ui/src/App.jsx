import { useEffect, useState } from 'react';

export default function App() {
  const [name, setName] = useState('world');
  const [result, setResult] = useState('等待 invoke…');
  const [tick, setTick] = useState('');
  const [href, setHref] = useState('');
  const [bridgeOk, setBridgeOk] = useState(false);

  useEffect(() => {
    setHref(location.href);
    const t = window.__CJ_TAURI__;
    if (!t) {
      setResult('未找到 window.__CJ_TAURI__');
      return;
    }
    setBridgeOk(true);
    t.listen('tick', (payload) => {
      setTick('事件 tick #' + payload.n + ' 来自仓颉后端');
    });
  }, []);

  async function greet() {
    try {
      const data = await window.__CJ_TAURI__.invoke('greet', { name });
      setResult('invoke OK: ' + data);
    } catch (err) {
      setResult('invoke FAIL: ' + err.message);
    }
  }

  async function startTimer() {
    await window.__CJ_TAURI__.invoke('timer');
  }

  function reload() {
    window.__CJ_TAURI__.reload();
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
