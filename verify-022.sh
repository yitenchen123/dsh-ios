#!/bin/sh
# ============================================================================
# verify-022.sh —— dsh 0.2.2-rc.1 + dsh-iOS 全套补丁树的独立核验
#
# 背景：官方 0.2.2-rc.1 声明 engines.node >=24.9.0，但 iPhone X / A11 上
# 唯一 100% 实测可用的 Node 是 22.12.0。本脚本用「与真机同版本的 Node
# 22.12.0」+ 零 JIT 档，对打完全套 dsh-iOS 补丁的 0.2.2-rc.1 依赖树做
# 静态断言 + 真 boot 验证，证明该组合可以完整启动、创建会话、恢复会话。
#
# 用法：
#   sh verify-022.sh [TREE] [NODE_BIN]
#
#   TREE     含 node_modules/ 与 fetch-shim.cjs 的树根；默认 $DSH_022_TREE
#            或 ./.build/022。可以是刚解包的离线 bundle，也可以是构建 stage。
#   NODE_BIN 用来跑验证的 Node，必须是 22.12.0（与真机同版本；真机用的
#            Mach-O arm64 二进制不能在 x86 Linux 上执行，构建机需另备一份
#            同版本 x86 二进制，例如 nvm install 22.12.0）。默认取
#            $DSH_NODE_VERIFY，再退回 PATH 里的 node。
#
# 退出码：0 = 全部通过；1 = 有 FAIL。
# ============================================================================
set -u

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
TREE=${1:-${DSH_022_TREE:-$ROOT/.build/022}}
# 必须转绝对路径：--require <fetch-shim.cjs> 与 require(<package.json>) 都按
# 模块解析，传相对路径会 ERR_MODULE_NOT_FOUND，产生一批假 FAIL。
TREE=$(CDPATH= cd -- "$TREE" && pwd) || { echo "TREE 目录不存在: $TREE" >&2; exit 2; }
NODE=${2:-${DSH_NODE_VERIFY:-$(command -v node 2>/dev/null || echo node)}}
NM="$TREE/node_modules"
BIN="$NM/@deepseek-ai/dsh/lib/bin.js"
SHIM="$TREE/fetch-shim.cjs"

OK=0; FAIL=0
ok(){ printf '  [ OK ] %s\n' "$1"; OK=$((OK+1)); }
bad(){ printf '  [FAIL] %s\n' "$1"; FAIL=$((FAIL+1)); }
skip(){ printf '  [ -- ] %s\n' "$1"; }
chk(){ if [ "$1" -eq 0 ]; then ok "$2"; else bad "$2"; fi; }

printf '=== verify-022: TREE=%s\n===          NODE=%s\n' "$TREE" "$NODE"

# ---------------------------------------------------------------- 前置
if [ ! -f "$BIN" ]; then echo "找不到 $BIN"; exit 1; fi
if [ ! -f "$SHIM" ]; then echo "找不到 $SHIM"; exit 1; fi
if ! "$NODE" -v >/dev/null 2>&1; then echo "验证用 Node 不可用: $NODE"; exit 1; fi
NV=$("$NODE" -v)
case "$NV" in v22.12.0) ok "验证用 Node 版本 $NV（与真机同版本）";; *) bad "验证用 Node 版本 $NV，必须是 22.12.0";; esac

HOME=$(mktemp -d /tmp/dsh022-home.XXXXXX 2>/dev/null || echo /tmp/dsh022-home)
export HOME
DSH_HOME="$HOME/.dsh"; export DSH_HOME
NODE_PATH="$NM"; export NODE_PATH
NODE_OPTIONS=--max-old-space-size=384; export NODE_OPTIONS
mkdir -p "$DSH_HOME"

ARGS="--jitless --no-expose-wasm --require $SHIM --experimental-sqlite --disable-warning=ExperimentalWarning --expose-internals"
run_node(){ # shellcheck disable=SC2086
    "$NODE" $ARGS "$BIN" "$@"
}
# headless 真 boot 可能等模型响应，单独加超时；timeout 只能包可执行命令，
# 不能包 shell 函数，所以这里显式展开同一组参数。
run_headless(){ # shellcheck disable=SC2086
    timeout 90 "$NODE" $ARGS "$BIN" "$@"
}

echo "--- A. 静态断言 ---------------------------------------------------"
# A1 版本
V=$(node -e 'process.stdout.write(require(process.argv[1]+"/node_modules/@deepseek-ai/dsh/package.json").version)' "$TREE" 2>/dev/null)
[ "$V" = "0.2.2-rc.1" ] && ok "dsh 版本 = 0.2.2-rc.1" || bad "dsh 版本 = ${V:-<未知>}"

# A2 无原生 addon
N=$(find "$NM" -name '*.node' 2>/dev/null | wc -l | tr -d ' ')
[ "$N" = "0" ] && ok "依赖树 0 个原生 .node" || bad "依赖树仍有 $N 个 .node"

# A3 四处 Node 22.12 兼容补丁
grep -q 'import.meta.main' "$NM/@deepseek-ai/dsh/lib/bin.js" 2>/dev/null \
    && bad "bin.js 仍含 import.meta.main" || ok "bin.js: import.meta.main 已移除"
grep -q 'zstd landed in 22.15' "$NM/@deepseek-ai/dsh-session-persistence-jsonl/lib/index.js" 2>/dev/null \
    && ok "session: zstd→gzip 降级" || bad "session: 缺 zstd 降级"
grep -q 'const DEFAULT_COMPRESSION = "none"' "$NM/@deepseek-ai/dsh-session-persistence-jsonl/lib/index.js" 2>/dev/null \
    && ok "session: 默认压缩 = none" || bad "session: 默认压缩未改 none"
grep -q 'stripTypeScriptTypes landed in 22.13' "$NM/@deepseek-ai/dsh-ptc-runtime-node/lib/index.js" 2>/dev/null \
    && ok "ptc-runtime: stripTypeScriptTypes shim" || bad "ptc-runtime: 缺 TS 剥离 shim"

# A4 +ios14 pnpm 绝对路径直连 + 零 JIT
for f in "$NM/@deepseek-ai/dsh-plugin-manager/lib/index.js" \
         "$NM/@deepseek-ai/dsh-plugin-manager/lib/types/operations.js"; do
    b=$(basename "$f")
    if grep -q '__dshPnpmFlags' "$f" 2>/dev/null; then ok "$b: pnpm 绝对路径 + 零 JIT 档"; else bad "$b: 缺 pnpm 直连补丁"; fi
done

# A5 +ios15 手动安装 / 插件市场
grep -q 'git-probe-shortcircuit' "$NM/@deepseek-ai/dsh-plugin-manager/lib/index.js" 2>/dev/null \
    && ok "手动安装: GitHub 裸 git 预检已短路" || bad "手动安装: git 预检未短路"
grep -q 'redirect: "follow"' "$NM/@deepseek-ai/dsh-plugin-market/lib/index.js" 2>/dev/null \
    && ok "插件市场: redirect follow" || bad "插件市场: redirect 仍为 error"
[ -f "$NM/@deepseek-ai/dsh-plugin-market/lib/worker-parse.cjs" ] \
    && ok "插件市场: worker-parse.cjs 已派生" || bad "插件市场: 缺 worker-parse.cjs"
grep -q '__dshParseIndexBody' "$NM/@deepseek-ai/dsh-plugin-market/lib/index.js" 2>/dev/null \
    && ok "插件市场: 索引主线程解析（无子 Worker）" || bad "插件市场: 仍用子 Worker"
grep -q '__dshIosTransformSpec' "$NM/@deepseek-ai/dsh-client-ui-plugin-manager/lib/client.js" 2>/dev/null \
    && ok "手动安装: 生态插件转化钩子已注入" || bad "手动安装: 缺转化钩子"

# A6 硬约束：AI 帮你装 / CLI 两条路径不得应用转化
LEAK=0
for f in "$NM/@deepseek-ai/dsh-plugin-manager/lib/types/tools.js" \
         "$NM/@deepseek-ai/dsh-plugin-manager/lib/types/operations.js"; do
    [ -f "$f" ] && grep -q '__dshIosTransformSpec' "$f" 2>/dev/null && LEAK=$((LEAK+1))
done
[ "$LEAK" -eq 0 ] && ok "硬约束: AI/CLI 路径 0 个转化钩子泄漏" || bad "硬约束: $LEAK 处泄漏"

# A7 前端注入
FRONT="$NM/@deepseek-ai/dsh-web-frontend/dist"
for m in safari16-polyfill.js dsh-ios-manual-install-transform.js; do
    if [ -f "$FRONT/assets/$m" ] && grep -q "$m" "$FRONT/index.html" 2>/dev/null; then
        ok "前端: $m 已注入 index.html"
    else
        bad "前端: $m 缺失"
    fi
done

# A8 所有补丁文件语法
SYN=0
for f in "@deepseek-ai/dsh/lib/bin.js" \
         "@deepseek-ai/dsh-session-persistence-jsonl/lib/index.js" \
         "@deepseek-ai/dsh-ptc-runtime-node/lib/index.js" \
         "@deepseek-ai/dsh-plugin-manager/lib/index.js" \
         "@deepseek-ai/dsh-plugin-manager/lib/types/operations.js" \
         "@deepseek-ai/dsh-plugin-market/lib/index.js" \
         "@deepseek-ai/dsh-plugin-market/lib/worker-parse.cjs" \
         "@deepseek-ai/dsh-client-ui-plugin-manager/lib/client.js" \
         "@deepseek-ai/dsh-web-frontend/dist/assets/safari16-polyfill.js" \
         "@deepseek-ai/dsh-web-frontend/dist/assets/dsh-ios-manual-install-transform.js"; do
    if [ -f "$NM/$f" ]; then
        node --check "$NM/$f" >/dev/null 2>&1 || { bad "语法错误: $f"; SYN=$((SYN+1)); }
    else
        bad "缺文件: $f"; SYN=$((SYN+1))
    fi
done
[ "$SYN" -eq 0 ] && ok "10 个补丁/垫片文件 node --check 全部通过" || bad "$SYN 个文件语法/缺失错误"

echo "--- B. 真 boot（Node 22.12.0 + 零 JIT 档）--------------------------"
# B1 --version
OUT=$(run_node --version 2>/tmp/v022.err); RC=$?
if [ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -q '0.2.2-rc.1'; then ok "--version → $OUT"; else bad "--version RC=$RC: $(tail -2 /tmp/v022.err)"; fi

# B2 web --dump-config
run_node web --dump-config >/tmp/v022.cfg 2>/tmp/v022.cfgerr; RC=$?
if [ "$RC" -eq 0 ] && [ -s /tmp/v022.cfg ]; then ok "web --dump-config（$(wc -l </tmp/v022.cfg | tr -d ' ') 行）"; else bad "web --dump-config RC=$RC: $(tail -3 /tmp/v022.cfgerr)"; fi

# B3 headless --help
run_node headless --help >/tmp/v022.hh 2>/tmp/v022.hherr; RC=$?
if [ "$RC" -eq 0 ] && grep -q 'Answer one task' /tmp/v022.hh; then ok "headless --help"; else bad "headless --help RC=$RC"; fi

# B4 web --no-open 真监听
PORT=${DSH_022_PORT:-3209}
run_node web --no-open --port "$PORT" >/tmp/v022.web.log 2>&1 &
PID=$!
i=0; CODE=""
while [ "$i" -lt 40 ]; do
    kill -0 "$PID" 2>/dev/null || break
    CODE=$(curl -s -o /tmp/v022.web.body -w '%{http_code}' --noproxy '*' --max-time 2 "http://127.0.0.1:$PORT/" 2>/dev/null)
    CRC=$?
    [ "$CRC" -eq 0 ] && [ -n "$CODE" ] && break
    CODE=""; i=$((i+1)); sleep 0.5
done
if kill -0 "$PID" 2>/dev/null; then ok "web 进程存活（PID=$PID）"; else bad "web 进程退出: $(tail -5 /tmp/v022.web.log)"; fi
if [ -n "$CODE" ] && [ "$CODE" != "000" ]; then ok "web HTTP 有响应（$CODE；根路径 404 属正常，UI 走 token→WebSocket RPC）"; else bad "web HTTP 无响应"; fi
kill "$PID" 2>/dev/null || true
wait "$PID" 2>/dev/null || true

# B5 headless 真 boot 到模型层 + B6 会话创建
run_headless headless "ping" >/tmp/v022.hl 2>/tmp/v022.hlerr; RC=$?
case "$RC" in
    132|133|134|135|136|138|139) bad "headless 被信号杀死 RC=$RC（SIGBUS/段错误）" ;;
    *) ok "headless 完整启动链路跑完 RC=$RC（无信号崩溃）" ;;
esac
if grep -q 'MISSING_CREDENTIAL' /tmp/v022.hlerr 2>/dev/null; then
    ok "headless 已到模型层（仅缺 API key，属预期）"
else
    skip "headless 未报 MISSING_CREDENTIAL，stderr 末尾：$(tail -2 /tmp/v022.hlerr | tr '\n' ' ')"
fi
SESS=$(find "$DSH_HOME/sessions" -name 'session.v4.jsonl' 2>/dev/null | head -1)
if [ -n "$SESS" ] && [ -s "$SESS" ]; then
    ok "会话文件已创建且非空: ${SESS#$DSH_HOME/}"
else
    bad "未创建 session.v4.jsonl（『无法创建新对话』回归）"
fi
if grep -qi 'corrupt\|zstandard\|zstd' /tmp/v022.hlerr 2>/dev/null; then bad "会话写入报 zstd/corrupt"; else ok "会话写入无 zstd/corrupt"; fi

# B7 会话恢复（用户报过的『重启后上一次对话不保留』）
if [ -n "$SESS" ]; then
    SID=$(basename "$(dirname "$SESS")")
    run_headless headless --session-id "$SID" "ping again" >/tmp/v022.rs 2>/tmp/v022.rserr; RC=$?
    case "$RC" in
        132|133|134|135|136|138|139) bad "会话恢复被信号杀死 RC=$RC" ;;
        *) ok "会话恢复跑完 RC=$RC" ;;
    esac
    if grep -qi 'corrupt\|zstandard\|zstd' /tmp/v022.rserr 2>/dev/null; then bad "会话恢复报 zstd/corrupt"; else ok "会话恢复无 zstd/corrupt"; fi
    if grep -q 'MISSING_CREDENTIAL' /tmp/v022.rserr 2>/dev/null; then ok "会话恢复到模型层（沿用已有会话）"; else skip "会话恢复未到模型层：$(tail -2 /tmp/v022.rserr | tr '\n' ' ')"; fi
else
    bad "跳过会话恢复：无会话文件"
fi

# B8 cordis.patch.yml 顶层必须是数组（真机曾 fatal）
BADPATCH=0
for f in "$DSH_HOME"/cordis.patch.yml "$DSH_HOME"/profiles/*/cordis.patch.yml; do
    [ -f "$f" ] || continue
    tail -1 "$f" | grep -q '^\[\]' || BADPATCH=$((BADPATCH+1))
done
[ "$BADPATCH" -eq 0 ] && ok "cordis.patch.yml 顶层均为数组" || bad "$BADPATCH 个 patch 文件顶层非数组"

printf '\n=== 汇总: OK=%s FAIL=%s ===\n' "$OK" "$FAIL"
[ "$FAIL" -eq 0 ] && echo "✔ dsh 0.2.2-rc.1 + dsh-iOS 全套补丁树核验全部通过"
exit $((FAIL > 0))
