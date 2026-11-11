#!/usr/bin/env node
/*
 * ensure-config.cjs —— 把内置手机工具链自动注册成 DSH 的 MCP 客户端
 *
 * 用户要求「启动 DSH 让 DSH 操作手机，能够直接调用相关工具链」。
 * 原先要用户手动装插件 + 手填 cordis.patch.yml；这里在 APP/保活包安装后，
 * 由 bridge daemon（以 mobile 身份）在启动时幂等写入：
 *
 *   $DSH_HOME/cordis.patch.yml
 *   $DSH_HOME/profiles/<profile>/cordis.patch.yml
 *
 * 写入的块：
 *   - insert:
 *       - id: dsh-ios-phone-bridge-mcp
 *         name: '@deepseek-ai/dsh-mcp-client'
 *         config: { url: http://127.0.0.1:8091/mcp, ... }
 *
 * 为什么必须保持「顶层数组」：真机上曾因 cordis.patch.yml 顶层非数组
 * 直接 fatal。本脚本用与 shims/dsh-home-heal.cjs 同样的判定逻辑；自愈脚本
 * 只删 id=im-qqbot / xmanrui-dsh-im 两个旧块，用户/本脚本写的块一律保留。
 *
 * 用法: node ensure-config.cjs <DSH_HOME> [on|off|status]
 *   on      幂等注册（默认）
 *   off     移除本工具链的块（保留用户其它块）
 *   status  只打印状态，不写文件
 * 环境变量: DSH_IOS_PHONE_CONTROL=0 等价于 off
 *
 * 纯 Node 内置模块，零 npm 依赖，可在 --jitless 档运行。
 */
'use strict';

const fs = require('node:fs');
const path = require('node:path');

const HOME = process.argv[2] || process.env.DSH_HOME || '/var/jb/var/mobile/.dsh';
let MODE = (process.argv[3] || 'on').toLowerCase();
if (process.env.DSH_IOS_PHONE_CONTROL === '0') MODE = 'off';
if (!['on', 'off', 'status'].includes(MODE)) {
    process.stderr.write('用法: ensure-config.cjs <DSH_HOME> [on|off|status]\n');
    process.exit(2);
}

const ID = 'dsh-ios-phone-bridge-mcp';
const BLOCK = [
    '- insert:',
    '    - id: ' + ID,
    "      name: '@deepseek-ai/dsh-mcp-client'",
    '      config:',
    '        serverName: ios',
    '        transport: streamable-http',
    '        url: http://127.0.0.1:8091/mcp',
    '        headers: {}',
    '        toolCallTimeoutMs: 120000',
    '        failOnStartupError: false',
    '        maxInstructionBytes: 32768',
    '        reconnect:',
    '          enabled: true',
    '          initialDelayMs: 500',
    '          maxDelayMs: 30000',
    '          maxAttempts: 30'
].join('\n');

/* 与 dsh-home-heal.cjs 的 patchLooksValid 同构：顶层必须是 YAML 数组。 */
function looksValid(text) {
    if (!text) return false;
    let sawItem = false;
    for (const raw of text.split('\n')) {
        const line = raw.replace(/\s+$/, '');
        if (!line.trim() || /^\s*#/.test(line)) continue;
        if (/^\s*(?:---|\.\.\.)\s*(?:#.*)?$/.test(line)) continue;
        if (/^\s/.test(line)) continue;              // 缩进行属于当前数组项
        if (/^\[\s*\]\s*(?:#.*)?$/.test(line.trim())) return true;
        if (/^-\s/.test(line) || /^-$/.test(line)) { sawItem = true; continue; }
        return false;
    }
    return sawItem;
}

function hasOurBlock(text) {
    return new RegExp('(^|\\n)\\s*-?\\s*id:\\s*[\'"]?' + ID + '[\'"]?\\s*(?:#.*)?$', 'm').test(text);
}

function splitTopBlocks(lines) {
    const head = [];
    const blocks = [];
    let i = 0;
    while (i < lines.length && !/^-\s/.test(lines[i]) && !/^-$/.test(lines[i])) {
        head.push(lines[i]); i++;
    }
    while (i < lines.length) {
        const block = [lines[i]];
        let j = i + 1;
        while (j < lines.length && !/^-\s/.test(lines[j]) && !/^-$/.test(lines[j])) {
            block.push(lines[j]); j++;
        }
        blocks.push(block);
        i = j;
    }
    return { head, blocks };
}

/* 原子写：先写同目录临时文件再 rename，避免半写；mode 0600 与 heal 一致。 */
function atomicWrite(p, content) {
    try { fs.mkdirSync(path.dirname(p), { recursive: true, mode: 0o700 }); }
    catch (e) { return 'mkdir: ' + e.code; }
    const tmp = p + '.dsh-phone-bridge.' + process.pid;
    try {
        fs.writeFileSync(tmp, content, { mode: 0o600 });
        fs.renameSync(tmp, p);
        try { fs.chmodSync(p, 0o600); } catch (_) {}
        return true;
    } catch (e) {
        try { fs.unlinkSync(tmp); } catch (_) {}
        return String(e.code || e.message || e);
    }
}

function targets() {
    const out = [path.join(HOME, 'cordis.patch.yml')];
    const pdir = path.join(HOME, 'profiles');
    let ents = [];
    try { ents = fs.readdirSync(pdir, { withFileTypes: true }); } catch (_) {}
    for (const e of ents) {
        if (e.isDirectory() || e.isSymbolicLink()) out.push(path.join(pdir, e.name, 'cordis.patch.yml'));
    }
    return out;
}

function processFile(p) {
    let text = '';
    let existed = false;
    try { text = fs.readFileSync(p, 'utf8'); existed = true; }
    catch (_) { text = '# dsh-ios phone-bridge patch layer\n[]\n'; }

    const valid = looksValid(text);
    if (!valid) text = '# dsh-ios phone-bridge: 顶层非数组，已重置\n[]\n';

    const has = hasOurBlock(text);
    if (MODE === 'status') return { file: p, existed, valid: !!valid, registered: has, action: 'none' };

    let lines = text.split('\n');
    // 单独的 [] 与后面的 "- insert:" 不能共存（YAML 会出现两个顶层值）。
    if (!lines.some((l) => /^-\s/.test(l) || /^-$/.test(l))) {
        lines = lines.filter((l) => !/^\[\s*\]\s*(?:#.*)?$/.test(l.trim()));
    }
    const { head, blocks } = splitTopBlocks(lines);
    const kept = blocks.filter((b) => !hasOurBlock(b.join('\n')));

    let next;
    if (MODE === 'on') {
        if (has) return { file: p, existed, valid: !!valid, registered: true, action: 'unchanged' };
        kept.push(BLOCK.split('\n'));
        next = head.concat(...kept).join('\n').replace(/\n{3,}/g, '\n\n').replace(/\s+$/, '') + '\n';
        if (!looksValid(next)) return { file: p, action: 'error', error: 'would produce invalid top-level' };
    } else {
        if (!has) return { file: p, existed, valid: !!valid, registered: false, action: 'unchanged' };
        const rest = head.concat(...kept).join('\n').replace(/\n{3,}/g, '\n\n').replace(/\s+$/, '').trim();
        next = (rest || '[]') + '\n';
        if (!looksValid(next)) next = '[]\n';
    }

    const w = atomicWrite(p, next);
    if (w !== true) return { file: p, action: 'error', error: String(w) };
    return { file: p, existed, valid: !!valid, registered: MODE === 'on', action: MODE === 'on' ? 'registered' : 'removed' };
}

const results = targets().map(processFile);
const errors = results.filter((r) => r.action === 'error');
process.stdout.write(JSON.stringify({ mode: MODE, home: HOME, results }, null, 2) + '\n');
process.exit(errors.length ? 1 : 0);
