#!/usr/bin/env node
/**
 * apply_plugin_install_patch_rc3.cjs —— 单包（rc.3）专用
 *
 * ============ 为什么必须独立成一份，不能直接改共享 shim ============
 * shims/apply_plugin_install_patch.cjs 会被 shims/make_fix_ios15.py
 * 内嵌进 dist/fix-ios15.sh，而 fix-ios15.sh 又打进稳定底座
 * dev.airdevs.dsh_0.2.1-rc.5+ios15 的 deb。改共享 shim 一个字节，
 * 稳定底座的 SHA 就跟着变 —— 违反「稳定包逐字节不动」的硬约束。
 * 因此 rc.3 需要的「minify bundle 双锚点」只放这份单包专用副本里，
 * 供 one-package/build-one-package.sh 调用；共享 shim 保持原字节。
 *
 * 与共享 shim 的唯一差异：patchManualInstallClient() 增加 rc.3 的
 * window.__ModuleLoader__ minify bundle 锚点（client.js 从源码格式
 * 变成了 webpack bundle，+ios15 原补丁在该文件上命中 0 次）。
 * 其余 A/B 段（git 预检短路 / 插件市场主线程解析 + redirect follow）
 * 与共享 shim 完全一致。
 *
 * ---------------- 以下为 +ios15 原始说明（保留）----------------
 *
 * 修真机 0.2.1-rc.5 上用户反馈的两类故障，全部是「Web UI 手动安装」链路：
 *
 *   A) 「点击插件 → 安装插件」里【所有手动方式都失败】（AI 帮你装成功）:
 *      service 产物 dsh-plugin-manager/lib/index.js 的 installBundle() 会先跑
 *      checkGithubConnection()，对 git/github spec 裸调 execa("git", ["ls-remote",...])。
 *      iOS rootless 没有 git 二进制 -> ENOENT -> classifyInstallFailure 判为
 *      network -> installBundle 直接 throw，安装中止。这正是用户说的
 *      「GitHub 仓库安装不再是 127、有别的报错」。
 *      而 AI 帮你装（lib/types/tools.js -> manager.installBundle）会把仓库地址
 *      智能转成 npm 包名 / tarball（spec.kind != "git"），不触发 git 预检，故成功。
 *      修法：iOS 上短路这个【可选】预检。真正的下载由 pnpm 走 codeload
 *      tarball（HTTP），不需要本地 git。短路不改变安装结果，只去掉提前报错。
 *
 *   B) 「插件市场点进去直接加载失败，一堆报错」（没试安装）:
 *      dsh-plugin-market/lib/index.js 的 fetchIndex() 用 fetch(url,{redirect:"error"})，
 *      而目录站 / CDN / http->https 必然跳转 -> fetch-shim 直接抛
 *      "Request redirected"；parseIndexInWorker() 又用 new Worker(entry,{execArgv:[]})
 *      起子线程，在 A11 nowasm 零 JIT 主进程下，子 Worker 重新启用 V8 JIT，
 *      写可执行页即 SIGBUS（x86 复现不了，真机 A11 必崩）。
 *      修法：redirect 改 follow；把索引解析改到主线程（复用同一份 worker.cjs
 *      的 parseIndexBody，派生 worker-parse.cjs），彻底不 new Worker。
 *
 *   C) 前端手动安装对话框提交点注入「iOS 生态插件转化」调用：
 *      只在 dsh-client-ui-plugin-manager/lib/client.js（Web UI 手动安装专属）
 *      的 installBundle(spec) 提交前调 window.__dshIosTransformSpec(spec)。
 *      AI 帮你装走 tools.js、命令行走 types/operations.js，都不经过这个前端
 *      文件 —— 天然满足「AI 帮你装不要应用转化」的硬约束。
 *
 * 用法: node apply_plugin_install_patch.cjs <node_modules 根目录>
 * 退出码: 0=全部应用/已是最新；1=任何一处模式未精确命中（拒绝打出未验证的包）
 *
 * 幂等：所有目标带 dsh-ios +ios15 标记；重复执行跳过。
 */
'use strict';
const fs = require('node:fs');
const path = require('node:path');

const MARK = 'dsh-ios +ios15';
const NM = process.argv[2] || process.env.DSH_NODE_MODULES;
let failed = false;

function fail(msg) { process.stderr.write(`[FAIL] ${msg}\n`); failed = true; }
function ok(msg) { process.stdout.write(`  [ OK ] ${msg}\n`); }
function skip(msg) { process.stdout.write(`  [ == ] ${msg}\n`); }
function count(s, needle) {
  let n = 0, i = 0;
  while ((i = s.indexOf(needle, i)) !== -1) { n++; i += needle.length; }
  return n;
}
function read(p) { return fs.readFileSync(p, 'utf8'); }
function write(p, s) { fs.writeFileSync(p, s, 'utf8'); }
function target(rel) {
  const p = path.join(NM, rel);
  if (!fs.existsSync(p)) { fail(`目标不存在: ${rel}`); return null; }
  return p;
}
/** 精确替换：old 必须恰好出现 expect 次，否则视为依赖树变化、拒绝继续。 */
function replaceExact(file, rel, old, rep, expect) {
  let s = read(file);
  const n = count(s, old);
  if (n !== expect) { fail(`${rel}: 模式命中 ${n}/${expect} 次，拒绝继续（依赖树版本可能已变化）`); return false; }
  s = s.split(old).join(rep);
  write(file, s);
  return true;
}

/* ------------------------------------------------------------------ *
 * A) 短路 checkGithubConnection 的 git 预检（service 产物）
 * ------------------------------------------------------------------ */
function patchPluginManager() {
  const rel = '@deepseek-ai/dsh-plugin-manager/lib/index.js';
  const f = target(rel);
  if (!f) return;
  let s = read(f);
  if (s.includes(`${MARK}: git-probe-shortcircuit`)) { skip(`${rel}: git 预检短路已存在`); return; }

  const anchor = '\tif (spec.kind !== "git") return void 0;\n';
  if (count(s, anchor) !== 1) { fail(`${rel}: checkGithubConnection 入口锚点未唯一命中`); return; }
  const inject = anchor +
    `\t// ${MARK}: git-probe-shortcircuit\n` +
    `\t// iOS rootless 没有 git 二进制。这个预检只是「提前给个更好看的报错」，\n` +
    `\t// 真正的安装由 pnpm 走 codeload tarball (HTTP)，不需要本地 git。\n` +
    `\t// 若保留裸 execa("git")，所有 GitHub 仓库手动安装都会 ENOENT -> network\n` +
    `\t// -> installBundle 直接 throw（用户看到的「不再是 127 的新报错」）。\n` +
    `\t// 设 DSH_IOS_KEEP_GIT_PROBE=1 可在装了 git 的环境恢复官方行为。\n` +
    `\tif (!process.env.DSH_IOS_KEEP_GIT_PROBE) return void 0;\n`;
  write(f, s.replace(anchor, inject));
  ok(`${rel}: GitHub 仓库手动安装不再依赖 git 二进制（预检短路）`);
}

/* ------------------------------------------------------------------ *
 * B1) 从 worker.cjs 派生 worker-parse.cjs（主线程复用同一份解析代码）
 * ------------------------------------------------------------------ */
function deriveWorkerParse() {
  const rel = '@deepseek-ai/dsh-plugin-market/lib/worker.cjs';
  const f = target(rel);
  if (!f) return;
  const out = path.join(path.dirname(f), 'worker-parse.cjs');
  if (fs.existsSync(out) && read(out).includes(`${MARK}: worker-parse`)) {
    skip('worker-parse.cjs 已生成');
    return;
  }
  const src = read(f);
  const marker = 'const request = node_worker_threads.workerData;';
  const idx = src.lastIndexOf(marker);
  if (idx < 0) { fail('worker.cjs: 找不到 worker entry 锚点，无法派生主线程解析模块'); return; }
  if (!src.includes('function parseIndexBody(body, url)')) {
    fail('worker.cjs: 找不到 parseIndexBody 定义'); return;
  }
  const body = src.slice(0, idx);
  write(out,
    `/* ${MARK}: worker-parse — 从 worker.cjs 派生，主线程同步解析插件市场索引。\n` +
    `   与官方 worker.cjs 的 parseIndexBody 字节同源，仅把末尾的 Worker entry\n` +
    `   换成 module.exports。A11 nowasm 零 JIT 档下不再 new Worker（避免 SIGBUS）。*/\n` +
    body +
    `\nmodule.exports = { parseIndexBody };\n`);
  ok('worker-parse.cjs 已派生（与官方 parseIndexBody 同源）');
}

/* ------------------------------------------------------------------ *
 * B2) 插件市场 index.js：redirect follow + 主线程解析
 * ------------------------------------------------------------------ */
function patchPluginMarket() {
  const rel = '@deepseek-ai/dsh-plugin-market/lib/index.js';
  const f = target(rel);
  if (!f) return;
  let s = read(f);
  if (s.includes(`${MARK}: market-main-thread`)) { skip(`${rel}: 主线程解析 + redirect follow 已存在`); return; }

  /* (1) 顶部注入 createRequire，加载同源的 worker-parse.cjs。
        放在第一行 import 之前也可以，但用后缀注入更安全（不破坏 sourcemap 行号）。 */
  const firstLine = s.slice(0, s.indexOf('\n'));
  if (!firstLine.startsWith('import ') && !firstLine.startsWith('//')) {
    fail(`${rel}: 首行不是 import，注入位置不确定`); return;
  }
  const helper =
    `import { createRequire as __dshCreateRequire } from "node:module";\n` +
    `const __dshRequire = __dshCreateRequire(import.meta.url);\n` +
    `const { parseIndexBody: __dshParseIndexBody } = __dshRequire("./worker-parse.cjs");\n` +
    `// ${MARK}: market-main-thread — A11 nowasm 档禁止子 Worker(execArgv:[]) 重新启用 V8 JIT。\n`;

  /* (2) parseIndexInWorker 整个函数体替换为主线程同步解析。
        精确匹配从函数签名到与之配对的第一个 "}\n//#endregion"。 */
  const startNeedle = 'async function parseIndexInWorker(body, url, signal) {';
  const si = s.indexOf(startNeedle);
  if (si < 0) { fail(`${rel}: 找不到 parseIndexInWorker 定义`); return; }
  const endNeedle = '\n}\n//#endregion';
  const ei = s.indexOf(endNeedle, si);
  if (ei < 0) { fail(`${rel}: 找不到 parseIndexInWorker 结束边界`); return; }
  const endAt = ei + '\n}'.length;
  const replacement =
    `async function parseIndexInWorker(body, url, signal) {\n` +
    `\tsignal.throwIfAborted();\n` +
    `\t// ${MARK}: market-main-thread — 主线程复用官方 parseIndexBody，\n` +
    `\t// 返回结构与 Worker 版完全一致 ({ok:true,index} | {ok:false,...})。\n` +
    `\t// 索引通常几十 KB，同步解析不会造成可感知的卡顿；换来 A11 上不再 SIGBUS。\n` +
    `\tconst __dshBytes = body instanceof Uint8Array ? body : new Uint8Array(body);\n` +
    `\treturn __dshParseIndexBody(__dshBytes, url);\n` +
    `}`;
  s = s.slice(0, si) + replacement + s.slice(endAt);

  /* (3) redirect:"error" -> "follow"（只改 fetchIndex 那一处，带上下文锚定）。 */
  const redirOld = '\t\t\t\tredirect: "error",';
  const redirNew = `\t\t\t\tredirect: "follow", // ${MARK}: 目录站/CDN/http->https 会跳转`;
  if (count(s, redirOld) !== 1) {
    fail(`${rel}: fetchIndex 的 redirect:"error" 未唯一命中 (${count(s, redirOld)})`); return;
  }
  s = s.replace(redirOld, redirNew);

  /* (4) 把 helper 放到文件最前（在所有 import 之前是合法的 ESM）。 */
  s = helper + s;
  write(f, s);
  ok(`${rel}: 插件市场索引改主线程解析 + redirect follow（不再 SIGBUS / 不再跳转即报错）`);
}

/* ------------------------------------------------------------------ *
 * C) 前端手动安装对话框：提交前插入 iOS 生态插件转化调用
 * ------------------------------------------------------------------ */
function patchManualInstallClient() {
  const rel = '@deepseek-ai/dsh-client-ui-plugin-manager/lib/client.js';
  const f = target(rel);
  if (!f) return;
  let s = read(f);
  const hookMark = `${MARK}: manual-transform-hook`;
  if (s.includes(hookMark)) { skip(`${rel}: 手动安装转化钩子已存在`); return; }

  // rc.3 把 client.js 换成了 window.__ModuleLoader__ 的 minify bundle，
  // 与 0.2.1-rc.5 / 0.2.2-rc.1 的源码格式（带空格、多行）不同。两种都
  // 精确命中 1 次才改，任一不唯一就拒绝，绝不打出未经验证的包。
  const srcAnchor = 'const result = await this.ctx.remote.pluginManager.installBundle(spec, {';
  const bundleAnchor = 'const result=await this.ctx.remote.pluginManager.installBundle(spec,{';

  const nSrc = count(s, srcAnchor);
  const nBundle = count(s, bundleAnchor);
  if (nSrc === 1) {
    const rep =
      `\t\t\t\t// ${hookMark} —— 仅 Web UI 手动安装路径。\n` +
      `\t\t\t\t// AI 帮你装走 tools.js、命令行走 operations.js，都不经过这里。\n` +
      `\t\t\t\tconst __dshSpec = (typeof window !== "undefined" && typeof window.__dshIosTransformSpec === "function")` +
      ` ? window.__dshIosTransformSpec(spec) : spec;\n` +
      `\t\t\t\tconst result = await this.ctx.remote.pluginManager.installBundle(__dshSpec, {`;
    if (!replaceExact(f, rel, srcAnchor, rep, 1)) return;
  } else if (nBundle === 1) {
    // minify bundle：单行注入，块注释带 hookMark 保证幂等；插在语句之间，
    // 与 const result 同一函数作用域，不会重复声明。
    const rep =
      `/* ${hookMark} */const __dshSpec=(typeof window!=="undefined"&&typeof window.__dshIosTransformSpec==="function")` +
      `?window.__dshIosTransformSpec(spec):spec;` +
      `const result=await this.ctx.remote.pluginManager.installBundle(__dshSpec,{`;
    if (!replaceExact(f, rel, bundleAnchor, rep, 1)) return;
  } else {
    fail(`${rel}: 手动安装提交点锚点未唯一命中 (源码=${nSrc}, bundle=${nBundle})，依赖树结构可能已变化`);
    return;
  }
  ok(`${rel}: 手动安装提交前接入 iOS 生态插件转化（AI 帮你装不受影响）`);
}

function main() {
  if (!NM) {
    process.stderr.write('[FAIL] 用法: apply_plugin_install_patch.cjs <node_modules 根目录>\n');
    return 1;
  }
  if (!fs.existsSync(NM)) {
    process.stderr.write(`[FAIL] node_modules 不存在: ${NM}\n`);
    return 1;
  }
  process.stdout.write(`==> ${MARK} 插件安装 / 插件市场全链路修复 (${NM})\n`);
  patchPluginManager();
  deriveWorkerParse();
  patchPluginMarket();
  patchManualInstallClient();
  if (failed) {
    process.stderr.write(`[FAIL] ${MARK} 有未命中项，拒绝继续\n`);
    return 1;
  }
  process.stdout.write(`  [ OK ] ${MARK} 全部应用\n`);
  return 0;
}

process.exit(main());
