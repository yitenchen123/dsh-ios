#!/usr/bin/env node
/*
 * dsh-home-heal.cjs —— +ios12 用户数据目录自愈（免 root）
 *
 * 真机症状（用户反馈「无法创建新对话」）:
 *   新建会话失败: gateway/internal: failed to create session:
 *   Error: EACCES: permission denied, open
 *   '/var/jb/var/mobile/.dsh/sessions/--private-preboot-...-DSH--/
 *    session-0395036a.../session.v4.jsonl'
 *
 * 根因: 另一个 AI 曾以 root + .zshenv 包装器跑过 dsh，把 $DSH_HOME 下的
 * sessions/、profiles/ 整棵目录树和 cordis.patch.yml 建成 root 属主。用户
 * 以 mobile 敲 dsh 时写不进去；gateway 建不了会话，pnpm 写不了 package.json，
 * 依赖会话的插件自然「未运行」。旧 doctor 只测 $DSH_HOME 顶层可写（postinst
 * chmod 过），没测子目录 —— 假绿灯。
 *
 * 免 root 修法（已用 nobody 身份对 root:root 444 文件/755 目录树实测）:
 *   只要 $DSH_HOME 本身可写，就能用 rename(2) 交换整棵目录树。
 *   关键陷阱：不能「先 rename 走旧树、再把内容搬回来」—— 那个搬回动作
 *   需要**源目录**可写，而源目录恰恰是 root 属主，必然 EACCES（会留下空
 *   目录，比不修更糟）。正确顺序是：
 *     1) 在 $DSH_HOME 下复制一棵全新的树（只需对旧树有【读】权限）；
 *        新树每个目录 0700、每个文件 0600，全部归当前用户。
 *     2) rename(旧树 -> *-legacy-root-<ts>)     只需 $DSH_HOME 可写
 *     3) rename(新树 -> 原路径)                 只需 $DSH_HOME 可写
 *   单文件同理：读内容 -> 同目录写临时文件 -> rename 覆盖。
 *
 * 同时清理 +ios7/+ios9 预装时代留下的用户层痕迹（本版起不再预装插件）:
 *   - cordis.patch.yml 里 id: im-qqbot / xmanrui-dsh-im 的整个 - insert: 块
 *     （整块删，绝不逐行 grep -v，那会把 YAML 拆坏 —— +ios11 踩过坑）
 *   - $DSH_HOME/node_modules 软链，仅当它指向包内 node_modules；用户自己
 *     dsh plugin add 建的真实目录绝不碰。
 *
 * 幂等、每次启动都跑（修好后只做 stat，开销极小）。
 * 输出全部走 stderr，不污染 `dsh --dump-config` 的 stdout。
 * 用法: node dsh-home-heal.cjs <DSH_HOME> [DSH_PKG_DIR]
 */
'use strict';
const fs = require('node:fs');
const path = require('node:path');

const HOME = process.argv[2] || process.env.DSH_HOME || '/var/jb/var/mobile/.dsh';
const PKG = process.argv[3] || process.env.DSH_PKG_DIR || '/var/jb/usr/lib/dsh';

let fixed = 0, warned = 0;
const log = (s) => process.stderr.write(s + '\n');

function lstat(p) { try { return fs.lstatSync(p); } catch { return null; } }
function writable(p) { try { fs.accessSync(p, fs.constants.W_OK); return true; } catch { return false; } }
function readable(p) { try { fs.accessSync(p, fs.constants.R_OK); return true; } catch { return false; } }

/* 整棵树是否对当前用户可写（限深度，用于判断要不要修）。
   +ios14：目录和【文件】都要查。真机截图里 EACCES 落在
   .../session--0395036a.../session.v4.jsonl —— 目录全可写、但那个
   session.v4.jsonl 是 root 属主 444；旧版只看目录就会判定「无需修」
   然后跳过整棵树，doctor 也因只测顶层 -w 而假绿。 */
function treeWritable(p, depth, max) {
  if (!writable(p)) return false;
  if (depth >= max) return true;
  let ents;
  try { ents = fs.readdirSync(p, { withFileTypes: true }); } catch { return false; }
  for (const e of ents) {
    const c = path.join(p, e.name);
    if (e.isDirectory() && !e.isSymbolicLink()) {
      if (!treeWritable(c, depth + 1, max)) return false;
    } else if (e.isFile() && !writable(c)) {
      return false;
    }
  }
  return true;
}

/* 原子替换单个文件：把 root 属主 / 不可写文件换成当前用户拥有的新文件。
   目录带 sticky 时 rename 覆盖不了别人的文件，先 unlink 再 rename。 */
function atomicReplace(p, content, mode) {
  const tmp = path.join(path.dirname(p), `.heal-${process.pid}-${Math.random().toString(36).slice(2)}`);
  try {
    fs.writeFileSync(tmp, content, { mode: mode || 0o600 });
    try { fs.renameSync(tmp, p); }
    catch (e) {
      if (e.code !== 'EPERM' && e.code !== 'EACCES') throw e;
      fs.unlinkSync(p);
      fs.renameSync(tmp, p);
    }
    return true;
  } catch (e) {
    try { fs.unlinkSync(tmp); } catch {}
    return e.code || e.message;
  }
}

/* 复制一棵树到新位置：只要求 src 可读、dst 的父目录可写。
   新树目录 0700 / 文件 0600，全部归当前用户；符号链接原样重建。
   +ios14：HOME 整树交换时可跳过顶层可重建缓存目录（pnpm store 等），
   避免为几个 GB 的缓存做全量复制；profiles 下的 node_modules 在深层，
   depth=0 才跳过，绝不误删用户自己装的插件。 */
const CACHE_DIRS = new Set([
  'pnpm', 'pnpm-data', 'pnpm-cache', 'npm-cache', 'store', 'cache',
  'node_modules', '.cache', '.npm', '.pnpm-store',
]);
let cloned = 0, skippedCaches = 0, unreadable = 0;
function cloneTree(src, dst, skipCaches = false, depth = 0) {
  if (++cloned > 50000) throw new Error('too many files');
  fs.mkdirSync(dst, { recursive: true });
  try { fs.chmodSync(dst, 0o700); } catch {}
  let ents;
  try { ents = fs.readdirSync(src, { withFileTypes: true }); } catch { return; }
  for (const e of ents) {
    const s = path.join(src, e.name), d = path.join(dst, e.name);
    if (e.isDirectory() && !e.isSymbolicLink()) {
      if (skipCaches && depth === 0 && CACHE_DIRS.has(e.name)) { skippedCaches++; continue; }
      cloneTree(s, d, skipCaches, depth + 1);
    } else if (e.isSymbolicLink()) {
      try { fs.symlinkSync(fs.readlinkSync(s), d); } catch {}
    } else if (e.isFile()) {
      // +ios14：读不到的文件（root 600）不再静默丢，计数并告警。
      try { fs.copyFileSync(s, d); fs.chmodSync(d, 0o600); }
      catch { unreadable++; }
    }
  }
}

/* 目录树自愈：复制新树 -> 两次 rename 原子交换。旧树完整保留备份。 */
function healTreeBySwap(target, label) {
  const st = lstat(target);
  if (!st || !st.isDirectory()) return;
  if (treeWritable(target, 0, 6)) return;      // 全可写，无需动

  const stamp = Date.now() + '-' + Math.random().toString(36).slice(2, 6);
  const fresh = target + '-fresh-' + stamp;
  const legacy = target + '-legacy-root-' + stamp;
  cloned = 0;
  try {
    cloneTree(target, fresh);
  } catch (e) {
    log(`[warn] ${label} 复制新树失败: ${e.code || e.message}`);
    warned++;
    try { fs.rmSync(fresh, { recursive: true, force: true }); } catch {}
    return;
  }
  try { fs.renameSync(target, legacy); }
  catch (e) {
    log(`[warn] ${label} 无法搬走旧树 (${e.code})`); warned++;
    try { fs.rmSync(fresh, { recursive: true, force: true }); } catch {}
    return;
  }
  try { fs.renameSync(fresh, target); }
  catch (e) {
    // 交换失败必须回滚，绝不能把用户数据留在半空状态
    try { fs.renameSync(legacy, target); } catch {}
    log(`[warn] ${label} 交换失败，已回滚 (${e.code})`); warned++;
    return;
  }
  log(`[fixed] ${label} 目录树属主已修复（${cloned} 项完整复制，旧树在 ${path.basename(legacy)}）`);
  fixed++;
}

/* +ios14 —— $DSH_HOME 本身的自愈。
   这是真机「新建会话 EACCES」的真正根因：main() 原第一行
     if (!writable(HOME)) { warn; return; }
   只要 $DSH_HOME 被 root 建过（555/755 且属主 root），后面 sessions/
   profiles/patch 的全部自愈一行都没跑，gateway 在深层 mkdir 或 open
   session.v4.jsonl 就 EACCES。已用 nobody + root 555 目录树 1:1 复现。

   两级修法（都不需要 root 权限）:
     1) 属主是自己、只是权限不够 -> chmod 0700；
     2) 属主是别人、但父目录可写 -> 复制一棵 0700/0600 新树后两次
        rename 原子交换 HOME。顶层 pnpm store / cache 等可重建缓存跳过。
   父目录也不可写时免 root 无解，打印明确命令，不再假装修好。 */
function healHomeBySwap() {
  try {
    fs.chmodSync(HOME, 0o700);
    if (writable(HOME)) {
      log('[fixed] $DSH_HOME 权限已修复（0700）');
      fixed++;
      return true;
    }
  } catch {}

  const parent = path.dirname(HOME);
  if (!writable(parent)) {
    log(`[warn] $DSH_HOME 不可写 (${HOME})，父目录 ${parent} 也不可写；免 root 无法修属主。`);
    log('[warn] 请以 root 执行: chown -R $(id -u):$(id -g) "$DSH_HOME"  或重装 +ios14 deb');
    warned++;
    return false;
  }

  const stamp = Date.now() + '-' + Math.random().toString(36).slice(2, 6);
  const fresh = HOME + '-fresh-' + stamp;
  const legacy = HOME + '-legacy-root-' + stamp;
  cloned = 0; skippedCaches = 0; unreadable = 0;
  try {
    cloneTree(HOME, fresh, true, 0);
  } catch (e) {
    log(`[warn] $DSH_HOME 复制新树失败: ${e.code || e.message}`);
    warned++;
    try { fs.rmSync(fresh, { recursive: true, force: true }); } catch {}
    return false;
  }
  try { fs.renameSync(HOME, legacy); }
  catch (e) {
    // sticky 位父目录（如 /tmp）会拒绝 rename 别人的目录；真机
    // /var/jb/var/mobile/ 不是 sticky，但这里仍给出可执行的 root 兜底。
    log(`[warn] $DSH_HOME 无法搬走旧树 (${e.code})；免 root 无法修属主。`);
    log('[warn] 请以 root 执行: chown -R 501:501 "$DSH_HOME" && chmod -R u+rwX "$DSH_HOME"');
    warned++;
    try { fs.rmSync(fresh, { recursive: true, force: true }); } catch {}
    return false;
  }
  try { fs.renameSync(fresh, HOME); }
  catch (e) {
    try { fs.renameSync(legacy, HOME); } catch {}
    log(`[warn] $DSH_HOME 交换失败，已回滚 (${e.code})`);
    warned++;
    return false;
  }
  log(`[fixed] $DSH_HOME 属主已修复（${cloned} 项，跳过 ${skippedCaches} 个可重建缓存目录；` +
      `旧树在 ${path.basename(legacy)}）`);
  if (unreadable > 0) log(`[warn] ${unreadable} 个 root 600 文件读不到，未迁入新树（旧树保留可救回）`);
  fixed++;
  return true;
}

/* +ios14 —— root 身份跑 heal 时的假绿修正。
   若 dsh web 是 root 常驻进程（历史根因：另一个 AI 用 root + .zshenv
   包装器跑过 dsh），以 root 跑 dsh-doctor / sudo 热修时 access(W_OK)
   全为 true，treeWritable 会判定「无需修」，但 mobile 用户/降权 worker
   依旧写不进去。此时 root 有能力直接 chown，主动把 root 属主的树交给
   mobile（iOS 固定 uid/gid 501），并统一放权。root 自身不受影响。 */
let chowned = 0;
function fixRootOwnedTree(p, depth) {
  if (depth > 12 || chowned > 20000) return;
  let st;
  try { st = fs.lstatSync(p); } catch { return; }
  if (st.uid === 0) {
    try {
      if (st.isSymbolicLink()) fs.lchownSync(p, MOBILE_UID, MOBILE_GID);
      else fs.chownSync(p, MOBILE_UID, MOBILE_GID);
      chowned++;
    } catch {}
  }
  try { fs.chmodSync(p, st.isDirectory() ? 0o700 : 0o600); } catch {}
  if (!st.isDirectory() || st.isSymbolicLink()) return;
  let ents;
  try { ents = fs.readdirSync(p, { withFileTypes: true }); } catch { return; }
  for (const e of ents) fixRootOwnedTree(path.join(p, e.name), depth + 1);
}
const _sudoUid = Number(process.env.SUDO_UID);
const _sudoGid = Number(process.env.SUDO_GID);
const MOBILE_UID = (_sudoUid > 0 && _sudoUid < 65535) ? _sudoUid : 501;
const MOBILE_GID = (_sudoGid > 0 && _sudoGid < 65535) ? _sudoGid : 501;

/* +ios14 兜底：即便目录树自愈因故没触发，也逐个修好不可写的会话文件。
   root 444 的 session.v4.jsonl 正是 open(..., 'w') 报 EACCES 的直接对象。 */
function healSessionFiles() {
  const root = path.join(HOME, 'sessions');
  const stack = [root];
  let n = 0;
  while (stack.length && n < 20000) {
    const d = stack.pop();
    let ents;
    try { ents = fs.readdirSync(d, { withFileTypes: true }); } catch { continue; }
    for (const e of ents) {
      const p = path.join(d, e.name);
      if (e.isDirectory() && !e.isSymbolicLink()) stack.push(p);
      else if (e.isFile() && n++ < 20000 && !writable(p)) healFile(path.relative(HOME, p));
    }
  }
}

/* 单文件自愈（顶层配置、profile 里的 package.json 等） */
function healFile(rel) {
  const p = path.join(HOME, rel);
  const st = lstat(p);
  if (!st || (!st.isFile() && !st.isSymbolicLink())) return;
  if (writable(p)) return;
  if (!readable(p)) { log(`[warn] ${rel} 不可读，跳过`); warned++; return; }
  let content;
  try { content = fs.readFileSync(p); } catch (e) { log(`[warn] ${rel} 读取失败 ${e.code}`); warned++; return; }
  const r = atomicReplace(p, content, 0o600);
  if (r === true) { log(`[fixed] ${rel} 属主/权限已修复`); fixed++; }
  else { log(`[warn] ${rel} 无法替换: ${r}`); warned++; }
}

/* ---------------------------------------------------------------------------
 * +ios13：patch 文件清理（修 dsh 启动 fatal + headless ERR_MODULE_NOT_FOUND）
 *
 * dsh-app-boot 的 readProfilePatches 会读【两类】patch 文件：
 *   $DSH_HOME/cordis.patch.yml
 *   $DSH_HOME/profiles/<name>/cordis.patch.yml
 * 然后 parsePatchList 在 index.js:4000 硬性要求「顶层是 YAML 数组」：
 *   if (!Array.isArray(parsed)) throw new Error("patches: patches.yml/
 *       cordis.patch.yml must be a top-level YAML array of loader patch entries")
 * 官方模板 PROFILE_PATCH_TEMPLATE 就是 "[]"。
 *
 * +ios12 的 cleanPatch() 有两个致命缺陷（真机截图已 1:1 复现）：
 *   1) 只处理 home 级，profiles/headless/cordis.patch.yml 里残留的两条
 *      - insert: 完全没清 -> headless boot 撞 ERR_MODULE_NOT_FOUND。
 *   2) 把 home 级两条块整块删掉后，若文件原本只有这两块，就写成纯注释；
 *      js-yaml.load 返回 null -> 用户敲 dsh 直接 fatal uncaught exception。
 *      更糟的是 dsh-doctor 第 15 项会触发这次清理并报 OK，于是出现
 *      「doctor 全绿、一敲 dsh 就崩」。
 *
 * 本版：全量扫描 + 删块后强制保证顶层是合法 YAML 数组（空则写 []），
 * 并且能修复真机上已经被 +ios12 删坏的文件（含纯注释 / 空 / null）。
 * 严格只按 id 匹配（im-qqbot / xmanrui-dsh-im），用户自己 dsh plugin add
 * 生成的块 id 不同，一律保留。
 * ------------------------------------------------------------------------- */

/* 目标块：旧预装时代写入的两条挂载。只认 id，不认包名，绝不误删用户插件。 */
const RE_TARGET = /^\s*-?\s*id:\s*['"]?(?:im-qqbot|xmanrui-dsh-im)['"]?\s*(?:#.*)?$/m;

/* 纯文本判定「顶层是否为合法 YAML 数组」。
   不 require js-yaml —— 本脚本会被热修从 /tmp 直接跑，那里解析不到包内模块。
   返回 false 的情况：空文件 / 纯注释 / null / 顶层是对象或标量。 */
function patchLooksValid(text) {
  if (!text) return false;
  let sawItem = false;
  for (const raw of text.split('\n')) {
    const line = raw.replace(/\s+$/, '');
    if (!line.trim() || /^\s*#/.test(line)) continue;
    if (/^\s*(?:---|\.\.\.)\s*(?:#.*)?$/.test(line)) continue;
    // ★ 缩进行是「当前数组项的内容」（- insert: 下的 - id: / name: 等），
    //   不影响顶层类型判定，必须跳过。否则会把合法数组误判成非数组，
    //   进而把用户自己 dsh plugin add 装的块一起重置掉（真机回归）。
    if (/^\s/.test(line)) continue;
    if (/^\[\s*\]\s*(?:#.*)?$/.test(line.trim())) return true;  // 显式空数组
    if (/^-\s/.test(line) || /^-$/.test(line)) { sawItem = true; continue; }
    return false;                                                // 顶格键/标量
  }
  return sawItem;
}

/* 写 patch 文件：兼容 root 属主、只读、软链三种历史遗留形态。
   目录树自愈在 main() 里先跑完，这里父目录一般已可写。 */
function writePatch(p, content, label) {
  const st = lstat(p);
  if (st && st.isSymbolicLink()) {
    try { fs.unlinkSync(p); }
    catch (e) { log(`[warn] ${label} 软链无法移除 ${e.code}`); warned++; return false; }
  }
  const cur = lstat(p);
  if (cur && cur.isFile() && writable(p)) {
    try { fs.writeFileSync(p, content, { mode: 0o600 }); return true; }
    catch { /* 落到原子替换 */ }
  }
  const r = atomicReplace(p, Buffer.from(content), 0o600);
  if (r !== true) { log(`[warn] ${label} 写入失败: ${r}`); warned++; return false; }
  return true;
}

/* 清理单个 patch 文件：整块删目标 + 保证顶层数组 + 幂等。 */
function cleanPatchFile(p, label) {
  if (!lstat(p)) return;
  let text;
  try { text = fs.readFileSync(p, 'utf8'); }
  catch (e) { log(`[warn] ${label} 读取失败 ${e.code}`); warned++; return; }

  const hasTarget = RE_TARGET.test(text);
  const valid = patchLooksValid(text);
  if (!hasTarget && valid) return;                 // 幂等：既干净又合法

  const lines = text.split('\n');
  const out = [];
  let i = 0, removed = 0;
  // 文件头部注释 / 文档标记原样保留
  while (i < lines.length && !/^-\s/.test(lines[i]) && !/^-$/.test(lines[i])) {
    out.push(lines[i]); i++;
  }
  // 按顶层 "- " 切块，整块丢弃或整块保留（绝不逐行 grep -v）
  while (i < lines.length) {
    const block = [lines[i]];
    let j = i + 1;
    while (j < lines.length && !/^-\s/.test(lines[j]) && !/^-$/.test(lines[j])) {
      block.push(lines[j]); j++;
    }
    if (RE_TARGET.test(block.join('\n'))) removed++;
    else out.push(...block);
    i = j;
  }

  let next = out.join('\n').replace(/\n{3,}/g, '\n\n').replace(/\s+$/, '');
  // ★ 关键：删空 / 原本就是纯注释 / 非数组，一律写成官方模板 []
  if (!patchLooksValid(next)) next = '[]';
  next += '\n';
  if (next === text) return;                      // 幂等复跑零写入

  if (!writePatch(p, next, label)) return;
  if (removed > 0) {
    log(`[fixed] ${label}: 移除 ${removed} 条旧预装挂载（用户自装块保留）`);
  } else {
    log(`[fixed] ${label}: 顶层不是 YAML 数组（+ios12 删坏残留），已重置为 []`);
  }
  fixed++;
}

/* 扫描 home 级 + 所有 profile 级 patch 文件。 */
function cleanAllPatches() {
  const rels = ['cordis.patch.yml', 'patches.yml'];
  for (const r of rels) cleanPatchFile(path.join(HOME, r), r);
  const pdir = path.join(HOME, 'profiles');
  let ents = [];
  try { ents = fs.readdirSync(pdir, { withFileTypes: true }); } catch { return; }
  for (const e of ents) {
    if (!e.isDirectory() && !e.isSymbolicLink()) continue;
    for (const r of rels) {
      cleanPatchFile(path.join(pdir, e.name, r), `profiles/${e.name}/${r}`);
    }
  }
}

/* 只删「我们建的、指向包内」的 node_modules 软链；真实目录一律不动 */
function cleanSymlinks() {
  const nm = path.join(HOME, 'node_modules');
  const st = lstat(nm);
  if (st && st.isSymbolicLink()) {
    let target = '';
    try { target = fs.readlinkSync(nm); } catch {}
    if (target && /\/usr\/lib\/dsh\/node_modules/.test(target)) {
      try { fs.unlinkSync(nm); log('[fixed] 移除旧预装 ESM 软链 node_modules'); fixed++; }
      catch (e) { log(`[warn] node_modules 软链移除失败 ${e.code}`); warned++; }
    }
  }
  const cp = path.join(PKG, 'cordis.patch.yml');
  const cs = lstat(cp);
  if (cs && cs.isSymbolicLink()) {
    try { fs.unlinkSync(cp); log('[fixed] 移除包目录旧 patch 软链'); fixed++; } catch {}
  }
}

function main() {
  if (!lstat(HOME)) { try { fs.mkdirSync(HOME, { recursive: true, mode: 0o700 }); } catch {} }
  // ★ +ios14：root 常驻进程建过树时，root 跑本脚本会全绿假通过。先无条件
  //   把 root 属主项转给 mobile，再走下面的常规自愈（对 root 与 mobile 都生效）。
  if (typeof process.getuid === 'function' && process.getuid() === 0) {
    fixRootOwnedTree(HOME, 0);
    if (chowned > 0) { log(`[fixed] root 属主项已转给 uid=${MOBILE_UID}（${chowned} 项）`); fixed++; }
  }
  if (!writable(HOME)) {
    // ★ +ios14：原来这里直接 return，导致 root 属主的 $DSH_HOME 让后面
    //   所有自愈一行没跑 -> 真机「新建会话失败 EACCES」。改为先自愈 HOME。
    if (!healHomeBySwap()) return;
  }
  // ★ 顺序关键：先修目录树属主，patch 文件才写得进去；
  //   profile 级 cordis.patch.yml 常在 root 属主的 profiles/ 子树里。
  healTreeBySwap(path.join(HOME, 'profiles'), 'profiles');
  healTreeBySwap(path.join(HOME, 'sessions'), 'sessions');
  // ★ 启动 fatal 的直接修复：清干净两类 patch 文件，并保证顶层是 YAML 数组。
  //   必须在 boot 之前跑；dsh wrapper 和 dsh-doctor 都会在启动前调用本脚本。
  cleanAllPatches();
  cleanSymlinks();
  // ★ +ios14：逐个兜底不可写的 session.v4.jsonl（含 root 444 历史文件）。
  healSessionFiles();
  // 顶层与 profile 级单文件兜底
  for (const r of ['cordis.patch.yml', 'patches.yml']) healFile(r);
  let pents = [];
  try { pents = fs.readdirSync(path.join(HOME, 'profiles'), { withFileTypes: true }); } catch {}
  for (const e of pents) {
    if (!e.isDirectory()) continue;
    for (const f of ['package.json', 'pnpm-lock.yaml', 'pnpm-workspace.yaml', 'cordis.patch.yml', 'patches.yml']) {
      healFile(path.join('profiles', e.name, f));
    }
  }
  if (fixed || warned) log(`[heal] fixed=${fixed} warn=${warned}`);
}

try { main(); } catch (e) { log(`[warn] heal 异常: ${e.code || e.message}`); }
process.exit(0);
