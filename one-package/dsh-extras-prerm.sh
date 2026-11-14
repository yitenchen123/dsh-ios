#!/bin/sh
# 单包 extras 卸载清理。
# 硬约束：绝不写 $DSH_HOME。旧版的 `dsh-phone-bridge-ctl config-off`
# 会改写用户 $DSH_HOME/cordis.patch.yml（等于删已有插件配置），已移除。
set -e
case "${1:-remove}" in upgrade|failed-upgrade|abort-upgrade) exit 0 ;; esac
JB=/var/jb
# 与 extras-postinst 对应，沙箱实测可用 DSH_WEBCLIP_DIR 覆盖到模拟目录。
WCDIR="${DSH_WEBCLIP_DIR:-/var/mobile/Library/WebClips/133239ba-d3d0-422d-ba40-7945156fd8ea.webclip}"

# 只停服务，绝不反注册用户插件配置。
[ -x "$JB/usr/bin/dsh-phone-bridge-ctl" ] && "$JB/usr/bin/dsh-phone-bridge-ctl" disable >/dev/null 2>&1 || true
[ -x "$JB/usr/bin/dsh-app-ctl" ] && "$JB/usr/bin/dsh-app-ctl" disable >/dev/null 2>&1 || true
rm -f "$JB/usr/bin/dsh-app-helper" \
      "$JB/Library/MobileSubstrate/DynamicLibraries/dsh-ios-control.dylib" \
      "$JB/Library/MobileSubstrate/DynamicLibraries/dsh-ios-control.plist" 2>/dev/null || true
# 只删本包安装的那一个 Web Clip，不遍历 / chown 用户 WebClips 目录，
# 更不碰 $DSH_HOME 里的会话、工作区、插件。
rm -rf "$WCDIR" 2>/dev/null || true
exit 0
