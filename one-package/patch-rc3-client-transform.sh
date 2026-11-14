#!/bin/sh
# 把已带 __dshIosTransformSpec 的 dsh-client-ui-plugin-manager/lib/client.js
# 放进 rc.3 的 pnpm 隔离树（rc.3 上游 client.js 的对话框锚点与 +ios15 补丁不一致，
# 直接跑 apply_plugin_install_patch.cjs 会报 0/1 命中；这里用已验证的成品替换）。
# 用法: sh patch-rc3-client-transform.sh <patched-client.js> <rc3-node_modules>
set -eu
SRC="${1:?patched client.js}"
NM="${2:?rc3 node_modules}"
DST=$(realpath "$NM/@deepseek-ai/dsh-client-ui-plugin-manager/lib/client.js")
cp "$SRC" "$DST"
grep -q "__dshIosTransformSpec" "$DST"
echo "patched: $DST"
