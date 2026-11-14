#!/bin/sh
# 把已带 __dshIosTransformSpec 的 dsh-client-ui-plugin-manager/lib/client.js
# 放进 rc.3 的 pnpm 隔离树（rc.3 上游 client.js 的对话框锚点与 +ios15 补丁
# 不一致，直接跑 apply_plugin_install_patch.cjs 会报 0/1 命中；这里用已验证
# 的成品替换）。
# 用法: sh patch-rc3-client-transform.sh <patched-client.js> <rc3-node_modules>
set -eu
SRC="${1:?patched client.js}"
NM="${2:?rc3 node_modules}"
[ -f "$SRC" ] || { echo "找不到 patched client.js: $SRC" >&2; exit 1; }
DSTP="$NM/@deepseek-ai/dsh-client-ui-plugin-manager/lib/client.js"
[ -f "$DSTP" ] || { echo "rc.3 树里找不到 $DSTP" >&2; exit 1; }
DST=$(realpath "$DSTP")
SRCR=$(realpath "$SRC" 2>/dev/null || printf '%s' "$SRC")
if [ "$SRCR" = "$DST" ]; then
    echo "源与目标为同一文件，跳过复制: $DST"
else
    cp "$SRC" "$DST"
fi
grep -q "__dshIosTransformSpec" "$DST" || {
    echo "替换后仍缺 __dshIosTransformSpec，前端转化钩子未生效: $DST" >&2; exit 1; }
echo "patched: $DST"
