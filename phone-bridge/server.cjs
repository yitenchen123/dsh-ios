#!/usr/bin/env node
/*
 * dsh-ios phone-bridge —— 设备本机 MCP 工具链（Streamable HTTP）
 *
 * 目的：用户要求「启动 DSH 让 DSH 操作手机，能够直接调用相关工具链」。
 * 早期方案要求用户额外安装第三方 witchan/ios-mcp 并手动装配置插件；现在原生能力随包提供，
 * 不满足「启动即可用」。本服务把能力分成两层，用一个固定回环端点统一暴露：
 *
 *   A 层（本文件原生实现，纯 Node，无需任何第三方原生组件）：
 *     设备信息 / 目录 / 读写文件 / 执行命令 / App 列表 / 启动 App /
 *     打开 URL / 进程 / 系统日志 / DSH 自身状态 / bridge 状态
 *   B 层（真·看屏幕、点屏幕、UI 树、OCR、剪贴板、亮度音量…）：
 *     转发到随包安装的原生 SpringBoard 插件 dsh-ios-control
 *     （默认 http://127.0.0.1:8090/mcp）。插件由 dev.airdevs.dsh-app 一起装，
 *     安装后 respring 一次即加载；在线时工具合并进 tools/list，tools/call 原样转发。
 *     离线时这些工具不出现，并给出明确的 respring / 状态检查指引。
 *
 * 为什么固定 8091：8090 是第三方 ios-mcp 的默认端口，不能抢占。
 * DSH 侧 cordis.patch.yml 由 ensure-config.cjs 自动注册到 127.0.0.1:8091/mcp。
 *
 * 协议：MCP 2025-11-25，POST /mcp 走 JSON-RPC；响应 application/json，
 * 带 MCP-Protocol-Version 与 Mcp-Session-Id。notification（无 id）返回 202。
 * 只用 Node 内置模块，零 npm 依赖，可在 --jitless / fetch-shim 零 JIT 档运行。
 *
 * 安全：无任何认证，仅绑定 127.0.0.1。run_command 可执行任意 shell，
 * 必须在可信设备上使用；不要改成 0.0.0.0。
 */
'use strict';

const http = require('node:http');
const fs = require('node:fs');
const path = require('node:path');
const os = require('node:os');
const cp = require('node:child_process');

const HOST = process.env.DSH_BRIDGE_HOST || '127.0.0.1';
const PORT = Number(process.env.DSH_BRIDGE_PORT || 8091);
const UPSTREAM = process.env.DSH_IOS_MCP_URL || 'http://127.0.0.1:8090/mcp';
const DSH_HOME = process.env.DSH_HOME || '/var/jb/var/mobile/.dsh';
const JB = '/var/jb';
const PROTOCOL = '2025-11-25';
const SESSION = 'dsh-ios-phone-bridge';
const MAX_OUTPUT = 64 * 1024;
const MAX_FILE = 2 * 1024 * 1024;
const CMD_TIMEOUT = Number(process.env.DSH_BRIDGE_CMD_TIMEOUT || 60000);

function tool(name, description, properties, required) {
    return {
        name,
        description,
        inputSchema: { type: 'object', properties: properties || {}, required: required || [] }
    };
}
const S = (d) => ({ type: 'string', description: d });
const N = (d) => ({ type: 'number', description: d });
const B = (d) => ({ type: 'boolean', description: d });

/* ------------------------------------------------------------------ A 层工具 */
const LOCAL_TOOLS = [
    tool('get_device_info', 'Read device/JB/DSH runtime info (model, OS, arch, memory, uptime, jailbreak root).', {}),
    tool('list_dir', 'List a directory with type/size/mtime.', { path: S('absolute directory path') }, ['path']),
    tool('read_file', 'Read a text file (max 2 MiB).', { path: S('absolute file path'), max_bytes: N('optional cap') }, ['path']),
    tool('write_file', 'Write a text file (max 2 MiB), creating parent directories.', { path: S('absolute file path'), content: S('text content'), append: B('append instead of overwrite') }, ['path', 'content']),
    tool('run_command', 'Run a shell command on the device with a timeout. Use for install/build/test loops.', { command: S('shell command'), cwd: S('optional working directory'), timeout_ms: N('optional timeout in ms') }, ['command']),
    tool('list_apps', 'List installed .app bundles under /var/jb/Applications and /Applications with bundle id / name.', { root: S('optional extra directory to scan') }),
    tool('launch_app', 'Launch an app by bundle id or open a URL scheme (uiopen / open / launchctl).', { bundle_id: S('CFBundleIdentifier'), url: S('URL or scheme, used when bundle_id is empty') }),
    tool('open_url', 'Open a URL / URL scheme on the device.', { url: S('e.g. bilibili:// or https://...') }, ['url']),
    tool('list_processes', 'List running processes (ps), optionally filtered.', { filter: S('optional grep filter') }),
    tool('get_syslog', 'Best-effort read of system log; returns a clear hint when no log tool is available.', { lines: N('max lines, default 200') }),
    tool('dsh_status', 'Report whether the DSH web service / daemon / this bridge are reachable.', { port: N('DSH web port, default 3080') }),
    tool('phone_bridge_status', 'Report this bridge: local tool count, upstream ios-mcp reachability and merged tool count.', {})
];

/* B 层工具名（上游在线时动态合并，离线时作为「需要 ios-mcp」的提示清单） */
const UPSTREAM_HINT_TOOLS = [
    'screenshot', 'get_screen_info', 'get_ui_elements', 'get_element_at_point',
    'tap_screen', 'swipe_screen', 'long_press', 'double_tap', 'drag_and_drop',
    'input_text', 'type_text', 'press_key', 'press_home', 'press_power',
    'press_volume_up', 'press_volume_down', 'toggle_mute', 'wake_and_home',
    'tap_element', 'wait_for_element', 'wait_for_disappear', 'ocr_screen',
    'describe_screen', 'get_frontmost_app', 'kill_app', 'install_app',
    'uninstall_app', 'get_app_info', 'get_crash_logs', 'read_crash_log',
    'get_brightness', 'set_brightness', 'get_volume', 'set_volume',
    'get_clipboard', 'set_clipboard', 'list_running_apps'
];

function textResult(value, isError) {
    const s = typeof value === 'string' ? value : JSON.stringify(value, null, 2);
    return { content: [{ type: 'text', text: s.slice(0, MAX_OUTPUT) }], isError: !!isError };
}
function err(msg) { return textResult({ error: msg }, true); }

function sh(cmd, opts) {
    return new Promise((resolve) => {
        const o = opts || {};
        cp.execFile('/bin/sh', ['-c', cmd], {
            timeout: o.timeout || CMD_TIMEOUT,
            maxBuffer: MAX_OUTPUT * 2,
            cwd: o.cwd || undefined,
            env: Object.assign({}, process.env, {
                PATH: [JB + '/usr/bin', JB + '/bin', '/usr/bin', '/bin', '/usr/sbin', '/sbin', process.env.PATH || ''].join(':')
            })
        }, (error, stdout, stderr) => {
            resolve({
                code: error ? (error.code === null ? 124 : (error.code || 1)) : 0,
                stdout: String(stdout || '').slice(-MAX_OUTPUT),
                stderr: String(stderr || '').slice(-MAX_OUTPUT),
                killed: !!(error && error.killed)
            });
        });
    });
}

function parsePlistStrings(p) {
    try {
        const s = fs.readFileSync(p, 'utf8');
        const pick = (key) => {
            const re = new RegExp('<key>' + key + '</key>\\s*<string>([\\s\\S]*?)</string>', 'i');
            const m = s.match(re);
            return m ? m[1].trim() : '';
        };
        return {
            bundle_id: pick('CFBundleIdentifier'),
            name: pick('CFBundleName') || pick('CFBundleDisplayName'),
            executable: pick('CFBundleExecutable'),
            version: pick('CFBundleShortVersionString')
        };
    } catch (_) {
        return { bundle_id: '', name: '', executable: '', version: '' };
    }
}

async function listApps(extra) {
    const roots = [JB + '/Applications', '/Applications'];
    if (extra) roots.push(extra);
    const out = [];
    for (const root of roots) {
        let entries = [];
        try { entries = fs.readdirSync(root, { withFileTypes: true }); } catch (_) { continue; }
        for (const e of entries) {
            if (!e.name.endsWith('.app')) continue;
            const dir = path.join(root, e.name);
            const plist = path.join(dir, 'Info.plist');
            if (!fs.existsSync(plist)) continue;
            out.push(Object.assign({ app: e.name, path: dir, root }, parsePlistStrings(plist)));
        }
    }
    return out;
}

async function callLocal(name, args) {
    const a = args || {};
    switch (name) {
        case 'get_device_info': {
            let uname = '';
            const r = await sh('uname -a');
            uname = r.stdout.trim();
            let jb = { present: fs.existsSync(JB), symlink: false };
            try { jb.symlink = fs.lstatSync(JB).isSymbolicLink(); } catch (_) {}
            return textResult({
                hostname: os.hostname(), platform: os.platform(), arch: os.arch(),
                release: os.release(), type: os.type(), uname,
                cpus: os.cpus().length, cpu_model: (os.cpus()[0] || {}).model || '',
                total_memory_bytes: os.totalmem(), free_memory_bytes: os.freemem(),
                uptime_seconds: os.uptime(), node: process.version,
                jailbreak_root: jb, dsh_home: DSH_HOME,
                bridge: { host: HOST, port: PORT, upstream: UPSTREAM }
            });
        }
        case 'list_dir': {
            const p = String(a.path || '');
            if (!p.startsWith('/')) return err('path must be absolute');
            let items;
            try { items = fs.readdirSync(p, { withFileTypes: true }); } catch (e) { return err(String(e.message)); }
            return textResult(items.map((d) => {
                let st = null;
                try { st = fs.statSync(path.join(p, d.name)); } catch (_) {}
                return { name: d.name, type: d.isDirectory() ? 'dir' : (d.isSymbolicLink() ? 'link' : 'file'), size: st ? st.size : null, mtime: st ? st.mtime.toISOString() : null };
            }));
        }
        case 'read_file': {
            const p = String(a.path || '');
            if (!p.startsWith('/')) return err('path must be absolute');
            let st;
            try { st = fs.statSync(p); } catch (e) { return err(String(e.message)); }
            const cap = Math.min(Number(a.max_bytes) || MAX_FILE, MAX_FILE);
            if (st.size > cap) return err('file too large: ' + st.size + ' > ' + cap);
            try { return textResult(fs.readFileSync(p, 'utf8')); } catch (e) { return err(String(e.message)); }
        }
        case 'write_file': {
            const p = String(a.path || '');
            const content = String(a.content === undefined ? '' : a.content);
            if (!p.startsWith('/')) return err('path must be absolute');
            if (Buffer.byteLength(content) > MAX_FILE) return err('content exceeds ' + MAX_FILE + ' bytes');
            try {
                fs.mkdirSync(path.dirname(p), { recursive: true });
                if (a.append) fs.appendFileSync(p, content, 'utf8');
                else fs.writeFileSync(p, content, 'utf8');
                return textResult({ written: p, bytes: Buffer.byteLength(content), append: !!a.append });
            } catch (e) { return err(String(e.message)); }
        }
        case 'run_command': {
            const cmd = String(a.command || '');
            if (!cmd.trim()) return err('command is empty');
            const r = await sh(cmd, { cwd: a.cwd, timeout: Math.min(Number(a.timeout_ms) || CMD_TIMEOUT, 300000) });
            return textResult({ exit_code: r.code, killed: r.killed, stdout: r.stdout, stderr: r.stderr });
        }
        case 'list_apps':
            return textResult({ count: (await listApps(a.root)).length, apps: await listApps(a.root) });
        case 'launch_app':
        case 'open_url': {
            const target = name === 'open_url' ? String(a.url || '') : (String(a.bundle_id || '') || String(a.url || ''));
            if (!target) return err('provide bundle_id or url');
            const q = "'" + target.replace(/'/g, "'\\''") + "'";
            const attempts = [
                'uiopen ' + q,
                'open ' + q,
                'launchctl open ' + q,
                JB + '/usr/bin/uiopen ' + q,
                JB + '/usr/bin/open ' + q
            ];
            const tried = [];
            for (const c of attempts) {
                const r = await sh(c, { timeout: 15000 });
                tried.push({ cmd: c, exit_code: r.code, stderr: r.stderr.slice(0, 200) });
                if (r.code === 0) return textResult({ launched: target, via: c, tried });
            }
            return err('could not launch/open; uiopen/open/launchctl unavailable. tried=' + JSON.stringify(tried));
        }
        case 'list_processes': {
            const f = String(a.filter || '').replace(/[^a-zA-Z0-9_. -]/g, '');
            const r = await sh('ps aux' + (f ? ' | grep -F ' + "'" + f + "'" + ' | grep -v grep' : ''), { timeout: 20000 });
            return textResult({ exit_code: r.code, output: r.stdout });
        }
        case 'get_syslog': {
            const n = Math.min(Number(a.lines) || 200, 2000);
            const r = await sh('log show --last 5m --style syslog 2>/dev/null | tail -n ' + n, { timeout: 30000 });
            if (r.code === 0 && r.stdout.trim()) return textResult({ source: 'log show', lines: r.stdout });
            return textResult({
                available: false,
                hint: 'No usable system log tool on this device. The bundled provider ships /var/jb/usr/bin/mcp-logreader; check dsh-phone-bridge-ctl status.',
                fallback_output: r.stderr.slice(0, 500)
            });
        }
        case 'dsh_status': {
            const port = Number(a.port) || 3080;
            const r = await sh('ps aux | grep -F "dsh" | grep -v grep', { timeout: 15000 });
            const http = await new Promise((resolve) => {
                const req = http.request({ host: '127.0.0.1', port, path: '/', method: 'GET', timeout: 3000 }, (res) => {
                    res.resume(); resolve(res.statusCode);
                });
                req.on('error', () => resolve(0));
                req.on('timeout', () => { req.destroy(); resolve(0); });
                req.end();
            });
            return textResult({ web_port: port, web_http_status: http, web_reachable: http > 0, processes: r.stdout.trim().split('\n').filter(Boolean).slice(0, 20), bridge_alive: true });
        }
        case 'phone_bridge_status': {
            const up = await upstreamTools(true);
            return textResult({
                version: '1.0.0', protocol: PROTOCOL, endpoint: 'http://' + HOST + ':' + PORT + '/mcp',
                local_tools: LOCAL_TOOLS.length,
                upstream: { url: UPSTREAM, online: up.length > 0, tools: up.length, names: up.map((t) => t.name) },
                merged_tools: LOCAL_TOOLS.length + up.length,
                b_class_offline_hint: up.length === 0 ? UPSTREAM_HINT_TOOLS : []
            });
        }
        default:
            return err('unknown local tool: ' + name);
    }
}

/* ------------------------------------------------------- 上游 ios-mcp 转发 */
let upstreamCache = { at: 0, tools: [], session: '' };

function postJson(url, payload, timeoutMs) {
    return new Promise((resolve, reject) => {
        let u;
        try { u = new URL(url); } catch (e) { reject(e); return; }
        const body = JSON.stringify(payload);
        const headers = {
            'Content-Type': 'application/json',
            'Accept': 'application/json, text/event-stream',
            'MCP-Protocol-Version': PROTOCOL,
            'Content-Length': Buffer.byteLength(body)
        };
        if (payload.method !== 'initialize' && upstreamCache.session) {
            headers['Mcp-Session-Id'] = upstreamCache.session;
        }
        const req = http.request({
            hostname: u.hostname, port: u.port, path: u.pathname + (u.search || ''),
            method: 'POST', headers, timeout: timeoutMs || 2500
        }, (res) => {
            const sid = res.headers['mcp-session-id'];
            if (sid) upstreamCache.session = Array.isArray(sid) ? sid[0] : sid;
            let raw = '';
            res.on('data', (c) => { raw += c; });
            res.on('end', () => {
                // Streamable HTTP 可能返回 application/json 或 text/event-stream
                let text = raw.trim();
                if (res.headers['content-type'] && String(res.headers['content-type']).includes('text/event-stream')) {
                    const lines = text.split('\n').filter((l) => l.startsWith('data:'));
                    text = lines.length ? lines[lines.length - 1].slice(5).trim() : '';
                }
                if (!text) { resolve(null); return; }
                try { resolve(JSON.parse(text)); } catch (_) { resolve(null); }
            });
        });
        req.on('error', reject);
        req.on('timeout', () => { req.destroy(); reject(new Error('upstream timeout')); });
        req.write(body);
        req.end();
    });
}

async function upstreamTools(force) {
    const now = Date.now();
    if (!force && now - upstreamCache.at < 30000) return upstreamCache.tools;
    upstreamCache.at = now;
    try {
        const init = await postJson(UPSTREAM, {
            jsonrpc: '2.0', id: 1, method: 'initialize',
            params: { protocolVersion: PROTOCOL, capabilities: {}, clientInfo: { name: 'dsh-ios-phone-bridge', version: '1.0.0' } }
        }, 2000);
        if (!init || !init.result) { upstreamCache.tools = []; return []; }
        // notification: notifications/initialized（上游没收到也不影响列工具）
        postJson(UPSTREAM, { jsonrpc: '2.0', method: 'notifications/initialized' }, 1500).catch(() => {});
        const listed = await postJson(UPSTREAM, { jsonrpc: '2.0', id: 2, method: 'tools/list', params: {} }, 2500);
        const tools = listed && listed.result && Array.isArray(listed.result.tools) ? listed.result.tools : [];
        upstreamCache.tools = tools;
        return tools;
    } catch (_) {
        upstreamCache.tools = [];
        return [];
    }
}

async function upstreamCall(name, args) {
    try {
        await upstreamTools(false);
        const r = await postJson(UPSTREAM, {
            jsonrpc: '2.0', id: 3, method: 'tools/call',
            params: { name, arguments: args || {} }
        }, 120000);
        if (!r) return err('upstream ios-mcp returned no response');
        if (r.error) return textResult({ upstream_error: r.error }, true);
        return r.result || textResult({});
    } catch (e) {
        return err('upstream ios-mcp unreachable: ' + String(e.message || e));
    }
}

/* ------------------------------------------------------------- JSON-RPC 分发 */
function commonHeaders() {
    return {
        'Content-Type': 'application/json',
        'MCP-Protocol-Version': PROTOCOL,
        'Mcp-Session-Id': SESSION,
        'Access-Control-Allow-Origin': '*',
        'Access-Control-Allow-Headers': 'Content-Type, Accept, MCP-Protocol-Version, Mcp-Session-Id'
    };
}
function reply(res, id, result) {
    res.writeHead(200, commonHeaders());
    res.end(JSON.stringify({ jsonrpc: '2.0', id, result }));
}
function replyError(res, id, code, message) {
    res.writeHead(200, commonHeaders());
    res.end(JSON.stringify({ jsonrpc: '2.0', id, error: { code, message } }));
}

async function dispatch(msg, res) {
    const method = msg.method;
    if (msg.id === undefined) { // notification
        res.writeHead(202, commonHeaders());
        res.end();
        return;
    }
    switch (method) {
        case 'initialize':
            return reply(res, msg.id, {
                protocolVersion: PROTOCOL,
                capabilities: { tools: { listChanged: false } },
                serverInfo: { name: 'dsh-ios-phone-bridge', version: '1.0.0' },
                instructions: 'On-device iOS toolchain for DSH. A-class tools work out of the box; B-class (screen/touch/OCR) come from the bundled SpringBoard provider dsh-ios-control on 127.0.0.1:8090 (shipped with dev.airdevs.dsh-app; respring once after install).'
            });
        case 'ping':
            return reply(res, msg.id, {});
        case 'tools/list': {
            const up = await upstreamTools(false);
            const localNames = new Set(LOCAL_TOOLS.map((t) => t.name));
            const merged = LOCAL_TOOLS.concat(up.filter((t) => !localNames.has(t.name)));
            return reply(res, msg.id, { tools: merged });
        }
        case 'tools/call': {
            const name = msg.params && msg.params.name;
            const args = (msg.params && msg.params.arguments) || {};
            if (!name) return replyError(res, msg.id, -32602, 'missing tool name');
            const localNames = new Set(LOCAL_TOOLS.map((t) => t.name));
            if (localNames.has(name)) return reply(res, msg.id, await callLocal(name, args));
            const up = await upstreamTools(true);
            if (up.some((t) => t.name === name)) return reply(res, msg.id, await upstreamCall(name, args));
            if (UPSTREAM_HINT_TOOLS.includes(name)) {
                return reply(res, msg.id, textResult({
                    error: 'B-class tool "' + name + '" requires the bundled native provider dsh-ios-control on 127.0.0.1:8090.',
                    how_to_enable: [
                        'The provider ships in dev.airdevs.dsh-app (dsh-ios-control.dylib + plist)',
                        'After installing/upgrading, respring once so ElleKit loads it into SpringBoard',
                        'Check dsh-phone-bridge-ctl status; it reports upstream online + tool count',
                        'Keep the device unlocked; the bridge auto-merges tools on the next tools/list'
                    ],
                    local_alternatives: ['run_command', 'list_apps', 'launch_app', 'open_url', 'get_device_info', 'dsh_status']
                }, true));
            }
            return replyError(res, msg.id, -32601, 'unknown tool: ' + name);
        }
        case 'resources/list':
            return reply(res, msg.id, { resources: [] });
        case 'prompts/list':
            return reply(res, msg.id, { prompts: [] });
        default:
            return replyError(res, msg.id, -32601, 'method not found: ' + method);
    }
}

const server = http.createServer((req, res) => {
    if (req.method === 'GET' && (req.url === '/health' || req.url === '/')) {
        res.writeHead(200, Object.assign(commonHeaders(), { 'Content-Type': 'application/json' }));
        res.end(JSON.stringify({
            status: 'ok', server: 'dsh-ios-phone-bridge', version: '1.0.0',
            protocolVersion: PROTOCOL, local_tools: LOCAL_TOOLS.length,
            upstream: UPSTREAM, endpoint: 'http://' + HOST + ':' + PORT + '/mcp'
        }));
        return;
    }
    if (req.method === 'OPTIONS') { res.writeHead(204, commonHeaders()); res.end(); return; }
    if (req.method !== 'POST' || !String(req.url || '').startsWith('/mcp')) {
        res.writeHead(404, commonHeaders()); res.end(); return;
    }
    let body = '';
    req.on('data', (c) => {
        body += c;
        if (body.length > 2 * 1024 * 1024) { req.destroy(); }
    });
    req.on('end', () => {
        let msg;
        try { msg = JSON.parse(body); } catch (_) {
            res.writeHead(400, commonHeaders());
            res.end(JSON.stringify({ jsonrpc: '2.0', id: null, error: { code: -32700, message: 'parse error' } }));
            return;
        }
        Promise.resolve(dispatch(msg, res)).catch((e) => {
            if (!res.headersSent) replyError(res, msg.id, -32603, String(e && e.message || e));
            else res.end();
        });
    });
});

server.on('error', (e) => {
    if (e && e.code === 'EADDRINUSE') {
        // 已有实例在跑：直接退出，让 ensure 逻辑认为「端口已占用 = 已启动」。
        process.stderr.write('dsh-phone-bridge: port ' + PORT + ' already in use (another instance running), exit\n');
        process.exit(0);
    }
    process.stderr.write('dsh-phone-bridge: ' + String(e && e.message || e) + '\n');
    process.exit(1);
});

server.listen(PORT, HOST, () => {
    process.stdout.write('dsh-phone-bridge: listening on http://' + HOST + ':' + PORT + '/mcp (upstream ' + UPSTREAM + ')\n');
});
