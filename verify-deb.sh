#!/bin/sh
# ============================================================================
# verify-deb.sh —— 从【交付 deb】独立解包核验 +ios15 全部落地条件。
#
# 为什么需要它：build.sh 里的强校验是「自己构建自己验」，无法证明用户拿到
# 的那个 .deb 真含修复。本脚本不调用 build.sh、不复用其校验逻辑，直接对
# dpkg-deb -x 解出来的文件树逐项断言；语法/功能检查用宿主机 node 真跑，
# 因此可在任何 Linux/macOS 上离线验证，不需要 iOS 真机。
#
# 用法: sh verify-deb.sh [deb路径] [fix-ios15.sh路径]
#   默认: dist/dev.airdevs.dsh_0.2.1-rc.5+ios15_iphoneos-arm64.deb
#         dist/fix-ios15.sh
# 退出码 0 = 全部通过；非 0 = 有 [FAIL]。
# ============================================================================
set -u
ROOT_DIR=$(cd "$(dirname "$0")" && pwd)
DEB="${1:-$ROOT_DIR/dist/dev.airdevs.dsh_0.2.1-rc.5+ios15_iphoneos-arm64.deb}"
FIXSH="${2:-$ROOT_DIR/dist/fix-ios15.sh}"
NODE="${DSH_NODE:-$(command -v node)}"

[ -f "$DEB" ]   || { echo "找不到 deb: $DEB" >&2; exit 2; }
[ -n "$NODE" ]  || { echo "找不到 node（可用 DSH_NODE 指定）" >&2; exit 2; }
command -v dpkg-deb >/dev/null 2>&1 || { echo "缺 dpkg-deb" >&2; exit 2; }

TMP=$(mktemp -d /tmp/dsh-verify-deb.XXXXXX) || exit 2
trap 'rm -rf "$TMP"' EXIT HUP INT TERM
echo "=== 解包 $DEB ==="
dpkg-deb -x "$DEB" "$TMP" || { echo "解包失败" >&2; exit 2; }

ROOT="$TMP/var/jb"
D="$ROOT/usr/lib/dsh"
NM="$D/node_modules"
FRONT="$NM/@deepseek-ai/dsh-web-frontend/dist"
PASS=0; FAIL=0
ok(){  printf '  [ OK ] %s\n' "$1"; PASS=$((PASS+1)); }
bad(){ printf '  [FAIL] %s\n' "$1"; FAIL=$((FAIL+1)); }
has(){ grep -q -- "$2" "$1" 2>/dev/null; }
nohas(){ ! grep -q -- "$2" "$1" 2>/dev/null; }
same(){ cmp -s "$1" "$2" 2>/dev/null; }

PM="$NM/@deepseek-ai/dsh-plugin-manager/lib/index.js"
MK="$NM/@deepseek-ai/dsh-plugin-market/lib/index.js"
WP="$NM/@deepseek-ai/dsh-plugin-market/lib/worker-parse.cjs"
CJS="$NM/@deepseek-ai/dsh-client-ui-plugin-manager/lib/client.js"
TOOLS="$NM/@deepseek-ai/dsh-plugin-manager/lib/types/tools.js"
OPS="$NM/@deepseek-ai/dsh-plugin-manager/lib/types/operations.js"

echo "=== 交付 deb 解包树独立核验 / node=$($NODE -v) ==="
echo

echo "--- A. 关键文件存在性 ---"
for f in "$PM" "$MK" "$WP" "$CJS" "$TOOLS" "$OPS" \
         "$D/apply_plugin_install_patch.cjs" "$D/apply_frontend_inject.cjs" \
         "$D/safari16-polyfill.js" "$D/dsh-ios-manual-install-transform.js" \
         "$D/fix-ios15.sh" "$FRONT/index.html" \
         "$FRONT/assets/safari16-polyfill.js" \
         "$FRONT/assets/dsh-ios-manual-install-transform.js" \
         "$ROOT/usr/bin/dsh" "$ROOT/usr/bin/dsh-doctor" "$ROOT/usr/bin/pnpm"; do
    if [ -f "$f" ]; then ok "存在 $(printf '%s' "$f" | sed "s#$ROOT/##")"; else bad "缺失 $(printf '%s' "$f" | sed "s#$ROOT/##")"; fi
done

echo "--- B. 修复 A：GitHub 手动安装 git 预检短路 ---"
has "$PM" 'dsh-ios +ios15'          && ok "dsh-plugin-manager 带 +ios15 标记"            || bad "缺 +ios15 标记"
has "$PM" 'DSH_IOS_KEEP_GIT_PROBE'  && ok "checkGithubConnection 预检已短路"              || bad "git 预检未短路"
has "$PM" 'git-probe-shortcircuit'  && ok "短路标记存在（可审计）"                        || bad "短路标记缺失"

echo "--- C. 修复 B：插件市场加载（redirect follow + 主线程解析）---"
has "$MK" 'redirect: "follow"'      && ok "fetchIndex 已改 redirect: follow"               || bad "仍是 redirect: error"
nohas "$MK" 'redirect: "error"'     && ok "包内已无 redirect: error 残留"                  || bad "仍有 redirect: error"
has "$MK" 'market-main-thread'      && ok "parseIndexInWorker 已改主线程解析"              || bad "仍走子 Worker"
has "$MK" '__dshParseIndexBody'     && ok "主线程解析函数已注入"                           || bad "解析函数未注入"
has "$WP" 'module.exports'          && ok "worker-parse.cjs 已派生为可 require 模块"       || bad "worker-parse.cjs 未派生"
nohas "$MK" 'new Worker'            && ok "市场代码已不含 new Worker（A11 不 SIGBUS）"      || bad "仍残留 new Worker"

echo "--- D. 修复 C：仅 Web UI 手动安装生效（硬约束）---"
has "$CJS" '__dshIosTransformSpec'  && ok "Web UI 手动安装 client.js 已注入转化钩子"       || bad "转化钩子未注入"
LEAK=0
has "$TOOLS" '__dshIosTransformSpec' && LEAK=$((LEAK+1))
has "$OPS"   '__dshIosTransformSpec' && LEAK=$((LEAK+1))
if [ "$LEAK" -eq 0 ]; then ok "AI 帮你装(tools.js) / CLI(operations.js) 均 0 泄漏"; else bad "转化钩子泄漏到 AI/CLI 路径（$LEAK 处）"; fi
EXTRA=$(grep -rl '__dshIosTransformSpec' "$NM/@deepseek-ai" 2>/dev/null \
        | grep -v 'dsh-client-ui-plugin-manager/lib/client.js' \
        | grep -v 'dsh-web-frontend/dist' | wc -l | tr -d ' ')
if [ "$EXTRA" -eq 0 ]; then ok "全依赖树无越界注入（除 client.js 与前端 asset）"; else bad "有 $EXTRA 个越界文件"; fi

echo "--- E. 前端注入顺序与字节一致性 ---"
H="$FRONT/index.html"
has "$H" 'assets/safari16-polyfill.js'                && ok "index.html 引用 safari16-polyfill.js"        || bad "缺 polyfill 引用"
has "$H" 'assets/dsh-ios-manual-install-transform.js' && ok "index.html 引用 转化逻辑"                    || bad "缺转化逻辑引用"
FIRST_MODULE=$(grep -n 'script type="module"' "$H" | head -1 | cut -d: -f1)
P_LINE=$(grep -n 'assets/safari16-polyfill.js' "$H" | head -1 | cut -d: -f1)
T_LINE=$(grep -n 'assets/dsh-ios-manual-install-transform.js' "$H" | head -1 | cut -d: -f1)
if [ -n "$FIRST_MODULE" ] && [ "${P_LINE:-99999}" -lt "$FIRST_MODULE" ] && [ "${T_LINE:-99999}" -lt "$FIRST_MODULE" ]; then
    ok "两个垫片引用都在第一个 module script 之前（行 $P_LINE/$T_LINE < $FIRST_MODULE）"
else
    bad "垫片引用落在 module 之后（module=$FIRST_MODULE p=$P_LINE t=$T_LINE）"
fi
same "$D/safari16-polyfill.js" "$FRONT/assets/safari16-polyfill.js" && ok "前端 polyfill 与包内源文件逐字节一致" || bad "前端 polyfill 与源文件不一致"
same "$D/dsh-ios-manual-install-transform.js" "$FRONT/assets/dsh-ios-manual-install-transform.js" && ok "前端转化逻辑与包内源文件逐字节一致" || bad "前端转化逻辑与源文件不一致"
has "$FRONT/assets/safari16-polyfill.js" 'RegExp.escape' && ok "扩展垫片含 RegExp.escape（+ios15）" || bad "垫片未扩展"

echo "--- F. 语法可加载（宿主机 node --check / require）---"
for f in "$WP" "$CJS" "$MK" "$PM" "$TOOLS" "$OPS" \
         "$D/safari16-polyfill.js" "$D/dsh-ios-manual-install-transform.js" \
         "$FRONT/assets/safari16-polyfill.js" "$FRONT/assets/dsh-ios-manual-install-transform.js"; do
    if "$NODE" --check "$f" >/dev/null 2>&1; then ok "--check $(printf '%s' "$f" | sed "s#$NM/##")"; else bad "语法错误 $(printf '%s' "$f" | sed "s#$NM/##")"; fi
done
if "$NODE" -e 'const m=require(process.argv[1]);if(typeof m.parseIndexBody!=="function")process.exit(1)' "$WP" 2>/dev/null; then
    ok "worker-parse.cjs 可 require 且导出 parseIndexBody 函数"
else
    bad "worker-parse.cjs 无法 require 或导出异常"
fi

echo "--- G. 转化逻辑功能回归（vm 模拟 window，32 用例 + 不兼容提示）---"
"$NODE" - "$D/dsh-ios-manual-install-transform.js" <<'JS'
const fs=require('fs'),vm=require('vm');
const code=fs.readFileSync(process.argv[2],'utf8');
const notices=[];
const sandbox={console:{warn(){},info(){}},CustomEvent:function(t,o){this.type=t;this.detail=o&&o.detail},
               dispatchEvent(e){notices.push(e)},__dshIosInstallNotices:[]};
sandbox.window=sandbox; vm.createContext(sandbox); vm.runInContext(code,sandbox);
const T=sandbox.__dshIosTransformSpec;
if(typeof T!=='function'){console.log('FAIL: 未导出 __dshIosTransformSpec');process.exit(1)}
const cases=[
 ['https://github.com/xmanrui/dsh-im','github:xmanrui/dsh-im'],
 ['https://github.com/tencent-connect/dsh-qqbot','github:tencent-connect/dsh-qqbot'],
 ['https://github.com/foo/bar','github:foo/bar'],
 ['https://github.com/foo/bar/','github:foo/bar'],
 ['https://github.com/foo/bar.git','github:foo/bar'],
 ['https://github.com/foo/bar.git/','github:foo/bar'],
 ['https://github.com/foo/bar/tree/main','github:foo/bar#main'],
 ['https://github.com/foo/bar/tree/release/v2','github:foo/bar#release/v2'],
 ['https://github.com/foo/bar/tree/feat/ios15','github:foo/bar#feat/ios15'],
 ['https://github.com/foo/bar/tree/main/','github:foo/bar#main'],
 ['https://github.com/foo/bar/tree/release/v2/','github:foo/bar#release/v2'],
 ['https://github.com/foo/bar/tree/v1.2.3#tag','github:foo/bar#tag'],
 ['https://github.com/foo/bar/tree/release/v2#tag','github:foo/bar#tag'],
 ['https://github.com/foo/bar#v1.2.3','github:foo/bar#v1.2.3'],
 ['https://github.com/foo/bar.git#v1.2.3','github:foo/bar#v1.2.3'],
 ['git@github.com:tencent-connect/dsh-qqbot.git','github:tencent-connect/dsh-qqbot'],
 ['git@github.com:foo/bar.git#v1.2.3','github:foo/bar#v1.2.3'],
 ['git+ssh://git@github.com/foo/bar.git','github:foo/bar'],
 ['git+ssh://git@github.com/foo/bar.git#v1.2.3','github:foo/bar#v1.2.3'],
 ['git+https://github.com/foo/bar.git','github:foo/bar'],
 ['git+https://github.com/foo/bar.git#v1.2.3','github:foo/bar#v1.2.3'],
 ['git+https://github.com/foo/bar/tree/release/v2','github:foo/bar#release/v2'],
 ['git://github.com/foo/bar.git','github:foo/bar'],
 ['github:foo/bar#v1.2.3','github:foo/bar#v1.2.3'],
 ['@deepseek-ai/dsh-demo@1.2.3','@deepseek-ai/dsh-demo@1.2.3'],
 ['dsh-im@^2.0.0','dsh-im@^2.0.0'],
 ['https://example.com/pkg.tgz','https://example.com/pkg.tgz'],
 ['https://github.com/foo/bar/releases/download/v1/pkg.tgz','https://github.com/foo/bar/releases/download/v1/pkg.tgz'],
 ['/var/mobile/plugin','/var/mobile/plugin'],
 ['file:./local','file:./local'],
 ['git@gitlab.com:foo/bar.git','git@gitlab.com:foo/bar.git'],
 ['https://github.com/foo/bar/blob/main/README.md','https://github.com/foo/bar/blob/main/README.md'],
];
let bad=0;
for(const [inp,exp] of cases){const got=T(inp);if(got!==exp){console.log('FAIL: '+inp+' -> '+got+' (期望 '+exp+')');bad++}}
if(T('better-sqlite3')!=='better-sqlite3'){console.log('FAIL: 不兼容插件被拦截/改写');bad++}
if(sandbox.__dshIosInstallNotices.length<1){console.log('FAIL: 不兼容插件未给提示');bad++}
if(bad){console.log('FAIL: '+bad+' 个用例未通过 / 共 '+cases.length);process.exit(1)}
console.log('OK: '+cases.length+' 个转化用例 + 不兼容提示全部通过');
JS
if [ $? -eq 0 ]; then ok "转化逻辑 32 个用例 + 不兼容提示全部通过"; else bad "转化逻辑功能回归失败（见上）"; fi

echo "--- H. +ios14 及更早回归项（不能退化）---"
has "$PM" 'dsh-ios +ios14' && ok "pnpm 绝对路径直连补丁在（service）" || bad "service 缺 +ios14 补丁"
has "$OPS" 'dsh-ios +ios14' && ok "pnpm 绝对路径直连补丁在（CLI）" || bad "CLI 缺 +ios14 补丁"
has "$OPS" '__dshPnpmFlags' && ok "零 JIT pnpm flags 在（CLI）" || bad "CLI 缺零 JIT flags"
PJ="$NM/@deepseek-ai/dsh-session-persistence-jsonl/lib/index.js"
has "$PJ" 'const DEFAULT_COMPRESSION = "none";' && ok "会话默认压缩 none（重启不丢对话）" || bad "会话压缩回退到 zstd"
SHIM="$D/fetch-shim.cjs"
has "$SHIM" '_bodyLocked' && ok "fetch-shim Response.body 幂等在（不报 TRANSPORT）" || bad "fetch-shim 缺幂等修复"
has "$ROOT/usr/bin/dsh" 'TIER_SQLITE_ARGS' && ok "dsh 启动链路带 --experimental-sqlite" || bad "启动链路缺 sqlite 开关"
has "$ROOT/usr/bin/dsh-doctor" 'DSH_IOS_KEEP_GIT_PROBE' && ok "dsh-doctor 含 +ios15 第 23~26 项" || bad "doctor 未升级到 +ios15"
if [ -f "$NM/@xmanrui/dsh-im/lib/index.js" ] || [ -f "$NM/@tencent-connect/dsh-qqbot/lib/index.js" ]; then bad "包内仍有预装插件"; else ok "包内 0 预装插件（干净底座）"; fi

echo "--- I. 热修脚本一致性 ---"
[ -f "$FIXSH" ] || bad "缺 dist 交付件 $FIXSH"
same "$D/fix-ios15.sh" "$FIXSH" && ok "deb 内 fix-ios15.sh 与 dist 交付件逐字节一致" || bad "deb 内热修与交付件不一致"
if sh -n "$D/fix-ios15.sh" 2>/dev/null; then ok "fix-ios15.sh 通过 sh -n"; else bad "fix-ios15.sh 语法错误"; fi

echo
echo "=== 汇总: OK=$PASS  FAIL=$FAIL ==="
[ "$FAIL" -eq 0 ] || exit 1
exit 0
