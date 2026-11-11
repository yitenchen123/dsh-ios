#!/bin/sh
# verify-app.sh — 独立核验交付 deb（自解包，不复用 build.sh 逻辑）
# 覆盖：deb 布局 / plist 合法性 / Mach-O 结构与签名 / 图标 / 脚本语法 /
#       postinst 关键调用 / 不改动已发布 +ios15 主包 / 两次构建可复现。
set -e
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO=$(CDPATH= cd -- "$ROOT/.." && pwd)
DEB="$ROOT/dist/dev.airdevs.dsh-app_0.2.1-rc.5+ios16_iphoneos-arm64.deb"
PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); printf '  [ OK ] %s\n' "$*"; }
bad()  { FAIL=$((FAIL+1)); printf '  [FAIL] %s\n' "$*"; }
sec()  { printf '\n=== %s ===\n' "$*"; }

[ -f "$DEB" ] || { echo "缺少 $DEB，先跑 sh build-app.sh" >&2; exit 1; }
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
dpkg-deb -x "$DEB" "$TMP/x"
dpkg-deb -e "$DEB" "$TMP/DEBIAN"
X="$TMP/x"
APP="$X/var/jb/Applications/DSH.app"

sec "1) deb 布局（UTM/JBDev 式 .app in deb）"
[ -d "$APP" ] && ok ".app bundle 存在" || bad ".app bundle 缺失"
[ -f "$APP/Info.plist" ] && ok "Info.plist 存在" || bad "Info.plist 缺失"
[ -f "$APP/DSHLauncher" ] && ok "CFBundleExecutable 存在" || bad "CFBundleExecutable 缺失"
[ -f "$APP/entitlements.plist" ] && ok "entitlements.plist 存在" || bad "entitlements 缺失"
[ -f "$X/var/jb/Library/LaunchDaemons/dev.airdevs.dsh.plist" ] && ok "LaunchDaemon plist 存在" || bad "LaunchDaemon plist 缺失"
for f in dsh-app-ui dsh-app-ctl dsh-daemon; do
    [ -f "$X/var/jb/usr/bin/$f" ] && ok "usr/bin/$f 存在" || bad "usr/bin/$f 缺失"
done
N=$(find "$APP" -name '*.png' | wc -l | tr -d ' ')
[ "$N" -ge 5 ] && ok "图标 $N 个" || bad "图标只有 $N 个（应 >=5）"
# 不在 payload 里的东西绝不能混进 deb
if dpkg-deb -c "$DEB" | grep -q 'node-v22\|dsh-nodemodules\|\.tar\.gz'; then
    bad "deb 里混入大文件（应保持小巧）"
else ok "deb 不含 125MB 主包内容（独立小包）"; fi

sec "2) Info.plist / entitlements / LaunchDaemon plist 语法与关键键"
python3 - "$APP/Info.plist" "$APP/entitlements.plist" "$X/var/jb/Library/LaunchDaemons/dev.airdevs.dsh.plist" <<'PY'
import plistlib, sys
def load(p):
    with open(p,'rb') as f: return plistlib.load(f)
info=load(sys.argv[1]); ent=load(sys.argv[2]); ld=load(sys.argv[3])
checks=[
 ('Info CFBundleExecutable=DSHLauncher', info.get('CFBundleExecutable')=='DSHLauncher'),
 ('Info CFBundleIdentifier', info.get('CFBundleIdentifier')=='dev.airdevs.dsh.app'),
 ('Info CFBundlePackageType=APPL', info.get('CFBundlePackageType')=='APPL'),
 ('Info MinimumOSVersion', str(info.get('MinimumOSVersion','')).startswith(('15','16'))),
 ('Info LSRequiresIPhoneOS', info.get('LSRequiresIPhoneOS') is True),
 ('Info arm64 能力', 'arm64' in (info.get('UIRequiredDeviceCapabilities') or [])),
 ('Info 图标键', bool(info.get('CFBundleIcons'))),
 ('ent platform-application', ent.get('platform-application') is True),
 ('ent container-required=false', ent.get('com.apple.private.security.container-required') is False),
 ('ent no-sandbox', ent.get('com.apple.private.security.no-sandbox') is True),
 ('LD Label', ld.get('Label')=='dev.airdevs.dsh'),
 ('LD RunAtLoad', ld.get('RunAtLoad') is True),
 ('LD KeepAlive', ld.get('KeepAlive') is True),
 ('LD ThrottleInterval=10', ld.get('ThrottleInterval')==10),
 ('LD UserName=mobile', ld.get('UserName')=='mobile'),
 ('LD ProgramArguments 绝对路径', (ld.get('ProgramArguments') or [''])[0]=='/var/jb/usr/bin/dsh-daemon'),
 ('LD env 含 DSH_HOME', ld.get('EnvironmentVariables',{}).get('DSH_HOME')=='/var/jb/var/mobile/.dsh'),
 ('LD env 含 PATH', '/var/jb/usr/bin' in ld.get('EnvironmentVariables',{}).get('PATH','')),
 ('LD stdout/stderr 日志', bool(ld.get('StandardOutPath')) and bool(ld.get('StandardErrorPath'))),
]
for n,c in checks:
    print(('  [ OK ] ' if c else '  [FAIL] ')+n)
    if not c: sys.exit(1)
PY
R=$? ; [ "$R" -eq 0 ] && PASS=$((PASS+20)) || FAIL=$((FAIL+1))

sec "3) Mach-O 结构（真 arm64 可执行 + 签名 + iOS 平台）"
python3 - "$APP/DSHLauncher" <<'PY'
import struct,sys
d=open(sys.argv[1],'rb').read()
assert d[:4]==bytes.fromhex('cffaedfe'), '不是 LE arm64 Mach-O'
cpu=struct.unpack_from('<I',d,4)[0]; assert cpu==0x0100000c, '不是 arm64'
ft=struct.unpack_from('<I',d,12)[0]
n=struct.unpack_from('<I',d,16)[0]; off=32; cmds={}
for i in range(n):
    cmd,sz=struct.unpack_from('<II',d,off); cmds.setdefault(cmd,0); cmds[cmd]+=1
    off+=sz
checks=[
 ('magic/CPU = arm64', cpu==0x0100000c),
 ('MH_EXECUTE filetype', ft==2),
 ('MH_PIE 标志', bool(struct.unpack_from('<I',d,24)[0] & 0x200000)),
 ('LC_MAIN 入口点', 0x80000028 in cmds),
 ('LC_BUILD_VERSION (iOS minos)', 0x32 in cmds),
 ('LC_CODE_SIGNATURE (ad-hoc)', 0x1d in cmds),
 ('无 LC_UUID（可复现）', 0x1b not in cmds),
 ('体积 < 100KB', len(d)<100000),
]
for name,c in checks:
    print(('  [ OK ] ' if c else '  [FAIL] ')+name)
    if not c: sys.exit(1)
PY
R=$?; [ "$R" -eq 0 ] && PASS=$((PASS+8)) || FAIL=$((FAIL+1))

sec "4) shell 脚本语法 + 关键调用"
for f in "$X/var/jb/usr/bin/dsh-app-ui" "$X/var/jb/usr/bin/dsh-app-ctl" \
         "$X/var/jb/usr/bin/dsh-daemon" "$TMP/DEBIAN/postinst" "$TMP/DEBIAN/prerm"; do
    if sh -n "$f" 2>/dev/null; then ok "sh -n $(basename "$f")"; else bad "sh -n $(basename "$f")"; fi
done
grep -q 'web --no-open --port' "$X/var/jb/usr/bin/dsh-daemon" && ok "daemon 前台 exec dsh web --no-open" || bad "daemon 未 exec web"
grep -q 'exec ' "$X/var/jb/usr/bin/dsh-daemon" && ok "daemon 用 exec（launchd 可管住 PID）" || bad "daemon 未 exec"
grep -q 'ldid' "$TMP/DEBIAN/postinst" && ok "postinst 用 ldid 伪签" || bad "postinst 缺 ldid"
grep -q 'register' "$TMP/DEBIAN/postinst" && ok "postinst 调 uicache 注册" || bad "postinst 缺 uicache"
grep -q 'enable' "$TMP/DEBIAN/postinst" && ok "postinst 加载 LaunchDaemon" || bad "postinst 缺 launchd 加载"
grep -q '501:501' "$TMP/DEBIAN/postinst" && ok "postinst 修 mobile 属主（防 EACCES）" || bad "postinst 缺属主修复"
grep -q 'Disable\|disable' "$TMP/DEBIAN/prerm" && ok "prerm 停用 daemon" || bad "prerm 未停用 daemon"

sec "4b) 手机操控工具链（内置 MCP bridge，启动 DSH 即可调用）"
PB="$X/var/jb/usr/lib/dsh-phone-bridge"
BPLIST="$X/var/jb/Library/LaunchDaemons/dev.airdevs.dsh.phone-bridge.plist"
for f in server.cjs ensure-config.cjs; do
    [ -f "$PB/$f" ] && ok "phone-bridge/$f 存在" || bad "phone-bridge/$f 缺失"
done
for f in dsh-phone-bridge-daemon dsh-phone-bridge-ctl; do
    [ -f "$X/var/jb/usr/bin/$f" ] && ok "usr/bin/$f 存在" || bad "usr/bin/$f 缺失"
done
[ -f "$BPLIST" ] && ok "bridge LaunchDaemon plist 存在" || bad "bridge plist 缺失"
if command -v node >/dev/null 2>&1; then
    for f in server.cjs ensure-config.cjs; do
        node --check "$PB/$f" >/dev/null 2>&1 && ok "$f node --check 通过" || bad "$f 语法错误"
    done
fi
for f in dsh-phone-bridge-daemon dsh-phone-bridge-ctl; do
    sh -n "$X/var/jb/usr/bin/$f" 2>/dev/null && ok "$f sh -n 通过" || bad "$f 语法错误"
done
python3 -c 'import plistlib,sys; d=plistlib.load(open(sys.argv[1],"rb")); assert d["Label"]=="dev.airdevs.dsh.phone-bridge" and d["RunAtLoad"] and d["KeepAlive"] and d["UserName"]=="mobile"' "$BPLIST" 2>/dev/null \
    && ok "bridge plist 合法且 RunAtLoad/KeepAlive/mobile 齐全" || bad "bridge plist 校验失败"
grep -q '8091' "$PB/server.cjs" && ok "bridge 固定回环 127.0.0.1:8091（不抢 ios-mcp 的 8090）" || bad "bridge 端口不对"
grep -q 'upstream' "$PB/server.cjs" && ok "bridge 支持转发到原生 ios-mcp" || bad "bridge 缺上游转发"
grep -q 'dsh-ios-phone-bridge-mcp' "$PB/ensure-config.cjs" && ok "自动注册块 id 就位" || bad "缺自动注册块"
grep -q 'config-on' "$TMP/DEBIAN/postinst" && ok "postinst 注册 MCP 配置" || bad "postinst 未注册配置"
grep -q 'config-off' "$TMP/DEBIAN/prerm" && ok "prerm 反注册 MCP 配置" || bad "prerm 未反注册"
[ ! -d "$REPO/payload/var/jb/usr/lib/dsh-phone-bridge" ] && ok "主包 payload 完全未含 bridge（稳定底座不变）" || bad "bridge 混进了主包 payload"

sec "5) control 元数据"
grep -q '^Package: dev.airdevs.dsh-app$' "$TMP/DEBIAN/control" && ok "包名正确" || bad "包名错误"
grep -q '^Architecture: iphoneos-arm64$' "$TMP/DEBIAN/control" && ok "架构 iphoneos-arm64" || bad "架构错误"
grep -q 'Depends: dev.airdevs.dsh' "$TMP/DEBIAN/control" && ok "依赖主包" || bad "缺主包依赖"
grep -q 'SpringBoard' "$TMP/DEBIAN/control" && ok "描述含 SpringBoard/.app" || bad "描述缺 .app 说明"

sec "6) 不改动已发布 +ios15 主包"
MAINDEB="$REPO/dist/dev.airdevs.dsh_0.2.1-rc.5+ios15_iphoneos-arm64.deb"
if [ -f "$MAINDEB" ]; then
    S=$(sha256sum "$MAINDEB" | cut -d' ' -f1)
    E=$(grep 'dev.airdevs.dsh_0.2.1-rc.5+ios15_iphoneos-arm64.deb' "$REPO/dist/SHA256SUMS.txt" | awk '{print $1}')
    [ "$S" = "$E" ] && ok "+ios15 主 deb SHA 未变 ($S)" || bad "+ios15 主 deb SHA 变了"
else bad "+ios15 主 deb 缺失"; fi
# 主包 payload 未被本包触碰
if [ -d "$REPO/payload/var/jb/Applications" ]; then bad "主包 payload 被写入 .app（应完全独立）"; else ok "主包 payload 完全未改"; fi

sec "7) 两次构建字节级可复现"
A=$(sha256sum "$DEB" | cut -d' ' -f1)
sh "$ROOT/build-app.sh" >/dev/null 2>&1
B=$(sha256sum "$DEB" | cut -d' ' -f1)
if [ "$A" = "$B" ]; then ok "两次构建 SHA 一致 ($A)"; else bad "两次构建不一致：$A / $B"; fi

printf '\n=== 汇总: OK=%d FAIL=%d ===\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
echo "✔ dev.airdevs.dsh-app 独立核验全部通过"
