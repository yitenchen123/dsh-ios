#!/usr/bin/env node
/**
 * apply_fixed_token_patch.cjs —— 让 DSH web 的 launchToken 可由 DSH_WEB_TOKEN 固定。
 *
 * 背景（iOS 全屏入口的根因）：
 *   dsh 0.2.2-rc.3 的 dsh-client-connection/lib/index.js 里，
 *   processLaunchToken() 每次进程启动都 randomBytes() 重新生成 launchToken；
 *   首页 authorizeIndex() 只有在 `/?token=<launchToken>` 匹配时才 303 换取
 *   HttpOnly cookie（30 天），否则一律 401。而 iOS 全屏 Web Clip 的 URL
 *   写死在 Info.plist 里，是静态的，无法跟随每次启动变化的 token —— 于是
 *   点开 Web Clip 必然 401，前端 JS 不加载，插件 / 工作区 / 对话全空。
 *
 * 修法：让 launchToken 取环境变量 DSH_WEB_TOKEN（由 launchd plist 注入），
 *   并以仓库内 one-package/dsh-web-token 里的同一个常量作缺省兜底 —— 保证
 *   「launchd 未注入 env」「用户在终端手动敲 dsh web」两种情况下，Web Clip
 *   的静态 URL 依旧恒定匹配。首次访问即 303 换 cookie，之后所有 API / SSE /
 *   WebSocket 走 cookie，与官方桌面 App「点开即用」一致。
 *   local loopback-only，无跨设备暴露；该值不是机密（rc.1 时代本机 Web UI
 *   根本没有 token 机制，安全模型未变）。
 *
 * 一致性由 one-package/verify-one-package.sh 强校验：补丁里的缺省值、plist
 *   的 DSH_WEB_TOKEN、Web Clip URL 的 ?token=、dsh-daemon 的兜底四处必须
 *   全部等于 one-package/dsh-web-token。
 *
 * 幂等：已打过（含标记）就跳过。遍历传入目录下所有
 *   名为 dsh-client-connection/lib/index.js 的文件
 *   （兼容 npm flat 与 pnpm 隔离布局）。
 *
 * 用法: node apply_fixed_token_patch.cjs <node_modules 目录> [更多目录...]
 * 退出码: 0=成功(或已最新)  1=锚点未命中/失败
 */
'use strict';
const fs = require('node:fs');
const path = require('node:path');

const MARK = 'process.env.DSH_WEB_TOKEN';
const roots = process.argv.slice(2);
if (!roots.length) {
  process.stderr.write('用法: apply_fixed_token_patch.cjs <node_modules 目录...>\n');
  process.exit(1);
}

// 匹配 `function processLaunchToken(owner) {`（含压缩后可能的空白差异）
const ANCHOR = /(function\s+processLaunchToken\s*\(\s*[A-Za-z_$][\w$]*\s*\)\s*\{)/;

function walk(dir, out, depth) {
  if (depth > 12) return;
  let ents;
  try { ents = fs.readdirSync(dir, { withFileTypes: true }); } catch { return; }
  for (const e of ents) {
    const p = path.join(dir, e.name);
    if (e.isDirectory()) {
      walk(p, out, depth + 1);
    } else if (e.isFile() && e.name === 'index.js') {
      // .../dsh-client-connection/lib/index.js
      if (p.replace(/\\/g, '/').endsWith('dsh-client-connection/lib/index.js')) out.push(p);
    }
  }
}

let targets = [];
for (const r of roots) {
  const found = [];
  walk(r, found, 0);
  targets = targets.concat(found);
}
// 去重（pnpm 硬链接可能重复出现）
targets = [...new Set(targets)];

if (!targets.length) {
  process.stderr.write('[FAIL] 未找到任何 dsh-client-connection/lib/index.js\n');
  process.exit(1);
}

let patched = 0, skipped = 0, failed = 0;
for (const file of targets) {
  let src;
  try { src = fs.readFileSync(file, 'utf8'); } catch (e) {
    process.stderr.write(`[FAIL] 读不到 ${file}: ${e.message}\n`); failed++; continue;
  }
  if (src.includes(MARK)) { skipped++; continue; }
  const m = src.match(ANCHOR);
  if (!m) {
    process.stderr.write(`[FAIL] ${file} 锚点未命中（上游结构变化）\n`); failed++; continue;
  }
  const inject = m[1] +
    '\n\t// __DSH_IOS_FIXED_TOKEN__: 固定 loopback token，供 iOS 全屏静态 URL 使用。' +
    '\n\t// DSH_WEB_TOKEN 由 launchd plist 注入；缺省值保证终端手动启动 dsh web 时' +
    '\n\t// 与 Web Clip 的静态 URL 仍然一致（local loopback-only，无跨设备暴露）。' +
    '\n\treturn process.env.DSH_WEB_TOKEN || "dshios-fixed-token-8f3a2c";';
  const out = src.slice(0, m.index) + inject + src.slice(m.index + m[1].length);
  try { fs.writeFileSync(file, out, 'utf8'); } catch (e) {
    process.stderr.write(`[FAIL] 写入 ${file}: ${e.message}\n`); failed++; continue;
  }
  process.stdout.write(`  [ OK ] ${path.relative(process.cwd(), file)} 已固定 token\n`);
  patched++;
}

process.stdout.write(`  fixed-token: patched=${patched} already=${skipped} failed=${failed}\n`);
process.exit(failed ? 1 : 0);
