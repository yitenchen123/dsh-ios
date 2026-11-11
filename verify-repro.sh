#!/bin/sh
# verify-repro.sh —— 验证「别人 clone 后构建出的 deb 与本地 1:1 一致」
#
# 做法：连续两次完整跑 build.sh，比对两次 deb 的 SHA-256。
# 因为 build.sh 固定了所有 stage 文件 mtime + SOURCE_DATE_EPOCH + gzip -z9，
# 两次构建的产物应当字节级相同。
#
# 用法: sh verify-repro.sh
# 依赖: 同 build.sh（先跑 sh bootstrap.sh 或已具备 bundles/ 大文件）
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
cd "$ROOT"

# 支持两个构建版本；DSH_VER 会传给 bootstrap.sh 与 build.sh。
DSH_VER="${DSH_VER:-0.2.1-rc.5}"
case "$DSH_VER" in
    0.2.1-rc.5) IOS_TAG="+ios15" ;;
    0.2.2-rc.1) IOS_TAG="+ios16" ;;
    *) echo "不支持的 DSH_VER: $DSH_VER" >&2; exit 1 ;;
esac
export DSH_VER
SUF="${DEB_COMP:-gzip}"
case "$SUF" in
    xz) SUFFIX="${IOS_TAG}xz" ;;
    *)  SUFFIX="$IOS_TAG" ;;
esac
OUT="dist/dev.airdevs.dsh_${DSH_VER}${SUFFIX}_iphoneos-arm64.deb"

echo "=== 1) 前置：确保构建大文件齐备（SHA 校验，缺则下载）==="
sh "$ROOT/bootstrap.sh" --check || sh "$ROOT/bootstrap.sh"

echo
echo "=== 2) 第一次完整构建 ==="
DSH_SKIP_BOOTSTRAP=1 sh "$ROOT/build.sh" > /tmp/verify-repro-1.log 2>&1 || {
    echo "第一次构建失败，日志尾：" >&2; tail -30 /tmp/verify-repro-1.log >&2; exit 1; }
SHA1=$(sha256sum "$OUT" | cut -d' ' -f1)
echo "    SHA1 = $SHA1"

echo
echo "=== 3) 第二次完整构建（改动工作区 mtime 后重跑，模拟不同 clone 时间）==="
# 特意把若干源文件 mtime 打乱，证明 build.sh 会统一固定、不受其影响
find "$ROOT/shims" -name '*.cjs' -o -name '*.js' 2>/dev/null | head -5 | while read -r f; do
    touch "$f" 2>/dev/null || true
done
sleep 1
DSH_SKIP_BOOTSTRAP=1 sh "$ROOT/build.sh" > /tmp/verify-repro-2.log 2>&1 || {
    echo "第二次构建失败，日志尾：" >&2; tail -30 /tmp/verify-repro-2.log >&2; exit 1; }
SHA2=$(sha256sum "$OUT" | cut -d' ' -f1)
echo "    SHA2 = $SHA2"

echo
if [ "$SHA1" = "$SHA2" ]; then
    echo "=== 结论：字节级可复现 ✔  两次构建 SHA-256 完全一致 ==="
    echo "    $SHA1  $OUT"
    exit 0
else
    echo "=== 结论：不一致 ✘ ===" >&2
    echo "    SHA1=$SHA1" >&2
    echo "    SHA2=$SHA2" >&2
    echo "    排查：stage 内是否有未固定 mtime 的文件、dpkg-deb 版本差异、" >&2
    echo "          gzip 是否写入了时间戳、control.tar 是否含随机顺序。" >&2
    exit 1
fi
