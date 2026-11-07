#!/bin/sh
# ============================================================================
# dsh-ios —— Safari 16 / iOS 16.7 (iPhone X, A11) 前端兼容垫片热修复  +ios4
#
# 症状：手机 Safari 打开 dsh web 工作台，点「选择工作区目录」等弹窗报
#       AbortSignal.any is not a function. (In 'AbortSignal.any([...])',
#       'AbortSignal.any' is undefined)
# 根因：AbortSignal.any / Promise.withResolvers / Object.groupBy / Map.groupBy
#       / Array.fromAsync 都是 Safari 17.4 (iOS 17.4) 才有的 Web API；
#       iPhone X (A11) 只能停在 iOS 16.7，WebKit 16.6 全都没有。
#       报错在「手机浏览器里跑的前端」，与后端 node / 越狱 / .deb 无关。
#       iPhone 17 Pro Max (iOS 26) 原生全有，所以别人用正常；换包、换
#       Chrome/Edge 都没用（iOS 强制系统 WebKit）。
#
# 修法：在已安装前端补一个 polyfill，并让 index.html 在所有 module 脚本
#       之前同步加载它。不重传 113MB deb，几秒生效；可重复执行（幂等）。
#       垫片全部「特性检测 + 原生优先」，新设备上一个字节都不改。
#
# 用法（iPhone 终端）：sh fix-safari16.sh
# 之后回 Safari 强制刷新页面（设置 → Safari → 清除历史记录与网站数据，
# 或长按刷新键 → 无缓存刷新）。无需重启 dsh、无需重装 deb。
# ============================================================================
set -eu

DIST=/var/jb/usr/lib/dsh/node_modules/@deepseek-ai/dsh-web-frontend/dist
POLY="$DIST/assets/safari16-polyfill.js"
HTML="$DIST/index.html"

if [ ! -f "$HTML" ]; then
    echo "[FAIL] 找不到 $HTML"
    echo "       确认已安装 dsh-ios 的 .deb；若前端在别的路径，改本脚本 DIST= 即可。"
    exit 1
fi

# 1) 写出 polyfill（静态资源为目录遍历式 serve，新增文件可直接加载）
cat > "$POLY" <<'DSH_POLYFILL_EOF'
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
DSH_POLYFILL_EOF
chmod 644 "$POLY"
echo "[ ok ] 已写入 assets/safari16-polyfill.js ($(wc -c < "$POLY" | tr -d ' ') 字节)"

# 2) 让 index.html 在任何 <script type=module> 之前同步加载 polyfill。
#    普通 <script src> 在 <head> 中阻塞解析、立即执行；module 默认 defer，
#    顺序必然是先垫片、后前端代码；运行时动态 import 的插件也覆盖到。
#    webserver 会把 index.html 过一遍 renderIndex（注入 base/rows），但保留
#    原有标签，所以这里改磁盘上的 index.html 是持久生效的。
if grep -q 'safari16-polyfill.js' "$HTML"; then
    echo "[skip] index.html 已注入过，未重复插入"
else
    if awk '/<head[^>]*>/{ print; print "    <script src=\"./assets/safari16-polyfill.js\"></script>"; hit=1; next } { print } END{ if(!hit) exit 3 }' "$HTML" > "$HTML.dshtmp"; then
        mv "$HTML.dshtmp" "$HTML"
        echo "[ ok ] index.html 已注入 polyfill 引用"
    else
        rm -f "$HTML.dshtmp"
        echo "[FAIL] index.html 里找不到 <head> 标签，未改动原文件"
        exit 1
    fi
fi

# 3) 校验
if grep -q 'safari16-polyfill.js' "$HTML" && [ -s "$POLY" ]; then
    echo "[ ok ] 校验通过：垫片已就位且被页面引用"
    echo
    echo "完成。回 Safari 强制刷新 dsh 工作台页面即可，无需重启 dsh、无需重装 deb。"
else
    echo "[FAIL] 校验未通过"; exit 1
fi
