#!/bin/sh
# dsh-ios +ios15 — 把 plugins/dsh-ios-phone-control 打成可传给手机的 tgz
#
# 产物：dist/dsh-ios-phone-control-0.1.0.tgz
# 确定性：成员排序、固定 mtime/属主、gzip -n -9，两次生成字节一致。
# 传到手机后：DSH「插件 → 添加插件」填 tgz 绝对路径即可（+ios15 手动安装已修好）。

set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
SRC="$ROOT/plugins/dsh-ios-phone-control"
NAME=dsh-ios-phone-control
OUT="$ROOT/dist/${NAME}-0.1.0.tgz"
SDE="${SOURCE_DATE_EPOCH:-1700000000}"

[ -d "$SRC" ] || { echo "缺少 $SRC" >&2; exit 1; }
mkdir -p "$ROOT/dist"

# 打包前强校验：bundle 必须自洽，否则不产包
for f in package.json cordis.patch.yml locale/en.json locale/zh.json icon.svg README.md; do
  [ -f "$SRC/$f" ] || { echo "bundle 缺文件: $f" >&2; exit 1; }
done
grep -q "'@deepseek-ai/dsh-mcp-client'" "$SRC/cordis.patch.yml" || {
  echo "cordis.patch.yml 未引用 dsh-mcp-client" >&2; exit 1; }
grep -q 'transport: streamable-http' "$SRC/cordis.patch.yml" || {
  echo "cordis.patch.yml 未使用 streamable-http" >&2; exit 1; }

TMP="$OUT.tmp"
tar --sort=name \
    --mtime="@$SDE" \
    --owner=0 --group=0 --numeric-owner \
    -cf - -C "$ROOT/plugins" "$NAME" | gzip -n -9 > "$TMP"
mv "$TMP" "$OUT"

echo "已生成: $OUT"
echo "大小  : $(wc -c < "$OUT") 字节"
echo "SHA256: $(sha256sum "$OUT" | cut -d' ' -f1)"
echo "成员  :"
tar tzf "$OUT" | sed 's/^/  /'
