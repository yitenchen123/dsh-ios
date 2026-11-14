#!/bin/sh
# build-native.sh — build the SpringBoard-resident phone-control provider.
#
# Source: witchan/ios-mcp 1.2.8 (MIT, see LICENSE-ios-mcp / NOTICE), vendored
# under core/ with two changes:
#   1. core/roothide.h is a rootless stub (upstream includes <roothide.h> even
#      in the rootless build);
#   2. core/entry.m starts the MCP server from a plain constructor instead of
#      the Logos %hook/%ctor in Tweak.x.
#
# Why a SpringBoard dylib: real HID touch injection, screenshot capture and the
# private accessibility tree are only available inside SpringBoard.  A pure
# Node / app process cannot do them.  The dylib is loaded by ElleKit from
# /var/jb/Library/MobileSubstrate/DynamicLibraries.
#
# Usage:
#   sh build-native.sh [output.dylib]
# Without a usable iOS SDK it verifies/copies prebuilt/dsh-ios-control.dylib.
set -e
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
OUT=${1:-"$HERE/prebuilt/dsh-ios-control.dylib"}
CORE="$HERE/core"

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
    echo "==> no iOS SDK found; using the committed prebuilt dylib"
    [ -f "$HERE/prebuilt/dsh-ios-control.dylib" ] || {
        echo "missing $HERE/prebuilt/dsh-ios-control.dylib" >&2; exit 1; }
    if [ "$OUT" != "$HERE/prebuilt/dsh-ios-control.dylib" ]; then
        cp "$HERE/prebuilt/dsh-ios-control.dylib" "$OUT"
    fi
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
OBJDIR="$HERE/.obj"
rm -rf "$OBJDIR"; mkdir -p "$OBJDIR"

echo "==> SDK: $SDK"
FILES="MCPServer MCPLogger HIDManager ScreenManager ClipboardManager AppManager \
AccessibilityManager TextInputManager FileSystemManager LogManager OCRManager \
MCPProcessUtil MCPAXQueryContext MCPAXRemoteContextResolver MCPUIElementSerializer \
MCPUIElementsFacade MCPAXAttributeBridge MCPAXNodeSource VisionOCREngine \
PaddleOCRManager MCPOCRRequestContext entry"
for f in $FILES; do
    "$CC" -arch arm64 -isysroot "$SDK" -miphoneos-version-min=15.0 -fobjc-arc -O2 -DMCP_ROOTLESS=1 \
          -I"$CORE" -c "$CORE/$f.m" -o "$OBJDIR/$f.o"
done

echo "==> link"
"$CC" -arch arm64 -isysroot "$SDK" -miphoneos-version-min=15.0 -dynamiclib -fobjc-arc \
      -I"$CORE" -Wl,-no_uuid -o "$OUT" "$OBJDIR"/*.o \
      -framework UIKit -framework Foundation -framework IOKit -framework CoreGraphics \
      -framework QuartzCore -framework MobileCoreServices -framework AVFoundation \
      -framework Security -framework Vision
rm -rf "$OBJDIR"

# mcp-logreader: live unified-log helper used by the get_syslog tool.
LOGHELPER="$HERE/prebuilt/mcp-logreader"
"$CC" -arch arm64 -isysroot "$SDK" -miphoneos-version-min=15.0 -fobjc-arc -O2 \
      "$HERE/tools/mcp-logreader/main.m" -o "$LOGHELPER" \
      -framework Foundation -framework CoreFoundation
if command -v ldid >/dev/null 2>&1; then
    ldid -S"$HERE/tools/mcp-logreader/mcp-logreader_entitlements.plist" "$LOGHELPER" || true
fi

if command -v ldid >/dev/null 2>&1; then
    ldid -S "$OUT" || true
fi
ls -la "$OUT" | sed 's/^/    /'
sha256sum "$OUT" | sed 's/^/    /'
echo "==> done: $OUT"
