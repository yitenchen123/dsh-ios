#!/bin/sh
# build-app.sh — build the single DeepSeek Harness APP package
# (dev.airdevs.dsh-app: native app + keep-alive daemon; the Harness runtime
#  itself is the existing dev.airdevs.dsh engine package it depends on).
#
# No separate phone-control plugin is shipped here: the app only contains the
# SpringBoard app, its icons, the setuid daemon helper and the launchd daemon
# that starts `dsh web` for the app (no terminal needed).
set -e
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO=$(CDPATH= cd -- "$ROOT/.." && pwd)
STAGE="$ROOT/.stage"
VER="0.2.1-rc.5+ios18"
OUT="$ROOT/dist/dev.airdevs.dsh-app_${VER}_iphoneos-arm64.deb"
SDE="${SOURCE_DATE_EPOCH:-1700000000}"

for c in python3 dpkg-deb sha256sum; do
    command -v "$c" >/dev/null 2>&1 || { echo "缺少 $c" >&2; exit 1; }
done

echo "==> build app executable"
sh "$ROOT/build-ui.sh"

echo "==> build setuid daemon helper"
sh "$ROOT/build-helper.sh"

echo "==> 清理 stage"
rm -rf "$STAGE"; mkdir -p "$STAGE"
mkdir -p "$ROOT/dist"

echo "==> 复制 payload"
cp -a "$ROOT/payload/." "$STAGE/"

echo "==> app executable + icons"
cp "$ROOT/prebuilt/DSHLauncher" "$STAGE/var/jb/Applications/DSH.app/DSHLauncher"
cp "$ROOT/prebuilt/dsh-app-helper" "$STAGE/var/jb/usr/bin/dsh-app-helper"
python3 "$ROOT/make_app_icon.py" "$STAGE/var/jb/Applications/DSH.app" | sed 's/^/    /'

for f in dsh-app-ctl dsh-daemon dsh-app-ui; do
    sh -n "$STAGE/var/jb/usr/bin/$f" || { echo "$f 语法错误" >&2; exit 1; }
done

echo "==> 复制 DEBIAN"
cp -a "$ROOT/DEBIAN" "$STAGE/DEBIAN"
chmod 755 "$STAGE/DEBIAN/postinst" "$STAGE/DEBIAN/prerm"
chmod 755 "$STAGE/var/jb/Applications/DSH.app/DSHLauncher" \
          "$STAGE/var/jb/usr/bin/dsh-app-ui" \
          "$STAGE/var/jb/usr/bin/dsh-app-ctl" \
          "$STAGE/var/jb/usr/bin/dsh-daemon"
chmod 4755 "$STAGE/var/jb/usr/bin/dsh-app-helper"
chmod 644 "$STAGE/var/jb/Applications/DSH.app/Info.plist" \
          "$STAGE/var/jb/Applications/DSH.app/entitlements.plist" \
          "$STAGE/var/jb/Applications/DSH.app/"*.png \
          "$STAGE/var/jb/Library/LaunchDaemons/dev.airdevs.dsh.plist"

echo "==> 固定 mtime / 属主（SOURCE_DATE_EPOCH=$SDE）"
chown -R 0:0 "$STAGE" 2>/dev/null || true
find "$STAGE" -depth -exec touch -h -d "@$SDE" {} + 2>/dev/null || \
    find "$STAGE" -depth -exec touch -h -t 202311142013.20 {} + 2>/dev/null || true

echo "==> dpkg-deb 组装"
rm -f "$OUT"
SOURCE_DATE_EPOCH="$SDE" dpkg-deb -b -Zgzip -z9 "$STAGE" "$OUT" >/dev/null
echo "==> 产物"
SIZE=$(stat -c%s "$OUT" 2>/dev/null || stat -f%z "$OUT" 2>/dev/null || echo "?")
echo "    $SIZE bytes  $OUT"
sha256sum "$OUT" | sed 's/^/    /'
