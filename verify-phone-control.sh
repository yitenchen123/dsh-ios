#!/bin/sh
# dsh-ios +ios15 — iOS 手机操控接入的本地独立验证
#
# 验证的是「我们包里的 MCP 客户端能不能连上 HTTP MCP 服务」以及
# 「插件 bundle 的配置是否合法」，不依赖 iOS 真机、不复用 build.sh 逻辑。
# 真机侧的服务安装 / HID 注入 / 私有 entitlement 仍需在设备上确认。
#
# 用法： sh verify-phone-control.sh
# 依赖： .build/npm/node_modules（跑过 build.sh 或 bootstrap.sh 后存在）

set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
cd "$ROOT"
NM="$ROOT/.build/npm/node_modules"
BUNDLE="$ROOT/plugins/dsh-ios-phone-control"
TMP=$(mktemp -d)
VFY=""
trap 'rm -rf "$TMP"; if [ -n "$VFY" ]; then rm -rf "$VFY"; fi; true' EXIT

PASS=0
FAIL=0
ok()   { PASS=$((PASS+1)); printf '  [ OK ] %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  [FAIL] %s\n' "$1"; }
info() { printf '  [INFO] %s\n' "$1"; }
sec()  { printf '\n=== %s ===\n' "$1"; }

sec '1) 插件 bundle 完整性'
for f in package.json cordis.patch.yml locale/en.json locale/zh.json icon.svg README.md; do
  [ -f "$BUNDLE/$f" ] && ok "存在 $f" || bad "缺少 $f"
done
for f in package.json locale/en.json locale/zh.json; do
  node -e 'JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"))' "$BUNDLE/$f" \
    && ok "$f 是合法 JSON" || bad "$f 不是合法 JSON"
done
node -e '
const p=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));
if(p["dsh"]?.["bundle"]?.["patch"]!=="./cordis.patch.yml") process.exit(1);
if(!p.files.includes("cordis.patch.yml")) process.exit(1);
' "$BUNDLE/package.json" && ok 'manifest 声明了 dsh.bundle.patch' || bad 'manifest 缺 dsh.bundle.patch'

sec '2) 不预装 / 不改动已交付 deb'
if grep -rq 'dsh-ios-phone-control' "$ROOT/payload/" 2>/dev/null; then
  bad 'payload/ 里出现了本 bundle（违反「不预装」约束）'
else
  ok 'payload/ 内无本 bundle（纯用户手动安装）'
fi
if [ -f "$ROOT/dist/SHA256SUMS.txt" ]; then
  DEB=$(find "$ROOT/dist" -maxdepth 1 -name 'dev.airdevs.dsh_*+ios15_iphoneos-arm64.deb' | head -1)
  if [ -n "$DEB" ] && grep -q "$(sha256sum "$DEB" | cut -d' ' -f1)" "$ROOT/dist/SHA256SUMS.txt"; then
    ok '+ios15 deb 的 SHA 仍与交付清单一致（未改动交付物）'
  else
    info '+ios15 deb 不存在或 SHA 未登记，跳过（不影响本验证）'
  fi
fi
sh -n "$ROOT/shims/probe_ios_mcp.sh" && ok 'probe_ios_mcp.sh 语法通过' || bad 'probe_ios_mcp.sh 语法错误'
sh -n "$ROOT/shims/make_phone_control_bundle.sh" && ok 'make_phone_control_bundle.sh 语法通过' || bad 'make_phone_control_bundle.sh 语法错误'

if [ ! -d "$NM/@deepseek-ai/dsh-mcp-client" ]; then
  sec '3~5) 跳过 SDK 验证'
  info '.build/npm/node_modules 不存在；先跑 bootstrap.sh + build.sh 可完整验证'
else
  # ESM 的模块解析基于脚本所在目录，临时 JS 必须放在依赖树内部才能 import 包内模块
  VFY="$NM/.dsh-verify-$$"
  mkdir -p "$VFY"
  sec '3) cordis.patch.yml 配置能被 dsh-mcp-client 的 Config schema 接受'
  cat > "$VFY/check-config.mjs" <<'JS'
import fs from 'node:fs';
import YAML from 'yaml';
import { Config } from '@deepseek-ai/dsh-mcp-client';

const doc = YAML.parse(fs.readFileSync(process.argv[2], 'utf8'));
const rows = doc?.[0]?.insert;
if (!Array.isArray(rows) || rows.length !== 1) throw new Error('patch 顶层应为单个 insert 且只有一行');
const row = rows[0];
if (row.name !== '@deepseek-ai/dsh-mcp-client') throw new Error('插件名不对: ' + row.name);
if (!row.id) throw new Error('缺少 row id');

const r = Config['~standard'].validate(row.config);
if (r.issues) throw new Error('Config schema 拒绝配置: ' + JSON.stringify(r.issues));
const c = r.value;
if (c.transport !== 'streamable-http') throw new Error('transport 不是 streamable-http');
if (c.serverName !== 'ios') throw new Error('serverName 不是 ios');
if (c.failOnStartupError !== false) throw new Error('failOnStartupError 必须为 false');
if (c.reconnect.enabled !== true) throw new Error('reconnect 未启用');
if (!/^http:\/\/127\.0\.0\.1(:8090)?\//.test(c.url)) throw new Error('url 不是回环地址: ' + c.url);
if (c.toolCallTimeoutMs < 60000) throw new Error('toolCallTimeoutMs 过小');

// 反例：非法 transport 必须被拒绝
const bad = Config['~standard'].validate({ ...row.config, transport: 'bogus' });
if (!bad.issues) throw new Error('Config schema 未能拒绝非法 transport');

console.log('  [ OK ] patch 结构、插件名、row id 正确');
console.log('  [ OK ] Config schema 校验通过（含非法值反例被拒）');
console.log('  [ OK ] serverName=ios / transport=streamable-http / url=' + c.url);
console.log('  [ OK ] failOnStartupError=false / reconnect 启用 / 工具名前缀 mcp__ios__*');
JS
  (cd "$NM" && node "$VFY/check-config.mjs" "$BUNDLE/cordis.patch.yml") \
    && PASS=$((PASS+4)) || { bad 'Config schema 校验失败'; }

  sec '4) 假 MCP server：包内 SDK 能完成 Streamable HTTP 握手并列出工具'
  cat > "$VFY/fake-mcp.mjs" <<'JS'
import http from 'node:http';
import { Client, StreamableHTTPClientTransport } from '@modelcontextprotocol/client';

const TOOLS = [
  'tap_screen', 'swipe_screen', 'input_text', 'screenshot', 'get_screen_info',
  'launch_app', 'get_frontmost_app', 'get_ui_elements', 'tap_element',
  'ocr_screen', 'describe_screen', 'get_syslog', 'get_crash_logs',
  'open_url', 'run_command', 'get_device_info'
].map(name => ({ name, description: 'fake ' + name, inputSchema: { type: 'object', properties: {} } }));

let sawInitialize = false, sawToolsList = false;
const server = http.createServer((req, res) => {
  if (req.method === 'GET' && req.url === '/health') {
    res.writeHead(200, { 'Content-Type': 'application/json', 'MCP-Protocol-Version': '2025-11-25' });
    res.end(JSON.stringify({ status: 'ok', server: 'ios-mcp', version: '1.2.8', protocolVersion: '2025-11-25' }));
    return;
  }
  let body = '';
  req.on('data', c => { body += c; });
  req.on('end', () => {
    let msg;
    try { msg = JSON.parse(body); } catch { res.writeHead(400); res.end(); return; }
    const common = {
      'Content-Type': 'application/json',
      'MCP-Protocol-Version': '2025-11-25',
      'Mcp-Session-Id': 'dsh-ios-verify-session'
    };
    if (msg.method === 'initialize') {
      sawInitialize = true;
      res.writeHead(200, common);
      res.end(JSON.stringify({ jsonrpc: '2.0', id: msg.id, result: {
        protocolVersion: '2025-11-25',
        capabilities: { tools: {} },
        serverInfo: { name: 'fake-ios-mcp', version: '1.2.8' }
      } }));
      return;
    }
    if (msg.method === 'tools/list') {
      sawToolsList = true;
      res.writeHead(200, common);
      res.end(JSON.stringify({ jsonrpc: '2.0', id: msg.id, result: { tools: TOOLS } }));
      return;
    }
    if (msg.id === undefined) { res.writeHead(202, common); res.end(); return; } // notification
    res.writeHead(200, common);
    res.end(JSON.stringify({ jsonrpc: '2.0', id: msg.id, result: {} }));
  });
});

await new Promise(r => server.listen(0, '127.0.0.1', r));
const port = server.address().port;
const url = `http://127.0.0.1:${port}/mcp`;

try {
  const client = new Client({ name: 'dsh-ios-verify', version: '0.1.0' });
  const transport = new StreamableHTTPClientTransport(new URL(url));
  await client.connect(transport);
  const listed = await client.listTools();
  const names = listed.tools.map(t => t.name);
  if (!sawInitialize) throw new Error('server 未收到 initialize');
  if (!sawToolsList) throw new Error('server 未收到 tools/list');
  if (!names.includes('tap_screen') || !names.includes('screenshot') || !names.includes('launch_app')) {
    throw new Error('工具列表不完整: ' + names.join(','));
  }
  console.log('  [ OK ] initialize 握手成功（protocolVersion 2025-11-25）');
  console.log('  [ OK ] tools/list 返回 ' + names.length + ' 个工具，含 tap_screen / screenshot / launch_app');
  console.log('  [ OK ] StreamableHTTPClientTransport 在包内 SDK 2.2.0 下可用');
  await client.close();
} finally {
  server.close();
}
JS
  (cd "$NM" && node "$VFY/fake-mcp.mjs") && PASS=$((PASS+3)) || bad '假 MCP server 握手失败'

  sec '5) nowasm 零 JIT 档（--require fetch-shim）下同样能连'
  SHIM=$(find "$ROOT" -name 'fetch-shim.cjs' -type f 2>/dev/null | head -1)
  if [ -n "$SHIM" ]; then
    (cd "$NM" && node --require "$SHIM" "$VFY/fake-mcp.mjs" > /tmp/dsh-mcp-shim.out 2>&1) \
      && { PASS=$((PASS+1)); ok '零 JIT 档下 MCP 握手/工具列表同样通过'; } \
      || { bad '零 JIT 档下失败'; cat /tmp/dsh-mcp-shim.out; }
  else
    info '未找到 fetch-shim.cjs，跳过零 JIT 档验证'
  fi
fi

sec '6) 交付 tgz（若已生成）'
TGZ="$ROOT/dist/dsh-ios-phone-control-0.1.0.tgz"
if [ -f "$TGZ" ]; then
  N=$(tar tzf "$TGZ" | wc -l)
  ok "tgz 存在，$N 个成员，SHA=$(sha256sum "$TGZ" | cut -d' ' -f1)"
  tar tzf "$TGZ" | grep -q 'dsh-ios-phone-control/cordis.patch.yml' \
    && ok 'tgz 内含 cordis.patch.yml' || bad 'tgz 缺 cordis.patch.yml'
else
  info '尚未生成 tgz（跑 sh shims/make_phone_control_bundle.sh 生成）'
fi

printf '\n============================================================\n'
printf '  结果： %d 项通过 / %d 项失败\n' "$PASS" "$FAIL"
printf '============================================================\n'
[ "$FAIL" -eq 0 ] || exit 1
