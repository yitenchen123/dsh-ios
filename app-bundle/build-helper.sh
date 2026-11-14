#!/bin/sh
# build-helper.sh — compile the setuid-root dsh-app-helper (fixed command only).
set -e
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
OUT=${1:-"$HERE/prebuilt/dsh-app-helper"}
SDK="${IOS_SDK:-}"
if [ -z "$SDK" ] && command -v xcrun >/dev/null 2>&1; then
    SDK=$(xcrun --sdk iphoneos --show-sdk-path 2>/dev/null || true)
fi
if [ -z "$SDK" ] && [ -d /var/jb/usr/share/SDKs/iPhoneOS.sdk ]; then
    SDK=/var/jb/usr/share/SDKs/iPhoneOS.sdk
fi
if [ -z "$SDK" ] || [ ! -d "$SDK" ]; then
    echo "==> no iOS SDK; using prebuilt helper"
    [ -f "$HERE/prebuilt/dsh-app-helper" ] || { echo "missing prebuilt helper" >&2; exit 1; }
    [ "$OUT" = "$HERE/prebuilt/dsh-app-helper" ] || cp "$HERE/prebuilt/dsh-app-helper" "$OUT"
    exit 0
fi
CC="${CC:-}"; if [ -z "$CC" ]; then for c in clang clang-14 clang-15 clang-16; do command -v "$c" >/dev/null 2>&1 && { CC=$c; break; }; done; fi
mkdir -p "$(dirname "$OUT")"
"$CC" -arch arm64 -isysroot "$SDK" -miphoneos-version-min=15.0 -O2 -Wl,-no_uuid \
      "$HERE/helper-src/dsh-app-helper.c" -o "$OUT"
command -v ldid >/dev/null 2>&1 && ldid -S"$HERE/helper-src/helper-ent.plist" "$OUT" || true
ls -la "$OUT" | sed 's/^/    /'
