#!/usr/bin/env node
/*
 * dsh-plugin-compat.cjs —— +ios12 装后兼容补丁（幂等、全副本覆盖）
 *
 * 本版不再预装 @xmanrui/dsh-im / @tencent-connect/dsh-qqbot，插件一律由
 * `dsh plugin --profile web add <包名>` 安装。但 A11 的 nowasm 档
 * (--jitless --no-expose-wasm) 会让 dsh-im 内联的 libsignal WASM glue 在
 * 模块顶层实例化失败：
 *     TypeError: ge.lthashantitampering_new is not a function
 * 从而整包 import 失败（+ios9 修过）。
 *
 * 所以装完 dsh-im 后要跑一次本脚本：
 *     dsh-compat              或  node dsh-plugin-compat.cjs
 * 它扫描 $DSH_HOME 与包目录下**所有** @xmanrui/dsh-im/lib/index.js 逐份
 * 补补丁（精确替换优先，变量名被改写过的构建走正则反查兜底），幂等。
 * 不写 cordis.patch.yml、不建软链、不改属主，只改插件自身的这一处代码。
 *
 * 用法: node dsh-plugin-compat.cjs [搜索根...]
 * 退出码: 0=全部副本已就绪；1=有副本补不了（会打印路径）
 */
'use strict';
const fs = require('node:fs');
const path = require('node:path');

const MARK = 'dsh-ios +ios9';
const TOP = 'var JCe=new VC;';
const FIN = 'let e=JCe.subtractThenAdd(t,a,o);';
const NEWTOP = 'var JCe=null;try{JCe=new VC}catch(_dshImWasmErr){}/* dsh-ios +ios9: libsignal WASM unavailable */';
const NEWFIN = 'let e=JCe?JCe.subtractThenAdd(t,a,o):Buffer.alloc(128);/* dsh-ios +ios9: degrade */';

function patchOne(p) {
  let s;
  try { s = fs.readFileSync(p, 'utf8'); } catch { return 'unreadable'; }
  if (s.includes(MARK)) return 'skip';
  const c1 = s.split(TOP).length - 1, c2 = s.split(FIN).length - 1;
  if (c1 === 1 && c2 === 1) {
    s = s.replace(TOP, NEWTOP).replace(FIN, NEWFIN);
  } else {
    // 变量名被改写过的构建：由 subtractThenAdd 反查单例变量名。
    const mm = /let\s+([A-Za-z_$][\w$]*)=([A-Za-z_$][\w$]*)\.subtractThenAdd\(([^)]*)\);/.exec(s);
    if (!mm) return 'no-finish';
    const V = mm[2];
    const topRe = new RegExp('var\\s+' + V + '=new\\s+([A-Za-z_$][\\w$]*);');
    const tm = topRe.exec(s);
    if (!tm) return 'no-top';
    s = s.replace(tm[0], 'var ' + V + '=null;try{' + V + '=new ' + tm[1] + '}catch(_dshImWasmErr){}/* dsh-ios +ios9: libsignal WASM unavailable */');
    s = s.replace(mm[0], 'let ' + mm[1] + '=' + V + '?' + V + '.subtractThenAdd(' + mm[3] + '):Buffer.alloc(128);/* dsh-ios +ios9: degrade */');
  }
  try { fs.writeFileSync(p, s); } catch (e) { return 'readonly:' + e.code; }
  return 'patched';
}

/* 递归找 @xmanrui/dsh-im/lib/index.js，限深度，跳过符号链接环 */
function findCopies(root, out, depth) {
  if (depth > 14) return;
  let ents;
  try { ents = fs.readdirSync(root, { withFileTypes: true }); } catch { return; }
  for (const e of ents) {
    if (!e.isDirectory() || e.isSymbolicLink()) continue;
    const p = path.join(root, e.name);
    if (e.name === 'dsh-im' && path.basename(path.dirname(p)) === '@xmanrui') {
      const f = path.join(p, 'lib', 'index.js');
      try { if (fs.statSync(f).isFile()) out.add(f); } catch {}
      continue;
    }
    findCopies(p, out, depth + 1);
  }
}

const roots = process.argv.slice(2);
if (roots.length === 0) {
  const home = process.env.DSH_HOME || '/var/jb/var/mobile/.dsh';
  roots.push(home, '/var/jb/usr/lib/dsh/node_modules');
}
const files = new Set();
for (const r of roots) findCopies(r, files, 0);

if (files.size === 0) {
  console.log('[ ok ] 未找到 @xmanrui/dsh-im 副本（未安装该插件时属正常）');
  process.exit(0);
}
let bad = 0, patched = 0, skipped = 0;
for (const f of [...files].sort()) {
  const r = patchOne(f);
  if (r === 'patched') { patched++; console.log('[ ok ] 已补零 JIT 补丁: ' + f); }
  else if (r === 'skip') { skipped++; }
  else { bad++; console.error('[FAIL] ' + r + ': ' + f); }
}
console.log(`[汇总] ${files.size} 份副本 / 新补 ${patched} / 已就绪 ${skipped} / 失败 ${bad}`);
if (bad) {
  console.error('补不了的副本多为 root 属主；先跑 sh fix-ios12.sh 修目录属主，或删掉旧安装用 dsh plugin add 重装。');
  process.exit(1);
}
process.exit(0);
