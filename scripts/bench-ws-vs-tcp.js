// WebSocket / TCP 本机回环基准 —— 给 cj-tauri 的进程内 IPC 做同机对照。
//
// 本机没有 ws 库，但 Node 22 自带 `WebSocket` 客户端（undici），
// 所以这里手写一个最小 WebSocket 服务端（RFC6455 握手 + 单帧文本回显，够基准用）。
//
// 跑法: node scripts/bench-ws-vs-tcp.js 2>&1 | tee /tmp/ws-vs-tcp.log
// 量的是「顺序往返」：发一条、等回到、再发下一条；同 cj-tauri 探针（examples/ipc-bench）的 latency 项。
// 结果解读与对照表见 docs/IPC-通信机制.md §4.3 / §5.3。

const net = require('net');
const crypto = require('crypto');
const { performance } = require('perf_hooks');

const GUID = '258EAFA5-E914-47DA-95CA-C5AB0DC85B11';
const N = 200;              // 顺序往返次数（与 cj-tauri 探针一致）
const WARMUP = 20;
const PAYLOAD = 'x'.repeat(41);   // 与 ping 一条报文的量级接近

function encodeFrame(str) {
  const data = Buffer.from(str, 'utf8');
  const len = data.length;
  let head;
  if (len < 126) {
    head = Buffer.from([0x81, len]);
  } else if (len < 65536) {
    head = Buffer.alloc(4);
    head[0] = 0x81; head[1] = 126; head.writeUInt16BE(len, 2);
  } else {
    head = Buffer.alloc(10);
    head[0] = 0x81; head[1] = 127; head.writeBigUInt64BE(BigInt(len), 2);
  }
  return Buffer.concat([head, data]);
}

// 解析一个客户端帧（必须带掩码）；不完整返回 null
function parseFrame(buf) {
  if (buf.length < 2) return null;
  const opcode = buf[0] & 0x0f;
  const masked = (buf[1] & 0x80) !== 0;
  let len = buf[1] & 0x7f;
  let off = 2;
  if (len === 126) { if (buf.length < 4) return null; len = buf.readUInt16BE(2); off = 4; }
  else if (len === 127) { if (buf.length < 10) return null; len = Number(buf.readBigUInt64BE(2)); off = 10; }
  let mask = null;
  if (masked) { if (buf.length < off + 4) return null; mask = buf.subarray(off, off + 4); off += 4; }
  if (buf.length < off + len) return null;
  const data = Buffer.from(buf.subarray(off, off + len));
  if (mask) { for (let i = 0; i < data.length; i++) data[i] ^= mask[i % 4]; }
  return { opcode, payload: data.toString('utf8'), total: off + len };
}

function stats(arr) {
  const s = arr.slice().sort((a, b) => a - b);
  const sum = s.reduce((a, b) => a + b, 0);
  const at = f => s[Math.min(s.length - 1, Math.floor(s.length * f))];
  return { min: s[0], p50: at(0.5), p95: at(0.95), max: s[s.length - 1], mean: sum / s.length };
}
const fmt = n => Math.round(n * 1000) / 1000;
const line = (tag, st) =>
  `${tag} min=${fmt(st.min)}ms p50=${fmt(st.p50)}ms p95=${fmt(st.p95)}ms max=${fmt(st.max)}ms mean=${fmt(st.mean)}ms`;

// ---- 1) 最小 WebSocket 服务端（握手 + 文本帧回显） ----
function startWsServer() {
  return new Promise(resolve => {
    const srv = net.createServer(sock => {
      let handshaked = false;
      let buf = Buffer.alloc(0);
      sock.on('data', chunk => {
        buf = Buffer.concat([buf, chunk]);
        if (!handshaked) {
          const idx = buf.indexOf('\r\n\r\n');
          if (idx < 0) return;
          const head = buf.subarray(0, idx).toString();
          const m = /Sec-WebSocket-Key: (.+)/i.exec(head);
          if (!m) { sock.destroy(); return; }
          const accept = crypto.createHash('sha1').update(m[1].trim() + GUID).digest('base64');
          sock.write('HTTP/1.1 101 Switching Protocols\r\n' +
                     'Upgrade: websocket\r\nConnection: Upgrade\r\n' +
                     'Sec-WebSocket-Accept: ' + accept + '\r\n\r\n');
          handshaked = true;
          buf = buf.subarray(idx + 4);
        }
        for (;;) {
          const f = parseFrame(buf);
          if (!f) break;
          buf = buf.subarray(f.total);
          if (f.opcode === 0x8) { sock.end(); break; }
          if (f.opcode === 0x1) sock.write(encodeFrame(f.payload));
        }
      });
    });
    srv.listen(0, '127.0.0.1', () => resolve(srv));
  });
}

function wsRoundTrip(ws, payload) {
  return new Promise((resolve, reject) => {
    const onMsg = ev => {
      ws.removeEventListener('message', onMsg);
      ws.removeEventListener('error', onErr);
      resolve(performance.now() - t0);
    };
    const onErr = ev => reject(new Error('ws error'));
    ws.addEventListener('message', onMsg);
    ws.addEventListener('error', onErr);
    var t0 = performance.now();
    ws.send(payload);
  });
}

async function benchWs(port) {
  const ws = new WebSocket(`ws://127.0.0.1:${port}/`);
  await new Promise((res, rej) => {
    ws.addEventListener('open', res);
    ws.addEventListener('error', rej);
  });
  for (let i = 0; i < WARMUP; i++) await wsRoundTrip(ws, PAYLOAD);
  const t = [];
  for (let i = 0; i < N; i++) t.push(await wsRoundTrip(ws, PAYLOAD));
  ws.close();
  return stats(t);
}

// ---- 2) 裸 TCP 回环回显（socket 往返的下限：无握手、无帧、无事件循环） ----
function startTcpEcho() {
  return new Promise(resolve => {
    const srv = net.createServer(sock => { sock.on('data', d => sock.write(d)); });
    srv.listen(0, '127.0.0.1', () => resolve(srv));
  });
}

function tcpRoundTrip(sock, payload) {
  return new Promise(resolve => {
    const onData = () => { sock.removeListener('data', onData); resolve(performance.now() - t0); };
    sock.on('data', onData);
    var t0 = performance.now();
    sock.write(payload);
  });
}

async function benchTcp(port) {
  const sock = net.connect(port, '127.0.0.1');
  await new Promise(res => sock.on('connect', res));
  sock.setNoDelay(true);
  for (let i = 0; i < WARMUP; i++) await tcpRoundTrip(sock, PAYLOAD);
  const t = [];
  for (let i = 0; i < N; i++) t.push(await tcpRoundTrip(sock, PAYLOAD));
  sock.end();
  return stats(t);
}

(async () => {
  console.log(`payload=${PAYLOAD.length}B n=${N} warmup=${WARMUP} node=${process.version}`);
  const wsSrv = await startWsServer();
  console.log('WS   ' + line('localhost ws://127.0.0.1', await benchWs(wsSrv.address().port)));
  wsSrv.close();
  const tcpSrv = await startTcpEcho();
  console.log('TCP  ' + line('localhost tcp echo ', await benchTcp(tcpSrv.address().port)));
  tcpSrv.close();
})();
