#!/bin/sh
# ============================================================================
# verify-phone-bridge.sh —— 内置手机工具链的本地独立验证（不需要 iOS 真机）
#
# 验证的是用户那句「启动 DSH 让 DSH 操作手机，能够直接调用相关工具链」：
#   1) bridge 是一个真的 MCP Streamable HTTP 服务，包内 SDK 能握手并列工具；
#   2) A 层工具（设备信息 / 命令 / 读写文件 / App / DSH 状态）真能调用；
#   3) 上游原生 ios-mcp 在线时，B 层工具会合并进 tools/list 且 tools/call
#      能原样转发；离线时给出明确指引；
#   4) ensure-config.cjs 幂等注册，且写出的 cordis.patch.yml 顶层是数组、
#      能被 dsh-mcp-client 的 Config schema 接受；
#   5) 零 JIT 档（--require fetch-shim.cjs）同样能跑。
#
# 用法: sh verify-phone-bridge.sh
# 依赖: .build/npm/node_modules（跑过 build.sh/bootstrap.sh 后存在）
# ============================================================================
set -u
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
BR="$ROOT/phone-bridge"
NM="$ROOT/.build/npm/node_modules"
TMP=$(mktemp -d /tmp/dsh-bridge-verify.XXXXXX) || exit 2
VFY=""
BRIDGE_PID=""
UP_PID=""
trap 'if [ -n "$BRIDGE_PID" ]; then kill "$BRIDGE_PID" 2>/dev/null || true; fi; if [ -n "$UP_PID" ]; then kill "$UP_PID" 2>/dev/null || true; fi; if [ -n "$VFY" ]; then rm -rf "$VFY"; fi; rm -rf "$TMP"; true' EXIT HUP INT TERM

PASS=0; FAIL=0
ok(){ printf '  [ OK ] %s\n' "$1"; PASS=$((PASS+1)); }
bad(){ printf '  [FAIL] %s\n' "$1"; FAIL=$((FAIL+1)); }
sec(){ printf '\n=== %s ===\n' "$1"; }
NODE=$(command -v node || echo node)

sec '1) 组件完整性 / 语法'
for f in server.cjs ensure-config.cjs dsh-phone-bridge-daemon dsh-phone-bridge-ctl dev.airdevs.dsh.phone-bridge.plist; do
    [ -f "$BR/$f" ] && ok "存在 $f" || bad "缺少 $f"
done
"$NODE" --check "$BR/server.cjs" && ok 'server.cjs 语法通过' || bad 'server.cjs 语法错误'
"$NODE" --check "$BR/ensure-config.cjs" && ok 'ensure-config.cjs 语法通过' || bad 'ensure-config.cjs 语法错误'
sh -n "$BR/dsh-phone-bridge-daemon" && ok 'daemon 脚本 sh -n 通过' || bad 'daemon 脚本语法错误'
sh -n "$BR/dsh-phone-bridge-ctl" && ok 'ctl 脚本 sh -n 通过' || bad 'ctl 脚本语法错误'
"$NODE" -e 'const fs=require("fs");const s=fs.readFileSync(process.argv[1],"utf8");if(!/RunAtLoad|KeepAlive/.test(s))process.exit(1);if(!s.includes("dev.airdevs.dsh.phone-bridge"))process.exit(1)' "$BR/dev.airdevs.dsh.phone-bridge.plist" \
    && ok 'plist 含 Label / RunAtLoad / KeepAlive' || bad 'plist 关键键缺失'

sec '2) ensure-config.cjs：幂等注册 / 顶层数组 / Config schema'
if [ -d "$NM/@deepseek-ai/dsh-mcp-client" ]; then
    VFY="$NM/.dsh-bridge-verify-$$"
    mkdir -p "$VFY"
    cat > "$VFY/check-config.mjs" <<'JS'
import fs from 'node:fs';
import YAML from 'yaml';
import { Config } from '@deepseek-ai/dsh-mcp-client';
const home = process.argv[2];
const files = [home + '/cordis.patch.yml', home + '/profiles/web/cordis.patch.yml'];
for (const f of files) {
    const text = fs.readFileSync(f, 'utf8');
    const doc = YAML.parse(text);
    if (!Array.isArray(doc)) throw new Error('顶层不是数组: ' + f);
    const row = doc.flatMap(e => (e && e.insert) ? e.insert : []).find(r => r && r.id === 'dsh-ios-phone-bridge-mcp');
    if (!row) throw new Error('缺本工具链块: ' + f);
    if (row.name !== '@deepseek-ai/dsh-mcp-client') throw new Error('插件名不对');
    const r = Config['~standard'].validate(row.config);
    if (r.issues) throw new Error('Config schema 拒绝: ' + JSON.stringify(r.issues));
    const c = r.value;
    if (c.transport !== 'streamable-http' || c.serverName !== 'ios') throw new Error('transport/serverName 不对');
    if (c.failOnStartupError !== false) throw new Error('failOnStartupError 必须为 false');
    if (c.url !== 'http://127.0.0.1:8091/mcp') throw new Error('url 不对: ' + c.url);
    if (!c.reconnect.enabled || c.reconnect.maxAttempts < 10) throw new Error('reconnect 未正确配置');
}
console.log('  [ OK ] 两个 patch 文件顶层均为数组，含且仅含一处工具链块');
console.log('  [ OK ] dsh-mcp-client Config schema 校验通过（url/transport/reconnect/failOnStartupError）');
JS
    mkdir -p "$TMP/home/profiles/web"
    printf '# user patch\n[]\n' > "$TMP/home/cordis.patch.yml"
    printf '# web profile\n[]\n' > "$TMP/home/profiles/web/cordis.patch.yml"
    "$NODE" "$BR/ensure-config.cjs" "$TMP/home" on > "$TMP/on1.json" 2>"$TMP/on1.err" \
        && ok '第一次 on 执行成功' || { bad '第一次 on 失败'; cat "$TMP/on1.err"; }
    "$NODE" "$BR/ensure-config.cjs" "$TMP/home" on > "$TMP/on2.json" 2>/dev/null \
        && ok '第二次 on 执行成功（幂等重跑）' || bad '第二次 on 失败'
    A=$(sha256sum "$TMP/home/cordis.patch.yml" | cut -d' ' -f1)
    "$NODE" "$BR/ensure-config.cjs" "$TMP/home" on >/dev/null 2>&1
    B=$(sha256sum "$TMP/home/cordis.patch.yml" | cut -d' ' -f1)
    [ "$A" = "$B" ] && ok '幂等：重复 on 后文件字节不变' || bad '幂等失败：文件被改写'
    (cd "$NM" && "$NODE" "$VFY/check-config.mjs" "$TMP/home") \
        && { PASS=$((PASS+2)); } || bad 'patch 结构 / Config schema 校验失败'
    "$NODE" "$BR/ensure-config.cjs" "$TMP/home" off >/dev/null 2>&1 \
        && ok 'off 执行成功' || bad 'off 失败'
    if grep -q 'dsh-ios-phone-bridge-mcp' "$TMP/home/cordis.patch.yml" 2>/dev/null; then
        bad 'off 后仍残留工具链块'
    else
        ok 'off 后块已移除，且顶层仍是合法数组'
    fi
    "$NODE" -e 'const fs=require("fs");const s=fs.readFileSync(process.argv[1],"utf8");if(!/^\[\s*\]/m.test(s))process.exit(1)' "$TMP/home/cordis.patch.yml" \
        && ok 'off 后文件回落到 []（不会 fatal）' || bad 'off 后文件形态异常'
else
    bad '缺 .build/npm/node_modules/@deepseek-ai/dsh-mcp-client，跳过 Config 校验'
fi

sec '3) 真 MCP 握手 + A 层工具调用 + 上游 B 层合并/转发'
if [ -d "$NM/@modelcontextprotocol/client" ]; then
    [ -n "$VFY" ] || { VFY="$NM/.dsh-bridge-verify-$$"; mkdir -p "$VFY"; }
    # 假上游 ios-mcp：提供一个 B 层工具 tap_screen
    cat > "$VFY/fake-upstream.cjs" <<'JS'
const http=require('node:http');
const s=http.createServer((req,res)=>{
  let b='';req.on('data',c=>b+=c);req.on('end',()=>{
    let m;try{m=JSON.parse(b)}catch(_){res.writeHead(400);res.end();return}
    const h={'Content-Type':'application/json','MCP-Protocol-Version':'2025-11-25','Mcp-Session-Id':'upstream-session'};
    let result={};
    if(m.method==='initialize') result={protocolVersion:'2025-11-25',capabilities:{tools:{}},serverInfo:{name:'fake-ios-mcp',version:'1.0'}};
    else if(m.method==='tools/list') result={tools:[{name:'tap_screen',description:'fake tap',inputSchema:{type:'object',properties:{x:{type:'number'},y:{type:'number'}}}},{name:'screenshot',description:'fake shot',inputSchema:{type:'object',properties:{}}}]};
    else if(m.method==='tools/call') result={content:[{type:'text',text:'upstream tapped '+JSON.stringify(m.params.arguments)}]};
    else if(m.id===undefined){res.writeHead(202,h);res.end();return}
    res.writeHead(200,h);res.end(JSON.stringify({jsonrpc:'2.0',id:m.id,result}));
  });
});
s.listen(Number(process.argv[2]),'127.0.0.1',()=>console.log('FAKE_UPSTREAM_READY'));
JS
    UPORT=18090; BPORT=18091
    "$NODE" "$VFY/fake-upstream.cjs" "$UPORT" > "$TMP/up.log" 2>&1 & UP_PID=$!
    i=0; while [ "$i" -lt 40 ]; do grep -q FAKE_UPSTREAM_READY "$TMP/up.log" 2>/dev/null && break; i=$((i+1)); sleep 0.2; done
    grep -q FAKE_UPSTREAM_READY "$TMP/up.log" 2>/dev/null && ok '假上游 ios-mcp 已启动' || bad '假上游启动失败'

    DSH_IOS_MCP_URL="http://127.0.0.1:$UPORT/mcp" DSH_BRIDGE_PORT="$BPORT" DSH_HOME="$TMP/home" \
        "$NODE" "$BR/server.cjs" > "$TMP/bridge.log" 2>&1 & BRIDGE_PID=$!
    i=0; while [ "$i" -lt 40 ]; do grep -q 'listening on' "$TMP/bridge.log" 2>/dev/null && break; i=$((i+1)); sleep 0.2; done
    grep -q 'listening on' "$TMP/bridge.log" 2>/dev/null && ok 'bridge 已监听' || { bad 'bridge 启动失败'; cat "$TMP/bridge.log"; }

    cat > "$VFY/e2e.mjs" <<'JS'
import { Client, StreamableHTTPClientTransport } from '@modelcontextprotocol/client';
const port = Number(process.argv[2]);
const tmp = process.argv[3];
const client = new Client({ name: 'dsh-ios-bridge-verify', version: '1.0.0' });
await client.connect(new StreamableHTTPClientTransport(new URL(`http://127.0.0.1:${port}/mcp`)));
const listed = await client.listTools();
const names = listed.tools.map(t => t.name);
for (const n of ['get_device_info','run_command','read_file','write_file','list_apps','launch_app','open_url','dsh_status','phone_bridge_status']) {
  if (!names.includes(n)) throw new Error('缺 A 层工具: ' + n);
}
console.log('  [ OK ] initialize + tools/list 成功，A 层 9 个必备工具齐全');
for (const n of ['tap_screen','screenshot']) {
  if (!names.includes(n)) throw new Error('上游 B 层工具未合并: ' + n);
}
console.log('  [ OK ] 上游 ios-mcp 的 B 层工具已合并进 tools/list（共 ' + names.length + ' 个）');
const call = async (name, args) => {
  const r = await client.callTool({ name, arguments: args || {} });
  const text = (r.content || []).map(c => c.text || '').join('');
  if (r.isError) throw new Error(name + ' 返回 isError: ' + text.slice(0, 200));
  return text;
};
const info = await call('get_device_info');
if (!info.includes('node') || !info.includes('dsh_home')) throw new Error('get_device_info 内容异常');
console.log('  [ OK ] tools/call get_device_info 返回结构化设备信息');
const echo = await call('run_command', { command: 'echo DSH_BRIDGE_OK' });
if (!echo.includes('DSH_BRIDGE_OK') || !echo.includes('exit_code')) throw new Error('run_command 异常: ' + echo);
console.log('  [ OK ] tools/call run_command 真执行 shell 并返回 exit_code/stdout');
const p = tmp + '/bridge-write-test.txt';
await call('write_file', { path: p, content: 'hello-from-dsh' });
const read = await call('read_file', { path: p });
if (!read.includes('hello-from-dsh')) throw new Error('write/read_file 往返失败');
console.log('  [ OK ] tools/call write_file + read_file 往返一致');
const st = await call('phone_bridge_status');
if (!st.includes('"online": true')) throw new Error('bridge 未识别到上游在线: ' + st.slice(0, 300));
console.log('  [ OK ] phone_bridge_status 正确报告上游在线与合并工具数');
const tap = await call('tap_screen', { x: 100, y: 200 });
if (!tap.includes('upstream tapped')) throw new Error('B 层工具未转发到上游: ' + tap.slice(0, 200));
console.log('  [ OK ] tools/call tap_screen 原样转发到上游 ios-mcp 并返回结果');
await client.close();
JS
    (cd "$NM" && "$NODE" "$VFY/e2e.mjs" "$BPORT" "$TMP") && PASS=$((PASS+7)) || bad 'MCP 端到端握手/工具调用失败（见上）'
else
    bad '缺 @modelcontextprotocol/client，跳过 MCP 端到端验证'
fi

sec '4) 零 JIT 档（A11 上 undici/llhttp WASM 会 SIGBUS）'
SHIM=$(find "$ROOT" -name 'fetch-shim.cjs' -type f 2>/dev/null | head -1)
if [ -n "$SHIM" ] && [ -n "$VFY" ]; then
    ZPORT=18092
    DSH_BRIDGE_PORT="$ZPORT" DSH_HOME="$TMP/home" \
        "$NODE" --jitless --no-expose-wasm --require "$SHIM" --expose-internals "$BR/server.cjs" \
        > "$TMP/bridge-jitless.log" 2>&1 & ZPID=$!
    i=0; ZOK=0
    while [ "$i" -lt 40 ]; do
        if "$NODE" -e 'const http=require("http");const r=http.get({host:"127.0.0.1",port:Number(process.argv[1]),path:"/health",timeout:1000},s=>{s.resume();process.exit(s.statusCode===200?0:1)});r.on("error",()=>process.exit(1));r.on("timeout",()=>{r.destroy();process.exit(1)})' "$ZPORT" >/dev/null 2>&1; then ZOK=1; break; fi
        i=$((i+1)); sleep 0.2
    done
    kill "$ZPID" 2>/dev/null || true
    [ "$ZOK" -eq 1 ] && ok '零 JIT 档下 bridge 正常启动并响应 /health' || bad '零 JIT 档启动失败'
else
    bad '缺 fetch-shim.cjs 或验证目录，跳过零 JIT 档'
fi

printf '\n=== 汇总: OK=%s FAIL=%s ===\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] && echo '✔ 内置手机工具链核验全部通过' || exit 1
exit 0
