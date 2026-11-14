#!/usr/bin/env node
/*
 * apply_pnpm_abs_patch.cjs —— +ios14：把 dsh 的 pnpm 调用改成包内绝对路径直连
 *                              且强制走「零 JIT」档（修真机 SIGBUS）
 *
 * 三段历史，缺一不可：
 *   +ios13 真机: `dsh plugin ...` 报
 *     "dsh: pnpm was not found; install pnpm and make it available on PATH."（127）
 *     package.json 的 exports 把 CLI 与 service 分到两份产物：
 *       "./operations" -> lib/types/operations.js   （CLI，单引号）
 *       "."            -> lib/index.js              （web service，双引号）
 *     两者都 execa('pnpm', ..., { env: environment, extendEnv: false })，
 *     真机 dsh 自造的 env 里 PATH 不含 /var/jb/usr/bin、shebang 也不可靠。
 *     -> 改成「包内 node 绝对路径 + pnpm.cjs 绝对路径」直连。
 *
 *   +ios14 真机回归（用户截图）: 卸载插件变成
 *     Command was killed with SIGBUS (Bus error due to misaligned, non-existing
 *       address or paging error):
 *       /var/jb/usr/lib/dsh/bin/node .../libexec/pnpm/bin/pnpm.cjs remove '@xmanrui/dsh-im'
 *     bin/pnpm.cjs 显式调用 module.enableCompileCache() / v8-compile-cache，
 *     dist/pnpm.cjs 是 7.2MB 大 bundle；A11 上 V8 后台线程编译 JIT/WASM 时
 *     pthread_jit_write_protect_np 按线程生效 -> 写可执行页 SIGBUS。这正是
 *     tier.sh 从 +ios3 起解决的老问题，而 +ios13 的注入把档位参数丢了，
 *     等于让 pnpm 裸奔。dsh 主进程有 tier_select 保护所以 web UI 正常，
 *     只有 plugin 子进程崩。
 *     -> 注入的 args 前置 nowasm 档参数：
 *        --jitless --require <abs>/fetch-shim.cjs   （+ios24 / Node 24 版）
 *     与 +ios24 tier.sh 的 nowasm 档逐字一致，子进程完全不生成可执行代码，
 *     从原理上杜绝 SIGBUS。pnpm 是短命子进程，零 JIT 的性能损失可接受。
 *
 *   +ios24 专用副本：Node 24 / V8 13.x 已删除 --expose-wasm，
 *   共享 shims/apply_pnpm_abs_patch.cjs 里的 --no-expose-wasm 会让 pnpm
 *   子进程 `bad option` 退出 9。共享 shim 会被 make_fix_ios15.py 内嵌进
 *   fix-ios15.sh 并打进稳定底座 deb，改它会改变已发布 +ios15 SHA，
 *   因此只在单包构建里用这份副本。MARK 仍是 dsh-ios +ios14，设备端
 *   doctor 用共享 shim 自愈时会命中幂等跳过，不会把废参数重新写回来。
 *
 *   +ios14 升级路径：已打过 +ios13 补丁的设备，热修不能简单跳过（否则
 *   旧 helper 仍在、依旧 SIGBUS）。本脚本识别旧标记并就地替换 helper 块，
 *   再写入新标记；MARK 不变则幂等跳过。
 *
 * helper 注入到两份文件头部（路径上溯层数不同），各 5 处 command + 5 处 args
 * 全部精确命中并校验。构建期与设备端热修共用本脚本。
 * DSH_NODE / DSH_PNPM_CJS 可覆盖推导出的绝对路径（构建机验证用 Linux node）。
 *
 * 用法: node apply_pnpm_abs_patch.cjs <dsh-plugin-manager/lib 目录>
 * 退出码: 0=已应用或已是最新；1=模式未精确命中（拒绝打出未经验证的包）
 */
'use strict';
const fs = require('node:fs');
const path = require('node:path');

const MARK = 'dsh-ios +ios14';
const MARK_OLD = 'dsh-ios +ios13';

/* 两份构建产物的差异：相对包名根的上溯层数、command 字面量引号风格。 */
const TARGETS = [
  { rel: 'index.js',           up: '../../../..',    cmd: 'options.command ?? "pnpm"',  args: 'options.args ?? []' },
  { rel: 'types/operations.js', up: '../../../../..', cmd: "options.command ?? 'pnpm'",  args: 'options.args ?? []' },
];
const EXPECT = 5;

const NEW_CMD = '__dshPnpmCmd(options)';
const NEW_ARGS = '__dshPnpmArgs(options)';

/* 旧 helper 的边界：从第一个 import 到 __dshPnpmArgs 函数定义行结束。
   helper 内所有函数都是单行，非贪婪匹配只会吃掉文件头部那一块。 */
const OLD_HELPER_RE =
  /import \{ fileURLToPath as __dshFileURLToPath \} from "node:url";[\s\S]*?function __dshPnpmArgs\(o\) \{[^\n]*\}\n/;

function helper(up) {
  return `import { fileURLToPath as __dshFileURLToPath } from "node:url";
import { dirname as __dshDirname, join as __dshJoin } from "node:path";
// ${MARK}: resolve pnpm to the bundled pure-JS launcher via absolute paths,
// and force the zero-JIT tier so A11/V8 never compiles on a background thread.
// execa runs pnpm with extendEnv:false and a dsh-built env, so PATH/shebang
// lookup is unreliable on-device (127). Bare node + the 7.2MB pnpm bundle
// also dies with SIGBUS on A11 because bin/pnpm.cjs enables V8 compile cache.
// Absolute command + nowasm argv + cjs arg bypasses all three.
const __dshRoot = __dshJoin(__dshDirname(__dshFileURLToPath(import.meta.url)), "${up}");
const __dshPnpmNode = process.env.DSH_NODE || __dshJoin(__dshRoot, "bin", "node");
const __dshPnpmCjs = process.env.DSH_PNPM_CJS || __dshJoin(__dshRoot, "libexec", "pnpm", "bin", "pnpm.cjs");
const __dshFetchShim = __dshJoin(__dshRoot, "fetch-shim.cjs");
// +ios24: Node 24 removed --expose-wasm; --no-expose-wasm is bad option (rc=9).
// Keep byte-for-byte identical to the patched tier.sh nowasm tier.
const __dshPnpmFlags = ["--jitless", "--require", __dshFetchShim];
function __dshPnpmCmd(o) { const c = o && o.command; return (!c || c === "pnpm") ? __dshPnpmNode : c; }
function __dshPnpmArgs(o) { const c = o && o.command; if (c && c !== "pnpm") return (o && o.args) || []; return [...__dshPnpmFlags, __dshPnpmCjs, ...((o && o.args) || [])]; }
`;
}

function count(s, needle) {
  let n = 0, i = 0;
  while ((i = s.indexOf(needle, i)) !== -1) { n++; i += needle.length; }
  return n;
}

function patchOne(dir, t) {
  const file = path.join(dir, t.rel);
  if (!fs.existsSync(file)) { process.stderr.write(`[FAIL] 目标不存在: ${file}\n`); return false; }
  let text = fs.readFileSync(file, 'utf8');

  /* 已是 +ios14：幂等跳过。 */
  if (text.includes(MARK)) {
    process.stdout.write(`  [ OK ] ${t.rel}: +ios14 补丁已存在（幂等跳过）\n`);
    return true;
  }

  /* +ios13 旧补丁：就地升级 helper，不能跳过（否则真机继续 SIGBUS）。 */
  if (text.includes(MARK_OLD)) {
    if (!OLD_HELPER_RE.test(text)) {
      process.stderr.write(`[FAIL] ${t.rel}: 检测到 +ios13 旧补丁，但 helper 边界无法识别，拒绝继续。\n`);
      return false;
    }
    if (count(text, NEW_CMD) !== EXPECT || count(text, NEW_ARGS) !== EXPECT) {
      process.stderr.write(`[FAIL] ${t.rel}: +ios13 调用点计数异常，拒绝继续。\n`);
      return false;
    }
    text = text.replace(OLD_HELPER_RE, '');
    text = helper(t.up) + text;
    fs.writeFileSync(file, text, 'utf8');
    process.stdout.write(`  [ OK ] ${t.rel}: +ios13 -> +ios14 升级完成（补上零 JIT 档参数）\n`);
    return true;
  }

  /* 首次注入。 */
  const nc = count(text, t.cmd), na = count(text, t.args);
  if (nc !== EXPECT || na !== EXPECT) {
    process.stderr.write(
      `[FAIL] ${t.rel}: 模式未精确命中：command = ${nc}/${EXPECT}，args = ${na}/${EXPECT}。\n` +
      `        依赖树版本可能已变化，拒绝继续，以免打出未经验证的包。\n`);
    return false;
  }
  text = helper(t.up) + text;
  text = text.split(t.cmd).join(NEW_CMD);
  text = text.split(t.args).join(NEW_ARGS);
  fs.writeFileSync(file, text, 'utf8');
  process.stdout.write(`  [ OK ] ${t.rel}: ${EXPECT} 处 command + ${EXPECT} 处 args 已改为绝对路径直连 + 零 JIT\n`);
  return true;
}

function main() {
  const dir = process.argv[2] || process.env.DSH_PM_LIB;
  if (!dir) { process.stderr.write('[FAIL] 用法: apply_pnpm_abs_patch.cjs <dsh-plugin-manager/lib>\n'); return 1; }
  let ok = true;
  for (const t of TARGETS) if (!patchOne(dir, t)) ok = false;
  if (!ok) return 1;
  process.stdout.write('  [ OK ] +ios14 pnpm 绝对路径直连 + 零 JIT 补丁全部应用（CLI + service）\n');
  return 0;
}

process.exit(main());
