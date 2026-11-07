'use strict';
// dsh WASM/HTTP 冒烟探针（+ios3）
//
// 目的：不联网，但完整走一遍 dsh 真 boot 的第一条致命路径
//   全局 fetch -> Node 内置 undici 加载 -> llhttp WebAssembly.Module 编译
//   -> 一次 HTTP/1 请求与响应解析
// 这条路径正是 A11 / iOS 16 rootless 上 SIGBUS 的触发点：V8 默认在后台
// 线程编译 WASM，而 pthread_jit_write_protect_np 是 per-thread 的，后台线程
// 没有可写权限，写 WASM 代码页即被内核以 SIGBUS 拒绝。
//
// 退出码 0  = 该组 V8 flags 可以安全用于 dsh；其它 = 不可用（含被信号杀死）。
// 由 pick-flags.sh 在启动前逐档调用，选出设备真正能跑的那一档。

const http = require('node:http');

const timer = setTimeout(() => {
  console.error('dsh-smoke: timeout');
  process.exit(5);
}, 15000);

const server = http.createServer((req, res) => {
  res.writeHead(200, { 'content-type': 'text/plain; charset=utf-8' });
  res.end('dsh-smoke-ok');
});

server.on('error', (e) => {
  console.error('dsh-smoke: listen failed:', e && e.message);
  clearTimeout(timer);
  process.exit(4);
});

server.listen(0, '127.0.0.1', async () => {
  const port = server.address().port;
  try {
    // 这一句会强制加载内置 undici 并编译 llhttp WASM —— 探针的核心。
    const res = await fetch(`http://127.0.0.1:${port}/`, {
      headers: { accept: 'text/plain' }
    });
    const body = await res.text();
    if (res.status !== 200 || body !== 'dsh-smoke-ok') {
      console.error('dsh-smoke: bad response', res.status, JSON.stringify(body));
      clearTimeout(timer);
      process.exit(3);
    }
  } catch (e) {
    console.error('dsh-smoke: fetch failed:', e && e.message);
    clearTimeout(timer);
    process.exit(2);
  }
  server.close(() => {
    clearTimeout(timer);
    process.exit(0);
  });
});
