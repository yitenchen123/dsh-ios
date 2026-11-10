/* DSH_SAFARI16_POLYFILL
 * dsh-ios +ios4 —— Safari 16.7 / iOS 16.7 (iPhone X, A11) 浏览器兼容垫片
 *
 * 症状：手机 Safari 打开 dsh web 工作台，点「选择工作区目录」等弹窗报
 *   AbortSignal.any is not a function. (In 'AbortSignal.any([...])',
 *   'AbortSignal.any' is undefined)
 * 括号措辞是 JavaScriptCore(Safari/WebKit) 独有；V8(Node) 只会写 TypeError。
 * 所以报错在「手机浏览器里跑的前端」，与后端 node / 越狱 / .deb 无关。
 *
 * 根因：iPhone X (A11) 最高只能停在 iOS 16.7.x，WebKit 停在 Safari 16.6，
 * 而下面这批 API 都是 Safari 17.4 (iOS 17.4, 2024-03) 才加入的：
 *   AbortSignal.any() / Promise.withResolvers() / Object.groupBy /
 *   Map.groupBy / Array.fromAsync
 * iPhone 17 Pro Max (iOS 26) 的 WebKit 全部都有，所以「别人用正常」。
 * iOS 上换 Chrome/Edge/Firefox 无效 —— 全部强制使用系统 WebKit。
 * 换谁的 node、换哪个 dsh 移植包也一样，因为变量是设备 WebKit 版本。
 *
 * 策略：全部「特性检测 + 原生优先」——原生已存在就一个字节都不改，
 * 只补缺失项，因此对新设备零影响、可重复加载、幂等。实现按 WHATWG /
 * ECMAScript 规范，纯 ES2019 语法（不依赖任何新 API 自身）。
 *
 * 注入位置：index.html 的 <head> 内、所有 <script type="module"> 之前，
 * 用普通 <script src> 同步加载 —— module 默认 defer，故必然先执行本垫片，
 * 随后动态 import 的插件 client.js 也能拿到补齐后的全局。
 */
(function () {
  'use strict';
  var g = typeof globalThis !== 'undefined' ? globalThis : this;
  var hasOwn = Object.prototype.hasOwnProperty;

  // ---- 1. AbortSignal.any(iterable) : WHATWG DOM ----
  // 组合多个 signal；任一 abort 时结果 signal 随之 abort，reason 取触发者；
  // 输入里已有 aborted 则立即返回已 abort 的 signal；abort 后摘掉监听。
  if (typeof g.AbortSignal !== 'undefined' && typeof g.AbortController !== 'undefined'
      && typeof g.AbortSignal.any !== 'function') {
    Object.defineProperty(g.AbortSignal, 'any', {
      configurable: true, writable: true, enumerable: false,
      value: function any(signals) {
        var list = Array.from(signals || []);
        var controller = new g.AbortController();
        var settled = false;
        function cleanup() {
          for (var i = 0; i < list.length; i++) {
            try { list[i].removeEventListener('abort', onAbort); } catch (_) {}
          }
        }
        function finish(reason) {
          if (settled) return;
          settled = true;
          try { controller.abort(reason); } catch (_) { try { controller.abort(); } catch (__) {} }
          cleanup();
        }
        function onAbort(e) { finish(e && e.target ? e.target.reason : undefined); }
        for (var i = 0; i < list.length; i++) {
          if (list[i] && list[i].aborted) { finish(list[i].reason); return controller.signal; }
        }
        for (var j = 0; j < list.length; j++) {
          if (list[j] && typeof list[j].addEventListener === 'function') {
            list[j].addEventListener('abort', onAbort, { once: true });
          }
        }
        return controller.signal;
      }
    });
  }

  // ---- 2. Promise.withResolvers() ----
  // webserver 的 boot 脚本直接调用它，缺失会让 __DSH_BOOT_READY__ 永远悬空。
  if (typeof g.Promise !== 'undefined' && typeof g.Promise.withResolvers !== 'function') {
    Object.defineProperty(g.Promise, 'withResolvers', {
      configurable: true, writable: true, enumerable: false,
      value: function withResolvers() {
        var resolve, reject;
        var promise = new g.Promise(function (res, rej) { resolve = res; reject = rej; });
        return { promise: promise, resolve: resolve, reject: reject };
      }
    });
  }

  // ---- 3/4. Object.groupBy / Map.groupBy ----
  function addToObjectGroup(groups, key, value) {
    var k = typeof key === 'symbol' ? key : String(key);
    if (!hasOwn.call(groups, k)) {
      Object.defineProperty(groups, k, {
        value: [], writable: true, enumerable: true, configurable: true
      });
    }
    groups[k].push(value);
  }
  function groupBy(iterable, callbackfn, isMap) {
    if (typeof callbackfn !== 'function') throw new TypeError('groupBy callback must be callable');
    var groups = isMap ? new g.Map() : {};
    var i = 0;
    for (var it = iterable[g.Symbol.iterator](), step; !(step = it.next()).done;) {
      var value = step.value;
      var key = callbackfn(value, i++);
      if (isMap) {
        if (!groups.has(key)) groups.set(key, []);
        groups.get(key).push(value);
      } else {
        addToObjectGroup(groups, key, value);
      }
    }
    return groups;
  }
  if (typeof g.Object !== 'undefined' && typeof g.Object.groupBy !== 'function') {
    Object.defineProperty(g.Object, 'groupBy', {
      configurable: true, writable: true, enumerable: false,
      value: function (items, fn) { return groupBy(items, fn, false); }
    });
  }
  if (typeof g.Map !== 'undefined' && typeof g.Map.groupBy !== 'function') {
    Object.defineProperty(g.Map, 'groupBy', {
      configurable: true, writable: true, enumerable: false,
      value: function (items, fn) { return groupBy(items, fn, true); }
    });
  }

  // ---- 5. Array.fromAsync ----
  if (typeof g.Array !== 'undefined' && typeof g.Array.fromAsync !== 'function') {
    Object.defineProperty(g.Array, 'fromAsync', {
      configurable: true, writable: true, enumerable: false,
      value: async function fromAsync(items, mapfn, thisArg) {
        var out = [];
        var i = 0;
        var map = typeof mapfn === 'function' ? mapfn : null;
        var push = function (v) {
          return map ? Promise.resolve(map.call(thisArg, v, i++)).then(function (r) { out.push(r); })
                     : (out.push(v), i++, Promise.resolve());
        };
        if (items && (items[g.Symbol.asyncIterator] || items[g.Symbol.iterator])) {
          var src = items[g.Symbol.asyncIterator] ? items[g.Symbol.asyncIterator]() : items[g.Symbol.iterator]();
          for (;;) {
            var step = await src.next();
            if (step.done) break;
            await push(step.value);
          }
        } else if (items && typeof items.length === 'number') {
          for (var j = 0; j < items.length; j++) await push(await items[j]);
        }
        return out;
      }
    });
  }

  /* ======================================================================
   * +ios15 扩展：为「DSH 第三方生态插件」（运行时动态加载的 client.js）补齐
   * Safari 17.4+/18+ 才有的 API。真机自带前端 assets 基本不用这些，但生态
   * 插件（含 PDF.js 打包代码、新版 UI 挂件）会用到，缺一个就整页报
   * "xxx is not a function / is undefined"。全部特性检测 + 原生优先，
   * 新设备一个字节都不改。纯 ES2019 语法。
   * ====================================================================== */
  function def(obj, key, value) {
    if (!obj) return;
    if (hasOwn.call(obj, key) && obj[key] !== undefined) return;
    try { Object.defineProperty(obj, key, { configurable: true, writable: true, enumerable: false, value: value }); }
    catch (_) { try { obj[key] = value; } catch (__) {} }
  }

  // 6. Promise.try(fn, ...args)
  if (typeof g.Promise !== 'undefined' && typeof g.Promise.try !== 'function') {
    def(g.Promise, 'try', function (fn) {
      var args = Array.prototype.slice.call(arguments, 1);
      return new g.Promise(function (res) { res(fn.apply(undefined, args)); });
    });
  }

  // 7. RegExp.escape(str)
  if (typeof g.RegExp !== 'undefined' && typeof g.RegExp.escape !== 'function') {
    def(g.RegExp, 'escape', function (s) {
      return String(s).replace(/[\\^$.*+?()[\]{}|]/g, '\\$&');
    });
  }

  // 8. Symbol.dispose / Symbol.asyncDispose（using / await using 转译产物会引用）
  if (typeof g.Symbol !== 'undefined') {
    if (typeof g.Symbol.dispose === 'undefined') def(g.Symbol, 'dispose', g.Symbol('Symbol.dispose'));
    if (typeof g.Symbol.asyncDispose === 'undefined') def(g.Symbol, 'asyncDispose', g.Symbol('Symbol.asyncDispose'));
  }

  // 9. Array.prototype 的 change-array-by-copy / findLast 家族
  if (typeof g.Array !== 'undefined' && g.Array.prototype) {
    var AP = g.Array.prototype;
    if (typeof AP.toSorted !== 'function') def(AP, 'toSorted', function (fn) { return Array.prototype.slice.call(this).sort(fn); });
    if (typeof AP.toReversed !== 'function') def(AP, 'toReversed', function () { return Array.prototype.slice.call(this).reverse(); });
    if (typeof AP.toSpliced !== 'function') def(AP, 'toSpliced', function (start, del, /* ...items */) {
      var a = Array.prototype.slice.call(this);
      a.splice.apply(a, Array.prototype.slice.call(arguments));
      return a;
    });
    if (typeof AP.with !== 'function') def(AP, 'with', function (idx, val) {
      var a = Array.prototype.slice.call(this);
      var i = Number(idx) < 0 ? a.length + Number(idx) : Number(idx);
      if (i < 0 || i >= a.length) throw new RangeError('Invalid index in Array.prototype.with');
      a[i] = val; return a;
    });
    if (typeof AP.findLast !== 'function') def(AP, 'findLast', function (fn, t) {
      for (var i = this.length - 1; i >= 0; i--) if (fn.call(t, this[i], i, this)) return this[i];
      return undefined;
    });
    if (typeof AP.findLastIndex !== 'function') def(AP, 'findLastIndex', function (fn, t) {
      for (var i = this.length - 1; i >= 0; i--) if (fn.call(t, this[i], i, this)) return i;
      return -1;
    });
  }

  // 10. Uint8Array.prototype base64 / hex（Node 22 / Safari 18 API，浏览器常用）
  if (typeof g.Uint8Array !== 'undefined' && g.Uint8Array.prototype) {
    var U8 = g.Uint8Array;
    var B64 = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
    function toB64(bytes) {
      var out = '', i;
      for (i = 0; i < bytes.length; i += 3) {
        var a = bytes[i], b = bytes[i + 1], c = bytes[i + 2];
        out += B64[a >> 2];
        out += B64[((a & 3) << 4) | ((b === undefined ? 0 : b) >> 4)];
        out += b === undefined ? '=' : B64[((b & 15) << 2) | ((c === undefined ? 0 : c) >> 6)];
        out += c === undefined ? '=' : B64[c & 63];
      }
      return out;
    }
    function fromB64(str) {
      var s = String(str).replace(/[\s=]/g, ''), out = [], i;
      for (i = 0; i < s.length; i += 4) {
        var n0 = B64.indexOf(s[i]), n1 = B64.indexOf(s[i + 1]), n2 = B64.indexOf(s[i + 2]), n3 = B64.indexOf(s[i + 3]);
        out.push((n0 << 2) | (n1 >> 4));
        if (n2 >= 0) out.push(((n1 & 15) << 4) | (n2 >> 2));
        if (n3 >= 0) out.push(((n2 & 3) << 6) | n3);
      }
      return new U8(out);
    }
    if (typeof U8.prototype.toBase64 !== 'function') def(U8.prototype, 'toBase64', function () { return toB64(this); });
    if (typeof U8.prototype.toHex !== 'function') def(U8.prototype, 'toHex', function () {
      var h = '0123456789abcdef', out = '';
      for (var i = 0; i < this.length; i++) out += h[this[i] >> 4] + h[this[i] & 15];
      return out;
    });
    if (typeof U8.fromBase64 !== 'function') def(U8, 'fromBase64', fromB64);
    if (typeof U8.prototype.setFromBase64 !== 'function') def(U8.prototype, 'setFromBase64', function (str) {
      var n = fromB64(str), i;
      for (i = 0; i < Math.min(n.length, this.length); i++) this[i] = n[i];
      return { read: Math.min(n.length, this.length), written: Math.min(n.length, this.length) };
    });
    if (typeof U8.prototype.setFromHex !== 'function') def(U8.prototype, 'setFromHex', function (str) {
      var s = String(str), out = [], i;
      for (i = 0; i + 1 < s.length; i += 2) out.push(parseInt(s.substr(i, 2), 16));
      for (i = 0; i < Math.min(out.length, this.length); i++) this[i] = out[i];
      return { read: Math.min(out.length * 2, this.length), written: Math.min(out.length, this.length) };
    });
    if (typeof U8.fromHex !== 'function') def(U8, 'fromHex', function (str) {
      var s = String(str), out = [];
      if (s.length % 2) throw new SyntaxError('Invalid hex string');
      for (var i = 0; i < s.length; i += 2) {
        var v = parseInt(s.substr(i, 2), 16);
        if (isNaN(v)) throw new SyntaxError('Invalid hex string');
        out.push(v);
      }
      return new U8(out);
    });
  }

  // 11. Iterator.from / URL.canParse / ArrayBuffer.prototype.transfer
  if (typeof g.Iterator !== 'undefined' && typeof g.Iterator.from !== 'function') {
    def(g.Iterator, 'from', function (o) {
      if (o && typeof o[g.Symbol.iterator] === 'function') return o[g.Symbol.iterator]();
      return (function* () { for (var k in o) yield o[k]; })();
    });
  }
  if (typeof g.URL !== 'undefined' && typeof g.URL.canParse !== 'function') {
    def(g.URL, 'canParse', function (u, base) {
      try { new g.URL(u, base); return true; } catch (_) { return false; }
    });
  }
  if (typeof g.ArrayBuffer !== 'undefined' && g.ArrayBuffer.prototype
      && typeof g.ArrayBuffer.prototype.transfer !== 'function') {
    def(g.ArrayBuffer.prototype, 'transfer', function (len) {
      var n = len === undefined ? this.byteLength : len;
      var dst = new g.ArrayBuffer(n);
      new g.Uint8Array(dst).set(new g.Uint8Array(this, 0, Math.min(n, this.byteLength)));
      return dst;
    });
  }

  // 12. Float16Array（Safari 18+；生态 PDF/数值插件可能引用）。给最小可用实现：
  //     基于 Uint16 位模式 + DataView 半精度换算，保证「new/读写/length」不抛错。
  if (typeof g.Float16Array === 'undefined' && typeof g.DataView !== 'undefined') {
    function halfToFloat(h) {
      var s = (h & 0x8000) >> 15, e = (h & 0x7C00) >> 10, f = h & 0x03FF;
      if (e === 0) return (s ? -1 : 1) * Math.pow(2, -14) * (f / 1024);
      if (e === 31) return f ? NaN : (s ? -Infinity : Infinity);
      return (s ? -1 : 1) * Math.pow(2, e - 15) * (1 + f / 1024);
    }
    function floatToHalf(x) {
      if (!isFinite(x)) return x === Infinity ? 0x7C00 : (x === -Infinity ? 0xFC00 : 0x7E00);
      var v = Math.fround ? Math.fround(x) : x;
      var buf = new g.ArrayBuffer(4), dv = new g.DataView(buf);
      dv.setFloat32(0, v); var bits = dv.getUint32(0);
      var s = (bits >> 16) & 0x8000, e = ((bits >> 23) & 0xFF) - 127 + 15, f = (bits >> 13) & 0x3FF;
      if (e <= 0) return s | (f ? 0 : 0);
      if (e >= 31) return s | 0x7C00;
      return s | (e << 10) | f;
    }
    function F16(n) {
      if (!(this instanceof F16)) return new F16(n);
      var len = n && typeof n === 'object' && typeof n.length === 'number' ? n.length : (Number(n) || 0);
      this._u = new g.Uint16Array(len);
      this.length = len;
      if (n && typeof n === 'object' && typeof n.length === 'number') {
        for (var i = 0; i < len; i++) this._u[i] = floatToHalf(Number(n[i]));
      }
    }
    Object.defineProperty(F16.prototype, 0, { get: function () { return halfToFloat(this._u[0]); }, set: function (v) { this._u[0] = floatToHalf(v); }, configurable: true });
    F16.prototype[Symbol.iterator] = function* () { for (var i = 0; i < this.length; i++) yield halfToFloat(this._u[i]); };
    F16.from = function (src) { return new F16(src); };
    F16.of = function () { return new F16(Array.prototype.slice.call(arguments)); };
    try { def(g, 'Float16Array', F16); } catch (_) {}
  }
})();
