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
echo "=== 4) 第三次构建（故意打乱源树文件 mode，模拟不同 clone/解包/umask）==="
# `git archive | tar -x`（root）会把 100644/100755 解成 664/775，某些 umask
# 也会让检出带组写位。build.sh 打包前会把 mode 归一化，所以即使源树被
# 扰动，产物仍必须与前两次字节一致。这是「别人 clone 后 1:1 重建」的核心防线。
# 用 git 记录的两档 mode 做扰动；结束时用 git checkout 精确还原（trap 兜底）。
restore_mode() {
    git -C "$ROOT" checkout -- bundles/pnpm 2>/dev/null || true
}
trap restore_mode EXIT HUP INT TERM
# 只加 group-write 位、保留 owner-x 语义：100644→664、100755→775。
# 这才是 git archive / 非标准 umask 的真实偏差；若把可执行文件也抹成
# 664 会丢失 x 位信息（git 本身不会这样），归一化无法凭空还原，不属本测试范围。
find "$ROOT/bundles/pnpm" -type f '!' -perm /100 -exec chmod 664 {} +
find "$ROOT/bundles/pnpm" -type f -perm /100 -exec chmod 775 {} +
find "$ROOT/bundles/pnpm" -type d -exec chmod 775 {} +
echo "    已把 bundles/pnpm 扰动为 664/775（git 记录为 644/755，x 位保留）"
DSH_SKIP_BOOTSTRAP=1 sh "$ROOT/build.sh" > /tmp/verify-repro-3.log 2>&1 || {
    echo "第三次构建失败，日志尾：" >&2; tail -30 /tmp/verify-repro-3.log >&2; exit 1; }
SHA3=$(sha256sum "$OUT" | cut -d' ' -f1)
echo "    SHA3 = $SHA3"
restore_mode
trap - EXIT HUP INT TERM
echo "    已用 git checkout 还原 bundles/pnpm 的 mode"

echo
if [ "$SHA1" = "$SHA2" ] && [ "$SHA1" = "$SHA3" ]; then
    echo "=== 结论：字节级可复现 ✔  三次构建（含 mode 扰动）SHA-256 完全一致 ==="
    echo "    $SHA1  $OUT"
    exit 0
else
    echo "=== 结论：不一致 ✘ ===" >&2
    echo "    SHA1(基准)=$SHA1" >&2
    echo "    SHA2(扰动 mtime)=$SHA2" >&2
    echo "    SHA3(扰动 mode)=$SHA3" >&2
    echo "    排查：stage 内是否有未固定 mtime/mode 的文件、dpkg-deb 版本差异、" >&2
    echo "          gzip 是否写入了时间戳、control.tar 是否含随机顺序。" >&2
    exit 1
fi
