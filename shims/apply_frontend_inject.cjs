#!/usr/bin/env node
/**
 * apply_frontend_inject.cjs —— +ios15 前端注入统一入口（幂等）
 *
 * 用途：把 Safari 16.6 扩展垫片 + 手动安装转化逻辑注入 dsh-web-frontend/dist。
 * 「构建期」「设备端热修」「dsh-doctor 自愈」三个入口共用同一份逻辑，避免
 * 出现「补丁打了但前端没注入」的假绿。
 *
 * 用法:
 *   node apply_frontend_inject.cjs <dist 目录> <垫片源文件> <转化逻辑源文件>
 *
 * 行为:
 *   - 复制两个源文件到 dist/assets/<basename>
 *   - 在 dist/index.html 的 <head> 内、所有 <script type="module"> 之前，
 *     幂等地补齐两个同步 <script src>（已有则不重复）
 *   - 校验结果：两个引用存在、两个 assets 文件存在
 * 退出码: 0=成功/已是最新；1=失败
 */
'use strict';
const fs = require('node:fs');
const path = require('node:path');

const dist = process.argv[2];
const polySrc = process.argv[3];
const transSrc = process.argv[4];

function fail(m) { process.stderr.write(`[FAIL] ${m}\n`); process.exit(1); }
if (!dist || !polySrc || !transSrc) fail('用法: apply_frontend_inject.cjs <dist> <垫片源> <转化逻辑源>');

const index = path.join(dist, 'index.html');
const assets = path.join(dist, 'assets');
if (!fs.existsSync(index)) fail(`找不到 ${index}`);
if (!fs.existsSync(polySrc)) fail(`找不到垫片源 ${polySrc}`);
if (!fs.existsSync(transSrc)) fail(`找不到转化逻辑源 ${transSrc}`);
fs.mkdirSync(assets, { recursive: true });

const jobs = [
  { src: polySrc, name: path.basename(polySrc) },
  { src: transSrc, name: path.basename(transSrc) },
];

let html = fs.readFileSync(index, 'utf8');
const tags = [];
for (const j of jobs) {
  const dst = path.join(assets, j.name);
  fs.copyFileSync(j.src, dst);
  process.stdout.write(`  [ OK ] assets/${j.name} (${fs.statSync(dst).size} 字节)\n`);
  if (!html.includes(j.name)) tags.push(`    <script src="./assets/${j.name}"></script>`);
}

if (tags.length) {
  const m = html.match(/(<head(?:\s[^>]*)?>)/);
  if (!m) fail('index.html 找不到 <head> 标签');
  html = html.slice(0, m.index + m[1].length) + '\n' + tags.join('\n') +
         html.slice(m.index + m[1].length);
  fs.writeFileSync(index, html, 'utf8');
  process.stdout.write(`  [ OK ] index.html 注入 ${tags.length} 个引用（<head> 内, module 之前）\n`);
} else {
  process.stdout.write('  [ == ] index.html 两个引用已存在，跳过\n');
}

// 结果校验
html = fs.readFileSync(index, 'utf8');
for (const j of jobs) {
  if (!html.includes(j.name)) fail(`index.html 缺 ${j.name} 引用`);
  if (!fs.existsSync(path.join(assets, j.name))) fail(`缺 assets/${j.name}`);
}
// 引用必须在 module 之前
const firstModule = html.indexOf('type="module"');
for (const j of jobs) {
  if (firstModule !== -1 && html.indexOf(j.name) > firstModule) {
    fail(`${j.name} 引用落在 <script type="module"> 之后`);
  }
}
process.stdout.write('  [ OK ] +ios15 前端注入完成并校验通过\n');
