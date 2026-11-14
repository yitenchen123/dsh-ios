#!/bin/sh
# 单包构建：引擎树 + 桌面 APP + 手机操控 + 全屏 WebClip -> 一个 deb
# 用法: sh build-one-package.sh <引擎树目录(含 bin/node)> <APP payload 目录> <输出.deb>
set -eu
ENGINE="${1:?engine tree}"
APPDIR="${2:?app payload}"
OUT="${3:-dsh-one-rc3.deb}"
HERE=$(cd "$(dirname "$0")" && pwd)
STAGE=$(mktemp -d /tmp/dsh-one.XXXXXX)
trap 'rm -rf "$STAGE"' EXIT INT TERM
mkdir -p "$STAGE/var/jb/usr/lib"
cp -a "$ENGINE" "$STAGE/var/jb/usr/lib/dsh"
cp -a "$APPDIR/." "$STAGE/"
mkdir -p "$STAGE/DEBIAN" "$STAGE/var/jb/usr/lib/dsh/webclip"
cp -a "$HERE/DEBIAN/." "$STAGE/DEBIAN/"
cp -a "$HERE/webclip/." "$STAGE/var/jb/usr/lib/dsh/webclip/"
chmod 755 "$STAGE/DEBIAN/postinst" "$STAGE/DEBIAN/prerm" 2>/dev/null || true
dpkg-deb -b -Zgzip -z1 "$STAGE" "$OUT"
echo "built: $OUT"
