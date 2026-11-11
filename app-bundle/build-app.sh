#!/bin/sh
# build-app.sh — 构建 dev.airdevs.dsh-app（桌面 APP + launchd 保活的 deb）
#
# 这就是用户要的「把 IPA 做成 deb」：一个 arm64 .app bundle 打进 deb，
# postinst 用 ldid 伪签 + uicache 注册，装完桌面出现 DSH 图标。
#
# 不需要 macOS / Xcode / iOS SDK：
#   * CFBundleExecutable 用 clang + ld.lld 交叉编译出 iOS arm64 Mach-O
#     （-adhoc_codesign 自带签名，-no_uuid 保证可复现）
#   * 图标用 make_app_icon.py 纯几何绘制
#   * deb 用 dpkg-deb -Zgzip -z9，固定 mtime/属主 + SOURCE_DATE_EPOCH
#
# 可复现：两次构建 SHA-256 完全一致（见 verify-app.sh）。
set -e
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO=$(CDPATH= cd -- "$ROOT/.." && pwd)
STAGE="$ROOT/.stage"
OUT="$ROOT/dist/dev.airdevs.dsh-app_0.2.1-rc.5+ios16_iphoneos-arm64.deb"
SDE="${SOURCE_DATE_EPOCH:-1700000000}"

for c in python3 dpkg-deb sha256sum clang ld.lld; do
    command -v "$c" >/dev/null 2>&1 || { echo "缺少 $c" >&2; exit 1; }
done

echo "==> 清理 stage"
rm -rf "$STAGE"; mkdir -p "$STAGE"
mkdir -p "$ROOT/dist"

echo "==> 复制 payload"
cp -a "$ROOT/payload/." "$STAGE/"

# --- 手机操控工具链（用户要求「启动 DSH 就能直接调用相关工具链操作手机」）---
# 放独立 launchd daemon，不进主 deb，因此 +ios15 稳定底座字节不变。
PBSRC="$REPO/phone-bridge"
PBDST="$STAGE/var/jb/usr/lib/dsh-phone-bridge"
mkdir -p "$PBDST" "$STAGE/var/jb/usr/bin" "$STAGE/var/jb/Library/LaunchDaemons"
for f in server.cjs ensure-config.cjs; do
    [ -f "$PBSRC/$f" ] || { echo "缺少 phone-bridge/$f" >&2; exit 1; }
    cp "$PBSRC/$f" "$PBDST/$f"
done
for f in dsh-phone-bridge-daemon dsh-phone-bridge-ctl; do
    [ -f "$PBSRC/$f" ] || { echo "缺少 phone-bridge/$f" >&2; exit 1; }
    cp "$PBSRC/$f" "$STAGE/var/jb/usr/bin/$f"
done
cp "$PBSRC/dev.airdevs.dsh.phone-bridge.plist" \
   "$STAGE/var/jb/Library/LaunchDaemons/dev.airdevs.dsh.phone-bridge.plist"
# 构建期语法自检（node 可选，缺则跳过 JS 检查）
if command -v node >/dev/null 2>&1; then
    for f in server.cjs ensure-config.cjs; do
        node --check "$PBDST/$f" || { echo "phone-bridge/$f 语法错误" >&2; exit 1; }
    done
fi
for f in dsh-phone-bridge-daemon dsh-phone-bridge-ctl; do
    sh -n "$STAGE/var/jb/usr/bin/$f" || { echo "$f 语法错误" >&2; exit 1; }
done
grep -q 'RunAtLoad' "$STAGE/var/jb/Library/LaunchDaemons/dev.airdevs.dsh.phone-bridge.plist" \
    || { echo "bridge plist 缺 RunAtLoad" >&2; exit 1; }
echo "    工具链: server.cjs + ensure-config.cjs + daemon + ctl + plist"

echo "==> 生成图标（纯几何，确定性）"
python3 "$ROOT/make_app_icon.py" "$STAGE/var/jb/Applications/DSH.app" | sed 's/^/    /'

echo "==> 交叉编译 iOS arm64 Mach-O launcher（无 Xcode）"
OBJ="$ROOT/.DSHLauncher.o"
clang --target=arm64-apple-ios16.0 -ffreestanding -fno-stack-protector \
      -fno-builtin -O2 -Wall -c "$ROOT/launcher-src/DSHLauncher.c" -o "$OBJ"
ld.lld -flavor darwin -arch arm64 -platform_version ios 16.0 16.0 \
       -pie -e __main -no_uuid -adhoc_codesign \
       -o "$STAGE/var/jb/Applications/DSH.app/DSHLauncher" "$OBJ"
rm -f "$OBJ"
file "$STAGE/var/jb/Applications/DSH.app/DSHLauncher" | sed 's/^/    /'

echo "==> 复制 DEBIAN"
cp -a "$ROOT/DEBIAN" "$STAGE/DEBIAN"
chmod 755 "$STAGE/DEBIAN/postinst" "$STAGE/DEBIAN/prerm"
chmod 755 "$STAGE/var/jb/Applications/DSH.app/DSHLauncher" \
          "$STAGE/var/jb/usr/bin/dsh-app-ui" \
          "$STAGE/var/jb/usr/bin/dsh-app-ctl" \
          "$STAGE/var/jb/usr/bin/dsh-daemon" \
          "$STAGE/var/jb/usr/bin/dsh-phone-bridge-daemon" \
          "$STAGE/var/jb/usr/bin/dsh-phone-bridge-ctl"
chmod 644 "$STAGE/var/jb/Applications/DSH.app/Info.plist" \
          "$STAGE/var/jb/Applications/DSH.app/entitlements.plist" \
          "$STAGE/var/jb/Applications/DSH.app/"*.png \
          "$STAGE/var/jb/Library/LaunchDaemons/dev.airdevs.dsh.plist" \
          "$STAGE/var/jb/Library/LaunchDaemons/dev.airdevs.dsh.phone-bridge.plist" \
          "$STAGE/var/jb/usr/lib/dsh-phone-bridge/server.cjs" \
          "$STAGE/var/jb/usr/lib/dsh-phone-bridge/ensure-config.cjs"

echo "==> 固定 mtime / 属主（SOURCE_DATE_EPOCH=$SDE）"
chown -R 0:0 "$STAGE" 2>/dev/null || true
find "$STAGE" -depth -exec touch -h -d "@$SDE" {} + 2>/dev/null || \
    find "$STAGE" -depth -exec touch -h -t 202311142013.20 {} + 2>/dev/null || true

echo "==> dpkg-deb 组装"
rm -f "$OUT"
SOURCE_DATE_EPOCH="$SDE" dpkg-deb -b -Zgzip -z9 "$STAGE" "$OUT" >/dev/null
echo "==> 产物"
ls -la "$OUT" | awk '{print "    "$5" bytes  "$9}'
sha256sum "$OUT" | sed 's/^/    /'
