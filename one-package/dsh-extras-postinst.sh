#!/bin/sh
set -e
JB=/var/jb
APP="$JB/Applications/DSH.app"; ENT="$APP/entitlements.plist"
HELPER="$JB/usr/bin/dsh-app-helper"; DYLDIR="$JB/Library/MobileSubstrate/DynamicLibraries"
DYL="$DYLDIR/dsh-ios-control.dylib"; BRCTL="$JB/usr/bin/dsh-phone-bridge-ctl"; CTL="$JB/usr/bin/dsh-app-ctl"
DSHHOME="${DSH_HOME:-$JB/var/mobile/.dsh}"
chmod 755 "$APP/DSHLauncher" "$JB/usr/bin/dsh-app-ctl" "$JB/usr/bin/dsh-daemon" \
  "$JB/usr/bin/dsh-app-ui" "$JB/usr/bin/dsh-phone-bridge-daemon" "$JB/usr/bin/dsh-phone-bridge-ctl" \
  "$JB/usr/bin/mcp-logreader" 2>/dev/null || true
chmod 644 "$APP/Info.plist" "$APP/entitlements.plist" "$APP"/*.png 2>/dev/null || true
for f in "$JB/Library/LaunchDaemons/dev.airdevs.dsh.plist" "$JB/Library/LaunchDaemons/dev.airdevs.dsh.phone-bridge.plist" \
         "$DYL" "$DYLDIR/dsh-ios-control.plist" "$HELPER" "$JB/usr/bin/mcp-logreader"; do
  [ -f "$f" ] && chown 0:0 "$f" 2>/dev/null || true
done
[ -f "$HELPER" ] && chmod 4755 "$HELPER" 2>/dev/null || true
LDID=""; for c in "$JB/usr/bin/ldid" "$JB/bin/ldid" /usr/bin/ldid; do [ -x "$c" ] && { LDID="$c"; break; }; done
if [ -n "$LDID" ]; then
  [ -f "$ENT" ] && "$LDID" -S"$ENT" "$APP/DSHLauncher" 2>/dev/null || true
  [ -f "$DYL" ] && "$LDID" -S "$DYL" 2>/dev/null || true
fi
mkdir -p "$DSHHOME/logs" 2>/dev/null || true
chown -R 501:501 "$DSHHOME" 2>/dev/null || true
if [ -x "$BRCTL" ]; then "$BRCTL" config-on >/dev/null 2>&1 || true; "$BRCTL" enable >/dev/null 2>&1 || true; fi
[ -x "$CTL" ] && "$CTL" enable >/dev/null 2>&1 || true
[ -x "$CTL" ] && "$CTL" register >/dev/null 2>&1 || true
# full-screen Web Clip (official-app-like, no Safari bar)
WCDIR=/var/mobile/Library/WebClips/133239ba-d3d0-422d-ba40-7945156fd8ea.webclip
if [ -d "$JB/usr/lib/dsh/webclip" ]; then
    mkdir -p "$WCDIR" 2>/dev/null || true
    cp "$JB/usr/lib/dsh/webclip/Info.plist" "$WCDIR/Info.plist" 2>/dev/null || true
    cp "$JB/usr/lib/dsh/webclip/icon.png" "$WCDIR/icon.png" 2>/dev/null || true
    cp "$JB/usr/lib/dsh/webclip/icon.png" "$WCDIR/Icon.png" 2>/dev/null || true
    chown -R 501:501 /var/mobile/Library/WebClips 2>/dev/null || true
fi
# npm 国内镜像 + 插件市场 region=china（仅首次写入，不覆盖用户已有设置）
P="$DSHHOME/profiles/web"
mkdir -p "$P" 2>/dev/null || true
if [ ! -f "$P/.npmrc" ]; then printf 'registry=https://registry.npmmirror.com\n' > "$P/.npmrc" 2>/dev/null || true; fi
if [ ! -f "$P/.dsh-market/state.json" ]; then mkdir -p "$P/.dsh-market" 2>/dev/null || true; printf '{"disabled":[],"groups":{},"groupOrder":[],"region":"china","regionAuto":false}' > "$P/.dsh-market/state.json" 2>/dev/null || true; fi
chown -R 501:501 "$P/.npmrc" "$P/.dsh-market" 2>/dev/null || true
echo "DeepSeek Harness 单包：APP + DSH 0.2.2 + 手机操控 已就绪。"
exit 0
