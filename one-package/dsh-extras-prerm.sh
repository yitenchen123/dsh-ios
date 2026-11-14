#!/bin/sh
set -e
case "${1:-remove}" in upgrade|failed-upgrade|abort-upgrade) exit 0 ;; esac
JB=/var/jb
[ -x "$JB/usr/bin/dsh-phone-bridge-ctl" ] && { "$JB/usr/bin/dsh-phone-bridge-ctl" config-off >/dev/null 2>&1 || true; "$JB/usr/bin/dsh-phone-bridge-ctl" disable >/dev/null 2>&1 || true; }
[ -x "$JB/usr/bin/dsh-app-ctl" ] && "$JB/usr/bin/dsh-app-ctl" disable >/dev/null 2>&1 || true
rm -f "$JB/usr/bin/dsh-app-helper" "$JB/Library/MobileSubstrate/DynamicLibraries/dsh-ios-control.dylib" \
      "$JB/Library/MobileSubstrate/DynamicLibraries/dsh-ios-control.plist" 2>/dev/null || true
exit 0
