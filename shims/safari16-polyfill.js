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
})();
