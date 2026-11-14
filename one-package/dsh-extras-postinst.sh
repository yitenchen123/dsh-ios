#!/bin/sh
# 单包 extras：APP 签名 / 图标注册 / **全屏 Web Clip** / launchd 保活。
#
# 硬约束：绝不写 $DSH_HOME。旧版在这里 mkdir/chown -R $DSHHOME、跑
# `dsh-phone-bridge-ctl config-on`（改写 cordis.patch.yml）、写
# profiles/web/.npmrc 与 .dsh-market/state.json —— 全部已移除。
# 用户已有的对话、工作区、插件、npm 源、插件市场区域设置一律保留。
set -e
JB=/var/jb
APP="$JB/Applications/DSH.app"
ENT="$APP/entitlements.plist"
HELPER="$JB/usr/bin/dsh-app-helper"
DYLDIR="$JB/Library/MobileSubstrate/DynamicLibraries"
DYL="$DYLDIR/dsh-ios-control.dylib"
CTL="$JB/usr/bin/dsh-app-ctl"
BRCTL="$JB/usr/bin/dsh-phone-bridge-ctl"
LOGDIR="$JB/var/log/dsh-app"
WCSRC="$JB/usr/lib/dsh/webclip"
# 设备端为 SpringBoard 读取的真实路径；DSH_WEBCLIP_DIR 仅供沙箱实测隔离。
WCDIR="${DSH_WEBCLIP_DIR:-/var/mobile/Library/WebClips/133239ba-d3d0-422d-ba40-7945156fd8ea.webclip}"

# 包内系统文件权限（不涉及用户数据目录）。
chmod 755 "$APP/DSHLauncher" "$JB/usr/bin/dsh-app-ctl" "$JB/usr/bin/dsh-daemon" \
  "$JB/usr/bin/dsh-app-ui" "$JB/usr/bin/dsh-phone-bridge-daemon" \
  "$JB/usr/bin/dsh-phone-bridge-ctl" "$JB/usr/bin/mcp-logreader" 2>/dev/null || true
chmod 644 "$APP/Info.plist" "$APP/entitlements.plist" "$APP"/*.png 2>/dev/null || true
for f in "$JB/Library/LaunchDaemons/dev.airdevs.dsh.plist" \
         "$JB/Library/LaunchDaemons/dev.airdevs.dsh.phone-bridge.plist" \
         "$DYL" "$DYLDIR/dsh-ios-control.plist" "$HELPER" "$JB/usr/bin/mcp-logreader"; do
  [ -f "$f" ] && chown 0:0 "$f" 2>/dev/null || true
done
[ -f "$HELPER" ] && chmod 4755 "$HELPER" 2>/dev/null || true
LDID=""; for c in "$JB/usr/bin/ldid" "$JB/bin/ldid" /usr/bin/ldid; do [ -x "$c" ] && { LDID="$c"; break; }; done
if [ -n "$LDID" ]; then
  [ -f "$ENT" ] && "$LDID" -S"$ENT" "$APP/DSHLauncher" 2>/dev/null || true
  [ -f "$DYL" ] && "$LDID" -S "$DYL" 2>/dev/null || true
fi

# 日志在 jbroot 系统区，绝不 mkdir/chown $DSH_HOME/logs。
mkdir -p "$LOGDIR" 2>/dev/null || true

# 手机操控 bridge：只启动服务，绝不 config-on（那会改写用户插件配置）。
if [ -x "$BRCTL" ]; then "$BRCTL" enable >/dev/null 2>&1 || true; fi

# --- 真全屏 standalone Web Clip（官方 App 形态的主入口） ---
# SFSafariViewController 永远带 Safari 顶栏/底栏/关闭按钮，只是「近似全屏」。
# FullScreen=true 的 Web Clip 才有自己的桌面图标、启动画面且无浏览器栏。
# URL 带固定 DSH_WEB_TOKEN：rc.3 首次访问 303 换 cookie，之后所有 API /
# SSE / WebSocket 走 cookie，插件 / 工作区 / 对话全部正常加载。
if [ -f "$WCSRC/Info.plist" ]; then
    mkdir -p "$WCDIR" 2>/dev/null || true
    cp "$WCSRC/Info.plist" "$WCDIR/Info.plist" 2>/dev/null || true
    cp "$WCSRC/icon.png"   "$WCDIR/icon.png"   2>/dev/null || true
    cp "$WCSRC/icon.png"   "$WCDIR/Icon.png"   2>/dev/null || true
    # 只 chown 本包新建的这一个目录，不碰用户其它 Web Clip，更不碰 $DSH_HOME。
    chown -R 501:501 "$WCDIR" 2>/dev/null || true
else
    echo "dsh: [ERROR] 缺 $WCSRC/Info.plist，全屏 Web Clip 未安装；此 deb 构建不完整！" >&2
fi

# launchd 保活 + 图标注册（native APP + Web Clip 一起刷新）。
[ -x "$CTL" ] && "$CTL" enable   >/dev/null 2>&1 || true
[ -x "$CTL" ] && "$CTL" register >/dev/null 2>&1 || true
for U in "$JB/usr/bin/uicache" "$JB/bin/uicache" /usr/bin/uicache; do
    if [ -x "$U" ]; then "$U" -a >/dev/null 2>&1 || true; break; fi
done

echo "DeepSeek Harness 单包：APP + DSH 0.2.2-rc.3 + 全屏入口 已就绪。"
echo "  工作区 / 会话 / 插件全部保留，本包没有写入 \$DSH_HOME。"
exit 0
