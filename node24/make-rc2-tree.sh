#!/bin/sh
# ---------------------------------------------------------------------------
# make-rc2-tree.sh —— 生成 dsh 0.2.2-rc.2 的纯 JS 依赖树（供实验 deb 用）
#
# 与稳定包 build.sh 的差异（Node 24 已原生具备这些 API）：
#   * 不调用 shims/apply_compat_patches.py（补 Node 22.12 缺的
#     import.meta.main / zstd / stripTypeScriptTypes —— Node 24 全都有，
#     且 rc.2 的 bin.js 结构已变，锚点会失配甚至误伤）。
#   * 仅保留一条会话自洽补丁：DEFAULT_COMPRESSION → none（见
#     apply_session_none.py），避免 zstd 帧头与读路径不一致。
#   * +ios15 那套「pnpm 直连 / 手动安装 / 插件市场 / 前端注入」补丁
#     与 Node 版本无关（修的是 iOS 无 pnpm/git、Worker SIGBUS、Web UI
#     spec 转化），但必须先做锚点自检；命中才应用，任一失配即停。
#
# 输出: node24/.build/node_modules/  与  bundles/dsh-nodemodules-0.2.2-rc.2+ios1.tar.gz
#
# 用法: sh node24/make-rc2-tree.sh            # 联网 npm install
#       sh node24/make-rc2-tree.sh --check    # 只做补丁锚点自检，不联网
# ---------------------------------------------------------------------------
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
N="$ROOT/node24"
DSH_VER="${DSH_VER:-0.2.2-rc.2}"
WORK="$N/.build"
NM="$WORK/node_modules"
BUNDLE="$ROOT/bundles/dsh-nodemodules-${DSH_VER}+ios1.tar.gz"

echo "=== 生成 dsh $DSH_VER 依赖树（Node 24 实验包）==="

if [ "${1:-}" = "--check" ]; then
    echo "    [自检模式] 只验证补丁锚点，不联网、不生成树"
    [ -d "$NM" ] || { echo "缺 ${NM}，请先跑一次不带 --check 的生成" >&2; exit 1; }
else
    rm -rf "$WORK"; mkdir -p "$WORK"
    cd "$WORK"
    printf '{"name":"dsh-ios-node24-bundle","private":true,"version":"1.0.0"}\n' > package.json
    echo "==> npm install @deepseek-ai/dsh@${DSH_VER} --omit=optional"
    npm install --omit=optional --no-audit --no-fund --loglevel=error "@deepseek-ai/dsh@${DSH_VER}"

    echo "==> 应用纯 JS shim（替代原生 addon）"
    cp "$ROOT/shims/node-addon-require-builtin__lib__index.js" \
       "$NM/node-addon-require-builtin/lib/index.js"
    cp "$ROOT/shims/node-addon-system__lib__flock.js" \
       "$NM/@deepseek-ai/node-addon-system/lib/flock.js"

    echo "==> 裁剪依赖树（去掉原生模块 / 平台二进制 / 文档）"
    find "$NM" -type f \( -name '*.node' -o -name '*.d.ts' -o -name '*.map' -o -name '*.d.cts' -o -name '*.d.mts' \) -delete 2>/dev/null || true
    find "$NM" -type d \( -name test -o -name tests -o -name __tests__ -o -name docs -o -name .github -o -name prebuilds \) -prune -exec rm -rf {} + 2>/dev/null || true
    find "$NM" -type f \( -iname 'readme*' -o -iname 'changelog*' -o -iname '*.md' \) -delete 2>/dev/null || true
    rm -rf "$NM"/@deepseek-ai/node-addon-system-*-* "$NM"/@img "$NM"/@koromix "$NM"/sherpa-onnx-* "$NM"/node-pty 2>/dev/null || true
fi

# --- 版本核对 ---
GOT=$(sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' \
      "$NM/@deepseek-ai/dsh/package.json" | head -1)
[ "$GOT" = "$DSH_VER" ] || { echo "版本不符: $GOT != $DSH_VER" >&2; exit 1; }
echo "    dsh 版本 OK: $GOT"
NADDON=$(find "$NM" -name '*.node' | wc -l)
[ "$NADDON" -eq 0 ] || { echo "仍有 $NADDON 个 .node，中止" >&2; exit 1; }
echo "    .node 原生模块: 0"

# --- 补丁锚点自检（fail-fast，逐条打印）---
echo "==> Node 24 补丁锚点自检"
MISS=0
check() {  # file | literal | note
    _f="$NM/$1"; _lit="$2"; _note="$3"
    if [ -f "$_f" ] && grep -Fq -- "$_lit" "$_f" 2>/dev/null; then
        printf '  [HIT ] %-58s | %s\n' "$1" "$_note"
    else
        printf '  [MISS] %-58s | %s\n' "$1" "$_note" >&2
        MISS=$((MISS+1))
    fi
}
# Node 24 自带这些 API —— 确认 rc.2 用的是标准写法，无需 compat 补丁
check '@deepseek-ai/dsh/lib/bin.js' 'import.meta.main' 'rc.2 用 import.meta.main（Node24 原生支持，不打补丁）'
# 会话压缩（唯一仍要改的一条）
SESSION="$NM/@deepseek-ai/dsh-session-persistence-jsonl/lib/index.js"
if grep -Fq 'DEFAULT_COMPRESSION' "$SESSION" 2>/dev/null; then
    printf '  [HIT ] %-58s | 会话 DEFAULT_COMPRESSION 存在\n' '@deepseek-ai/dsh-session-persistence-jsonl/lib/index.js'
else
    printf '  [MISS] %-58s | 会话 DEFAULT_COMPRESSION 锚点\n' '@deepseek-ai/dsh-session-persistence-jsonl/lib/index.js' >&2
    MISS=$((MISS+1))
fi
# +ios15 补丁目标文件是否都在
for f in '@deepseek-ai/dsh-plugin-manager/lib/index.js' \
         '@deepseek-ai/dsh-plugin-manager/lib/types/operations.js' \
         '@deepseek-ai/dsh-plugin-market/lib/index.js' \
         '@deepseek-ai/dsh-client-ui-plugin-manager/lib/client.js'; do
    if [ -f "$NM/$f" ]; then printf '  [HIT ] %-58s | 补丁目标文件存在\n' "$f"
    else printf '  [MISS] %-58s | 补丁目标文件缺失\n' "$f" >&2; MISS=$((MISS+1)); fi
done

if [ "$MISS" -gt 0 ]; then
    echo "=== 锚点自检有 $MISS 项失配 —— 不生成 bundle，需人工核对 rc.2 结构 ===" >&2
    exit 1
fi
echo "    锚点自检全绿"

if [ "${1:-}" = "--check" ]; then exit 0; fi

# --- 打包成可复现 bundle（与 rc.1 命名一致，便于 bootstrap 复用）---
echo "==> 生成 bundle: $BUNDLE"
cd "$WORK"
# 固定排序与 mtime，保证 bundle 字节可复现
find node_modules -depth -exec touch -h -d "@1700000000" {} + 2>/dev/null || true
COPYFILE_DISABLE=1 tar --sort=name --mtime='@1700000000' --owner=0 --group=0 \
    --numeric-owner -czf "$BUNDLE" node_modules
echo "    $(du -sh "$BUNDLE" | cut -f1)  SHA $(sha256sum "$BUNDLE" | cut -c1-16)…"

# --- x86 语法自检（能跑的部分）---
echo "==> 全树 JS 语法检查（x86 node，仅语法层）"
BAD=0; CNT=0
for f in $(find "$NM" -name '*.js' -o -name '*.cjs' -o -name '*.mjs' | head -2000); do
    CNT=$((CNT+1))
    node --check "$f" 2>/dev/null || { echo "  语法错误: $f" >&2; BAD=$((BAD+1)); }
done
echo "    检查 $CNT 个文件，语法错误 $BAD 个"
[ "$BAD" -eq 0 ] || exit 1
echo "=== 完成 ==="
