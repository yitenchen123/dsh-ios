'use strict';
// ============================================================================
// dsh fetch shim (CJS preload, +ios6 / nowasm 档)
// +ios5: 最小侵入，只覆盖 fetch/WebSocket，保留原生 Headers/Request/Response/FormData
// +ios6: Response.body 幂等 + 补齐 formData()/bytes()，修 SSE 流式 transport failed
//
// 为什么需要它：
//   Node 22 的全局 fetch 来自「内置 undici」，其 HTTP/1 解析器是 llhttp 的
//   WebAssembly 版本，模块加载期就会 new WebAssembly.Module(...)。在 iOS
//   rootless / A11 上，WASM 编译（后台线程写可执行内存）会触发 SIGBUS；
//   而 --jitless 会把 WebAssembly 全局整个移除，内置 undici 加载即抛
//   "WebAssembly is not defined"。两头堵死。
//
//   本 shim 只覆盖 fetch / WebSocket 两个 lazy 全局。fetch 用
//   node:http / node:https（原生 C++ llhttp，不用 WASM）实现；
//   从而让 dsh 在 --jitless 下完全不分配任何可执行内存 —— 连 JIT 都不开，
//   从原理上消除 SIGBUS。纯解释执行，慢一点，但 I/O 密集的 CLI 完全够用。
//
// 关键约束：绝不能读取原 fetch/Headers/... 的值（那些是 lazy getter，一读
//   就加载内置 undici -> WASM）。只能通过 Object.defineProperty 直接覆盖。
//   也绝不 require("undici")。
// ============================================================================

const http = require('node:http');
const https = require('node:https');
const zlib = require('node:zlib');
const { Readable } = require('node:stream');
const { TextEncoder, TextDecoder } = require('node:util');

const enc = new TextEncoder();
const dec = new TextDecoder();

// ---------------------------------------------------------------------------
// jitless 会把 WebAssembly 全局整个移除，而内置 undici / npm undici 在
// **模块加载期**就会 new WebAssembly.Module(llhttp wasm)。只要 dsh 引用了
// undici 的任意符号（含 WebSocket、getGlobalDispatcher 等），加载即抛
// "WebAssembly is not defined"，连启动都到不了。
//
// 本档里真实网络请求全部由上面的 shim 走 node:http，llhttp WASM 永远不会被
// 调用，所以给它一个「只满足模块加载」的最小 stub 是安全的：让模块图能建
// 起来，但绝不产生任何可执行代码。
// ---------------------------------------------------------------------------
if (typeof globalThis.WebAssembly === 'undefined') {
  class StubModule { constructor(bytes) { this.bytes = bytes; } }
  class StubMemory {
    constructor(d) { this.buffer = new ArrayBuffer(((d && d.initial) || 1) * 65536); }
    grow() { return 1; }
  }
  class StubInstance {
    constructor() { this.exports = { memory: new StubMemory({ initial: 1 }) }; }
  }
  const StubWasm = {
    Module: StubModule,
    Instance: StubInstance,
    Memory: StubMemory,
    Table: class { constructor() {} get() { return null; } set() {} grow() { return 0; } },
    Global: class { constructor() { this.value = 0; } },
    Tag: class {},
    Exception: class {},
    compile: async (b) => new StubModule(b),
    compileStreaming: async () => new StubModule(new ArrayBuffer(0)),
    instantiate: async (b) => ({ module: new StubModule(b), instance: new StubInstance() }),
    instantiateStreaming: async () => ({ module: new StubModule(new ArrayBuffer(0)), instance: new StubInstance() }),
    validate: () => true
  };
  StubWasm.Memory = StubMemory;
  Object.defineProperty(globalThis, 'WebAssembly', {
    value: StubWasm, writable: true, configurable: true, enumerable: false
  });
}

class ShimHeaders {
  constructor(init) {
    this._m = new Map();
    if (!init) return;
    if (init instanceof ShimHeaders) {
      for (const [k, v] of init._m) this._m.set(k, v);
    } else if (Array.isArray(init)) {
      for (const pair of init) if (pair && pair.length >= 2) this.append(pair[0], pair[1]);
    } else if (typeof init.forEach === 'function' && typeof init.entries !== 'function') {
      init.forEach((v, k) => this.append(k, v));
    } else if (typeof init[Symbol.iterator] === 'function' && !Array.isArray(init)) {
      for (const pair of init) if (pair && pair.length >= 2) this.append(pair[0], pair[1]);
    } else {
      for (const k of Object.keys(init)) {
        const v = init[k];
        if (v !== undefined) this.append(k, Array.isArray(v) ? v.join(', ') : String(v));
      }
    }
  }
  append(k, v) {
    const key = String(k).toLowerCase();
    const val = String(v);
    const old = this._m.get(key);
    this._m.set(key, old ? old + ', ' + val : val);
  }
  set(k, v) { this._m.set(String(k).toLowerCase(), String(v)); }
  get(k) { const v = this._m.get(String(k).toLowerCase()); return v === undefined ? null : v; }
  has(k) { return this._m.has(String(k).toLowerCase()); }
  delete(k) { this._m.delete(String(k).toLowerCase()); }
  forEach(fn, thisArg) { for (const [k, v] of this._m) fn.call(thisArg, v, k, this); }
  keys() { return this._m.keys(); }
  values() { return this._m.values(); }
  entries() { return this._m.entries(); }
  [Symbol.iterator]() { return this._m.entries(); }
  toObject() { return Object.fromEntries(this._m); }
}

function bodyToBuffer(body) {
  if (body === undefined || body === null) return null;
  if (typeof body === 'string') return Buffer.from(body, 'utf8');
  if (Buffer.isBuffer(body)) return body;
  if (body instanceof ArrayBuffer) return Buffer.from(body);
  if (ArrayBuffer.isView(body)) return Buffer.from(body.buffer, body.byteOffset, body.byteLength);
  if (typeof body === 'object' && typeof body[Symbol.asyncIterator] === 'function') return body;
  return Buffer.from(String(body), 'utf8');
}

function decodeStream(res) {
  const encHeader = String(res.headers['content-encoding'] || '').toLowerCase().trim();
  if (!encHeader || encHeader === 'identity') return res;
  switch (encHeader) {
    case 'gzip': return res.pipe(zlib.createGunzip());
    case 'deflate': return res.pipe(zlib.createInflate());
    case 'br': return res.pipe(zlib.createBrotliDecompress());
    default: return res;   // zstd 等：Node 22.12 无解压器，交回原始字节
  }
}

async function collect(stream) {
  const chunks = [];
  for await (const c of stream) chunks.push(Buffer.isBuffer(c) ? c : Buffer.from(c));
  return Buffer.concat(chunks);
}

class ShimResponse {
  constructor(stream, opts) {
    opts = opts || {};
    this.status = opts.status || 200;
    this.statusText = opts.statusText || '';
    this.ok = this.status >= 200 && this.status < 300;
    this.redirected = !!opts.redirected;
    this.url = opts.url || '';
    this.headers = opts.headers instanceof ShimHeaders ? opts.headers : new ShimHeaders(opts.headers);
    this._raw = stream;                 // IncomingMessage（已按需解压）
    this._bodyUsed = false;
    this._bodyStream = null;
    this._bodyLocked = false;
  }
  get bodyUsed() { return this._bodyUsed; }
  // +ios6 关键修复（body 幂等）：原生 Response.body 是「幂等 getter」——多次读取返回同一个
  // ReadableStream。dsh 的 SSE 路径 (dsh-llm-deepseek/lib/index.js:2259-2260)
  // 会连续访问两次：先 `if (response.body === null)`，再 `parseSse(response.body)`。
  // 旧实现第一次就把 _bodyUsed 置 true，第二次抛 "Body is unusable"，这个
  // 异常不是 LlmError/超时/取消，被 generate() 兜底包成
  // "DeepSeek Messages transport failed" (TRANSPORT)，重试 5/5 全部失败
  // —— 手机工作台发消息一直转圈报 transport failed 就是这个原因。
  get body() {
    if (this._bodyLocked) return this._bodyStream;
    if (this._bodyUsed) throw new TypeError('Body is unusable');
    this._bodyLocked = true;
    this._bodyUsed = true;
    if (!this._raw) { this._bodyStream = null; return null; }
    // Readable.toWeb 属于 node:stream，与内置 undici / WASM 无关。
    this._bodyStream = Readable.toWeb(this._raw);
    return this._bodyStream;
  }
  async _consume() {
    if (this._bodyUsed) throw new TypeError('Body is unusable: body stream already read');
    this._bodyUsed = true;
    return this._raw ? collect(this._raw) : Buffer.alloc(0);
  }
  async text() { const b = await this._consume(); return dec.decode(b); }
  async json() { return JSON.parse(await this.text()); }
  async arrayBuffer() {
    const b = await this._consume();
    return b.buffer.slice(b.byteOffset, b.byteOffset + b.byteLength);
  }
  async blob() { const b = await this._consume(); return new Blob([b], { type: this.headers.get('content-type') || '' }); }
  // +ios6 补齐：dsh-client-connection/lib/client.node.js 的 parseBinaryResponse
  // 会对 multipart 响应调 response.formData()；旧 shim 没有这个方法。
  // +ios5 起原生 Response 全局保留，multipart 解析走内置 undici 的纯 JS
  // 解析器（不碰 llhttp WASM），可安全委托给它。
  async formData() {
    const b = await this._consume();
    const R = globalThis.Response;
    if (typeof R !== 'function') throw new TypeError('formData() unavailable: no native Response');
    return new R(b, { headers: this.headers.toObject() }).formData();
  }
  // Node 22 的 Response.bytes()；同样补齐，避免新代码路径踩空。
  async bytes() {
    const b = await this._consume();
    return new Uint8Array(b.buffer.slice(b.byteOffset, b.byteOffset + b.byteLength));
  }
  clone() {
    if (this._bodyUsed) throw new TypeError('Cannot clone a used body');
    // 简易分流：把原流 tee 成两份，一份留给 this，一份给克隆体。
    const [a, b] = Readable.toWeb(this._raw).tee();
    this._bodyUsed = true;
    this._bodyStream = a;
    // 用 async generator 把 web stream 转回供 clone 使用的轻量对象
    const cloneObj = Object.create(ShimResponse.prototype);
    Object.assign(cloneObj, {
      status: this.status, statusText: this.statusText, ok: this.ok,
      redirected: this.redirected, url: this.url, headers: new ShimHeaders(this.headers),
      _raw: null, _bodyUsed: true, _bodyStream: b, _bodyLocked: true
    });
    // 让 clone 的 text/json/arrayBuffer 直接读 web stream
    const bufFromWeb = async (ws) => {
      const r = ws.getReader(); const parts = [];
      for (;;) { const { done, value } = await r.read(); if (done) break; parts.push(Buffer.from(value)); }
      return Buffer.concat(parts);
    };
    cloneObj.text = async () => { const x = await bufFromWeb(b); return dec.decode(x); };
    cloneObj.json = async () => JSON.parse(await cloneObj.text());
    cloneObj.arrayBuffer = async () => { const x = await bufFromWeb(b); return x.buffer.slice(x.byteOffset, x.byteOffset + x.byteLength); };
    return cloneObj;
  }
}

class ShimRequest {
  constructor(input, init) {
    init = init || {};
    if (input instanceof ShimRequest) {
      this.url = input.url; this.method = init.method || input.method;
      this.headers = new ShimHeaders(init.headers || input.headers);
      this.body = init.body !== undefined ? init.body : input.body;
      this.signal = init.signal || input.signal;
      this.redirect = init.redirect || input.redirect;
    } else {
      this.url = String(input && input.url ? input.url : input);
      this.method = String(init.method || 'GET').toUpperCase();
      this.headers = new ShimHeaders(init.headers);
      this.body = init.body;
      this.signal = init.signal;
      this.redirect = init.redirect || 'follow';
    }
  }
  async text() { const b = bodyToBuffer(this.body); if (!b) return ''; if (typeof b.pipe === 'function' || b[Symbol.asyncIterator]) return dec.decode(await collect(b)); return dec.decode(b); }
  async json() { return JSON.parse(await this.text()); }
}

function onceRequest(url, opts, redirectsLeft, redirected) {
  return new Promise((resolve, reject) => {
    let u;
    try { u = new URL(url); } catch (e) { reject(new TypeError('Failed to parse URL from ' + url)); return; }
    const isHttps = u.protocol === 'https:';
    const mod = isHttps ? https : http;
    if (u.protocol !== 'http:' && u.protocol !== 'https:') { reject(new TypeError('Only http(s) supported: ' + u.protocol)); return; }

    const headers = new ShimHeaders(opts.headers);
    if (!headers.has('accept')) headers.set('accept', '*/*');
    if (!headers.has('user-agent')) headers.set('user-agent', 'dsh-ios/0.2.1 (node-http shim)');
    if (!headers.has('accept-encoding')) headers.set('accept-encoding', 'gzip, deflate');
    if (opts.bodyBuf && !headers.has('content-length')) headers.set('content-length', String(opts.bodyBuf.length));

    const reqOpts = {
      protocol: u.protocol, hostname: u.hostname, port: u.port || (isHttps ? 443 : 80),
      path: u.pathname + u.search, method: opts.method, headers: headers.toObject(),
      // dispatcher 是 undici 专有选项，node:http 无对应实现，安全忽略。
    };
    if (opts.signal && opts.signal.aborted) { reject(new DOMException('The operation was aborted', 'AbortError')); return; }

    let req;
    try { req = mod.request(reqOpts, (res) => {
      const status = res.statusCode || 0;
      const loc = res.headers.location;
      const isRedirect = [301, 302, 303, 307, 308].includes(status) && loc;
      if (isRedirect && opts.redirect !== 'manual') {
        res.resume();
        if (opts.redirect === 'error') { reject(new TypeError('Request redirected (redirect: "error")')); return; }
        if (redirectsLeft <= 0) { reject(new TypeError('Too many redirects')); return; }
        let next;
        try { next = new URL(loc, u).toString(); } catch (e) { reject(e); return; }
        const nextMethod = (status === 303 && opts.method !== 'GET' && opts.method !== 'HEAD') ? 'GET' : opts.method;
        const nextBody = nextMethod === 'GET' ? null : opts.bodyBuf;
        onceRequest(next, { ...opts, method: nextMethod, bodyBuf: nextBody }, redirectsLeft - 1, true).then(resolve, reject);
        return;
      }
      const stream = decodeStream(res);
      resolve(new ShimResponse(stream, {
        status, statusText: res.statusMessage || '',
        headers: res.headers, url: u.toString(), redirected
      }));
    }); } catch (e) { reject(e); return; }

    req.on('error', reject);
    if (opts.signal) {
      const onAbort = () => { req.destroy(Object.assign(new Error('The operation was aborted'), { name: 'AbortError' })); };
      if (typeof opts.signal.addEventListener === 'function') {
        opts.signal.addEventListener('abort', onAbort, { once: true });
        req.on('close', () => { if (typeof opts.signal.removeEventListener === 'function') opts.signal.removeEventListener('abort', onAbort); });
      }
    }
    if (opts.bodyBuf) {
      if (typeof opts.bodyBuf.pipe === 'function') opts.bodyBuf.pipe(req);
      else { req.write(opts.bodyBuf); req.end(); }
    } else req.end();
  });
}

async function shimFetch(input, init) {
  init = init || {};
  const req = new ShimRequest(input, init);
  const buf = bodyToBuffer(req.body);
  // 显式 dispatcher（undici Agent）无法用于 node:http；忽略它，仅告警一次。
  return onceRequest(req.url, {
    method: req.method, headers: req.headers, bodyBuf: buf,
    signal: req.signal, redirect: req.redirect || 'follow'
  }, 20, false);
}

// 覆盖 lazy 全局：必须用 defineProperty，不能用赋值（赋值可能触发 getter？
// 实际上赋值安全，但 defineProperty 更明确，且可保留 writable/configurable）。
// +ios5 关键修复：绝不覆盖 Headers / Request / Response / FormData。
// 它们是 dsh 后端 Web 框架（api-session-controller / client-connection）用来
// 构造响应、解析 multipart 的原生全局。旧版 +ios3/+ios4 把它们换成半成品
// Shim* 类后，服务端处理 /api/... POST 时抛异常并静默断开连接 —— Safari
// 里就表现为 fetch 报 "Load failed"（directoryPicker/list failed）。
// 现在 WASM stub 已能让内置 undici 加载期通过，这些原生全局可安全保留。
Object.defineProperty(globalThis, 'fetch', { value: shimFetch, writable: true, configurable: true, enumerable: false });

// WebSocket 也是内置 undici 的 lazy 全局：只要被「读」一次，就会加载
// node:internal/deps/undici/undici -> client-h1 -> llhttp WASM -> jitless 下
// 直接 "WebAssembly is not defined"。dsh 的 web profile 在启动期会碰它。
// 依赖树里自带 ws@8（纯 JS，不用 WASM），用它顶上，并把 undici 特有的
// 常量/静态成员补齐，避免 typeof 检查或属性读取失败。
try {
  const WS = require('ws');
  const WebSocketShim = WS.WebSocket || WS;
  if (WebSocketShim) {
    Object.defineProperty(globalThis, 'WebSocket', {
      value: WebSocketShim, writable: true, configurable: true, enumerable: false
    });
  }
} catch (e) {
  // 没有 ws 时给一个最小 stub，至少保证「读全局」不会加载内置 undici。
  class WebSocketStub {
    constructor() { throw new Error('WebSocket unavailable in dsh-ios no-WASM fallback'); }
  }
  Object.defineProperty(globalThis, 'WebSocket', {
    value: WebSocketStub, writable: true, configurable: true, enumerable: false
  });
}
// +ios5: FormData / File 保持原生（服务端的 multipart 解析依赖它）。
module.exports = { fetch: shimFetch, Headers: ShimHeaders, Request: ShimRequest, Response: ShimResponse };
