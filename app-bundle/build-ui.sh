#!/bin/sh
# build-ui.sh — compile the native DSH.app executable (SFSafariViewController shell).
#
# No Apple developer certificate / Xcode project is needed: a plain clang
# invocation against the iPhoneOS SDK produces the arm64 Mach-O.  The plist is
# embedded with -sectcreate __TEXT __info_plist (some system services read it).
#
# Usage:
#   sh build-ui.sh [output]
# Without an iOS SDK the committed prebuilt binary is used.
set -e
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO=$(CDPATH= cd -- "$HERE/.." && pwd)
OUT=${1:-"$HERE/prebuilt/DSHLauncher"}
PLIST="$HERE/payload/var/jb/Applications/DSH.app/Info.plist"

SDK="${IOS_SDK:-}"
if [ -z "$SDK" ] && command -v xcrun >/dev/null 2>&1; then
    SDK=$(xcrun --sdk iphoneos --show-sdk-path 2>/dev/null || true)
fi
if [ -z "$SDK" ] && [ -d /var/jb/usr/share/SDKs/iPhoneOS.sdk ]; then
    SDK=/var/jb/usr/share/SDKs/iPhoneOS.sdk
fi
if [ -z "$SDK" ] && [ -d /Applications/Xcode.app/Contents/Developer/Platforms/iPhoneOS.platform/Developer/SDKs ]; then
    SDK=$(ls -d /Applications/Xcode.app/Contents/Developer/Platforms/iPhoneOS.platform/Developer/SDKs/iPhoneOS*.sdk 2>/dev/null | tail -1)
fi

if [ -z "$SDK" ] || [ ! -d "$SDK" ]; then
    echo "==> no iOS SDK found; using the committed prebuilt executable"
    [ -f "$HERE/prebuilt/DSHLauncher" ] || {
        echo "missing $HERE/prebuilt/DSHLauncher" >&2; exit 1; }
    [ "$OUT" = "$HERE/prebuilt/DSHLauncher" ] || cp "$HERE/prebuilt/DSHLauncher" "$OUT"
    sha256sum "$OUT" | sed 's/^/    /'
    exit 0
fi

CC="${CC:-}"
if [ -z "$CC" ]; then
    for c in clang clang-14 clang-15 clang-16; do
        if command -v "$c" >/dev/null 2>&1; then CC="$c"; break; fi
    done
fi
command -v "$CC" >/dev/null 2>&1 || { echo "缺少 clang" >&2; exit 1; }

echo "==> SDK: $SDK"
mkdir -p "$(dirname "$OUT")"
"$CC" -arch arm64 -isysroot "$SDK" -miphoneos-version-min=15.0 -fobjc-arc -O2 \
      -I"$HERE/app-src" \
      "$HERE/app-src/main.m" "$HERE/app-src/DSHAppDelegate.m" \
      -o "$OUT" \
      -framework UIKit -framework Foundation -framework SafariServices -framework QuartzCore \
      -Wl,-no_uuid \
      -Wl,-sectcreate,__TEXT,__info_plist,"$PLIST"
if command -v ldid >/dev/null 2>&1; then
    ldid -S "$OUT" || true
fi
ls -la "$OUT" | sed 's/^/    /'
sha256sum "$OUT" | sed 's/^/    /'
echo "==> done: $OUT"
