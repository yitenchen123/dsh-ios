#!/bin/sh
# verify-app.sh — 独立核验 app-bundle 交付 deb（自解包，不复用 build.sh 逻辑）
# 覆盖：deb 布局 / plist 合法性 / 全屏 Web Clip / Mach-O 结构与签名 / 图标 /
#       脚本语法 / postinst 关键调用与零写入 / 不改动已发布 +ios15 主包 /
#       两次构建可复现 / 数据零改动实测。
set -e
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO=$(CDPATH= cd -- "$ROOT/.." && pwd)
DEB="$ROOT/dist/dev.airdevs.dsh-app_0.2.2-rc.3+ios18_iphoneos-arm64.deb"
TOKEN=$(tr -d '\r\n' < "$REPO/one-package/dsh-web-token")
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
LDPLIST="$X/var/jb/Library/LaunchDaemons/dev.airdevs.dsh.plist"
WCDIR="$X/var/jb/usr/lib/dsh/webclip"

sec "1) deb 布局（UTM/JBDev 式 .app in deb）"
[ -d "$APP" ] && ok ".app bundle 存在" || bad ".app bundle 缺失"
[ -f "$APP/Info.plist" ] && ok "Info.plist 存在" || bad "Info.plist 缺失"
[ -f "$APP/DSHLauncher" ] && ok "CFBundleExecutable 存在" || bad "CFBundleExecutable 缺失"
[ -f "$APP/entitlements.plist" ] && ok "entitlements.plist 存在" || bad "entitlements 缺失"
[ -f "$LDPLIST" ] && ok "LaunchDaemon plist 存在" || bad "LaunchDaemon plist 缺失"
for f in dsh-app-ui dsh-app-ctl dsh-daemon dsh-app-helper; do
    [ -f "$X/var/jb/usr/bin/$f" ] && ok "usr/bin/$f 存在" || bad "usr/bin/$f 缺失"
done
N=$(find "$APP" -name '*.png' | wc -l | tr -d ' ')
[ "$N" -ge 5 ] && ok "图标 $N 个" || bad "图标只有 $N 个（应 >=5）"
[ -f "$WCDIR/Info.plist" ] && ok "全屏 Web Clip Info.plist 已打进包" || bad "Web Clip Info.plist 缺失（旧版构建链断裂点）"
[ -f "$WCDIR/icon.png" ] && ok "全屏 Web Clip icon.png 已打进包" || bad "Web Clip icon.png 缺失"
# 独立小包：不含 125MB 引擎树，也不内嵌 phone-bridge（职责单一）
if dpkg-deb -c "$DEB" | grep -q 'node-v22\|dsh-nodemodules\|\.tar\.gz'; then
    bad "deb 里混入大文件（应保持小巧）"
else ok "deb 不含 125MB 主包内容（独立小包）"; fi
if dpkg-deb -c "$DEB" | grep -q 'dsh-phone-bridge'; then
    bad "deb 混入独立手机操控工具链"
else ok "deb 不含 phone-bridge（零写入链路更短，工具链独立可选）"; fi
# chown -R 0:0 会清 setuid 位；helper 必须真的是 4755 才能 bootstrap daemon
if dpkg-deb -c "$DEB" | grep 'dsh-app-helper' | grep -q 'rws'; then
    ok "setuid helper 为 4755（chown 后 setuid 位仍在）"
else bad "setuid helper 丢了 setuid 位（App 无法拉起 daemon）"; fi

sec "2) Info.plist / entitlements / LaunchDaemon plist 语法与关键键（20 项）"
python3 - "$TOKEN" "$APP/Info.plist" "$APP/entitlements.plist" "$LDPLIST" <<'PY'
import plistlib, sys
tok = sys.argv[1]
def load(p):
    with open(p, 'rb') as f: return plistlib.load(f)
info, ent, ld = load(sys.argv[2]), load(sys.argv[3]), load(sys.argv[4])
args = ld.get('ProgramArguments') or []
logs = (str(ld.get('StandardOutPath', '')) + str(ld.get('StandardErrorPath', '')))
checks = [
 ('Info CFBundleExecutable=DSHLauncher', info.get('CFBundleExecutable') == 'DSHLauncher'),
 ('Info CFBundleIdentifier', info.get('CFBundleIdentifier') == 'dev.airdevs.dsh.app'),
 ('Info CFBundlePackageType=APPL', info.get('CFBundlePackageType') == 'APPL'),
 ('Info MinimumOSVersion', str(info.get('MinimumOSVersion', '')).startswith(('15', '16'))),
 ('Info LSRequiresIPhoneOS', info.get('LSRequiresIPhoneOS') is True),
 ('Info arm64 能力', 'arm64' in (info.get('UIRequiredDeviceCapabilities') or [])),
 ('Info 图标键', bool(info.get('CFBundleIcons'))),
 ('ent platform-application', ent.get('platform-application') is True),
 ('ent container-required=false', ent.get('com.apple.private.security.container-required') is False),
 ('ent no-sandbox', ent.get('com.apple.private.security.no-sandbox') is True),
 ('LD Label', ld.get('Label') == 'dev.airdevs.dsh'),
 ('LD RunAtLoad', ld.get('RunAtLoad') is True),
 ('LD KeepAlive', ld.get('KeepAlive') is True),
 ('LD ThrottleInterval=10', ld.get('ThrottleInterval') == 10),
 ('LD UserName=mobile', ld.get('UserName') == 'mobile'),
 ('LD ProgramArguments 含 dsh-daemon 绝对路径', '/var/jb/usr/bin/dsh-daemon' in args),
 ('LD env 含 DSH_HOME', ld.get('EnvironmentVariables', {}).get('DSH_HOME') == '/var/jb/var/mobile/.dsh'),
 ('LD env 含 PATH', '/var/jb/usr/bin' in ld.get('EnvironmentVariables', {}).get('PATH', '')),
 ('LD env DSH_WEB_TOKEN 与常量一致', ld.get('EnvironmentVariables', {}).get('DSH_WEB_TOKEN') == tok),
 ('LD 日志在 $DSH_HOME 之外', bool(ld.get('StandardOutPath')) and bool(ld.get('StandardErrorPath')) and '/.dsh/' not in logs),
]
assert len(checks) == 20, 'checks 数量与 shell 计数不同步'
for n, c in checks:
    print(('  [ OK ] ' if c else '  [FAIL] ') + n)
    if not c: sys.exit(1)
PY
R=$? ; [ "$R" -eq 0 ] && PASS=$((PASS+20)) || FAIL=$((FAIL+1))

sec "3) 全屏 Web Clip（真全屏入口，无 Safari 栏）"
python3 - "$TOKEN" "$WCDIR/Info.plist" <<'PY'
import plistlib, sys
tok = sys.argv[1]
d = plistlib.load(open(sys.argv[2], 'rb'))
checks = [
 ('FullScreen=true', d.get('FullScreen') is True),
 ('URL 带与常量一致的固定 token', d.get('URL', '').endswith('?token=' + tok)),
 ('URL 为 loopback 127.0.0.1:3080', d.get('URL', '').startswith('http://127.0.0.1:3080/')),
 ('Precomposed=true', d.get('Precomposed') is True),
 ('CFBundleIdentifier 为 webapp', 'com.apple.webapp' in str(d.get('CFBundleIdentifier', ''))),
]
for n, c in checks:
    print(('  [ OK ] ' if c else '  [FAIL] ') + n)
    if not c: sys.exit(1)
PY
R=$? ; [ "$R" -eq 0 ] && PASS=$((PASS+5)) || FAIL=$((FAIL+1))
[ "$(wc -c < "$WCDIR/icon.png")" -gt 1000 ] && ok "Web Clip 图标非空" || bad "Web Clip 图标过小"

sec "4) Mach-O 结构（真 arm64 可执行 + 签名 + iOS 平台，8 项）"
python3 - "$APP/DSHLauncher" <<'PY'
import struct, sys
d = open(sys.argv[1], 'rb').read()
assert d[:4] == bytes.fromhex('cffaedfe'), '不是 LE arm64 Mach-O'
cpu = struct.unpack_from('<I', d, 4)[0]; assert cpu == 0x0100000c, '不是 arm64'
ft = struct.unpack_from('<I', d, 12)[0]
n = struct.unpack_from('<I', d, 16)[0]; off = 32; cmds = {}
for i in range(n):
    cmd, sz = struct.unpack_from('<II', d, off); cmds.setdefault(cmd, 0); cmds[cmd] += 1
    off += sz
checks = [
 ('magic/CPU = arm64', cpu == 0x0100000c),
 ('MH_EXECUTE filetype', ft == 2),
 ('MH_PIE 标志', bool(struct.unpack_from('<I', d, 24)[0] & 0x200000)),
 ('LC_MAIN 入口点', 0x80000028 in cmds),
 ('LC_BUILD_VERSION (iOS minos)', 0x32 in cmds),
 ('LC_CODE_SIGNATURE (ad-hoc)', 0x1d in cmds),
 ('无 LC_UUID（可复现）', 0x1b not in cmds),
 ('体积 < 100KB', len(d) < 100000),
]
assert len(checks) == 8
for name, c in checks:
    print(('  [ OK ] ' if c else '  [FAIL] ') + name)
    if not c: sys.exit(1)
PY
R=$?; [ "$R" -eq 0 ] && PASS=$((PASS+8)) || FAIL=$((FAIL+1))

sec "5) shell 脚本语法 + 关键调用 / 零写入断言"
for f in "$X/var/jb/usr/bin/dsh-app-ui" "$X/var/jb/usr/bin/dsh-app-ctl" \
         "$X/var/jb/usr/bin/dsh-daemon" "$TMP/DEBIAN/postinst" "$TMP/DEBIAN/prerm"; do
    if sh -n "$f" 2>/dev/null; then ok "sh -n $(basename "$f")"; else bad "sh -n $(basename "$f")"; fi
done
grep -q 'web --no-open --port' "$X/var/jb/usr/bin/dsh-daemon" && ok "daemon 前台 exec dsh web --no-open" || bad "daemon 未 exec web"
grep -q 'exec ' "$X/var/jb/usr/bin/dsh-daemon" && ok "daemon 用 exec（launchd 可管住 PID）" || bad "daemon 未 exec"
grep -q 'DSH_WEB_TOKEN' "$X/var/jb/usr/bin/dsh-daemon" && ok "daemon 注入固定 token 兜底" || bad "daemon 缺 DSH_WEB_TOKEN"
grep -q 'statusCode===303' "$X/var/jb/usr/bin/dsh-app-ctl" && ok "ctl ping 只认 303/200，不再把 401 判可连" || bad "ctl ping 仍把 401 判可连"
# 必须剥离注释：daemon 的注释里会描述旧版缺陷，裸 grep 会误报。
if grep -v '^[[:space:]]*#' "$X/var/jb/usr/bin/dsh-daemon" \
        | grep -qE 'while .*ping.*sleep|sleep 30'; then
    bad "daemon 仍有 30s 待机循环"
else ok "daemon 已删除 401 待机死循环"; fi
grep -q 'ldid' "$TMP/DEBIAN/postinst" && ok "postinst 用 ldid 伪签" || bad "postinst 缺 ldid"
grep -q 'register' "$TMP/DEBIAN/postinst" && ok "postinst 调 uicache 注册" || bad "postinst 缺 uicache"
grep -q 'enable' "$TMP/DEBIAN/postinst" && ok "postinst 加载 LaunchDaemon" || bad "postinst 缺 launchd 加载"
grep -q 'WCSRC/Info.plist' "$TMP/DEBIAN/postinst" && ok "postinst 真的安装全屏 Web Clip" || bad "postinst 缺 Web Clip 安装"
# 零写入：自动链路绝不递归改用户数据属主/权限、不 config-on/off
if grep -vE '^[[:space:]]*#|^[[:space:]]*echo|^[[:space:]]*printf' "$TMP/DEBIAN/postinst" \
        | grep -qE 'chown[[:space:]]+-R.*(\$DSHHOME|\$DSH_HOME|\.dsh)|chmod[[:space:]]+-R.*(\$DSHHOME|\$DSH_HOME|\.dsh)|config-on|config-off'; then
    bad "postinst 仍在写 \$DSH_HOME"
else ok "postinst 不递归改 \$DSH_HOME 属主/权限、不 config-on/off"; fi
grep -q 'LOGDIR="$JB/var/log/dsh-app"' "$TMP/DEBIAN/postinst" \
    && ok "postinst 日志目录在 \$DSH_HOME 之外" || bad "postinst 未把日志移出 \$DSH_HOME"
grep -q 'Disable\|disable' "$TMP/DEBIAN/prerm" && ok "prerm 停用 daemon" || bad "prerm 未停用 daemon"
if grep -q 'config-off' "$TMP/DEBIAN/prerm"; then
    bad "prerm 仍在反注册用户插件配置"
else ok "prerm 不重写用户 patch"; fi

sec "6) control 元数据"
grep -q '^Package: dev.airdevs.dsh-app$' "$TMP/DEBIAN/control" && ok "包名正确" || bad "包名错误"
grep -q '^Version: 0.2.2-rc.3+ios18$' "$TMP/DEBIAN/control" && ok "版本与单包 / 最新 DSH 一致" || bad "版本不一致"
grep -q '^Architecture: iphoneos-arm64$' "$TMP/DEBIAN/control" && ok "架构 iphoneos-arm64" || bad "架构错误"
grep -q 'Depends: dev.airdevs.dsh' "$TMP/DEBIAN/control" && ok "依赖主包" || bad "缺主包依赖"
grep -q 'SpringBoard' "$TMP/DEBIAN/control" && ok "描述含 SpringBoard/.app" || bad "描述缺 .app 说明"
if grep -q 'near full-screen\|全屏.*SFSafariViewController' "$TMP/DEBIAN/control"; then
    bad "control 仍把半屏 SFSafariViewController 说成全屏"
else ok "control 不再虚假承诺 SFSafariViewController 全屏"; fi

sec "7) 不改动已发布 +ios15 主包"
MAINDEB="$REPO/dist/dev.airdevs.dsh_0.2.1-rc.5+ios15_iphoneos-arm64.deb"
if [ -f "$MAINDEB" ]; then
    S=$(sha256sum "$MAINDEB" | cut -d' ' -f1)
    E=$(grep 'dev.airdevs.dsh_0.2.1-rc.5+ios15_iphoneos-arm64.deb' "$REPO/dist/SHA256SUMS.txt" | awk '{print $1}')
    [ "$S" = "$E" ] && ok "+ios15 主 deb SHA 未变 ($S)" || bad "+ios15 主 deb SHA 变了"
else bad "+ios15 主 deb 缺失"; fi
if [ -d "$REPO/payload/var/jb/Applications" ]; then bad "主包 payload 被写入 .app（应完全独立）"; else ok "主包 payload 完全未改"; fi

sec "8) 两次构建字节级可复现"
A=$(sha256sum "$DEB" | cut -d' ' -f1)
sh "$ROOT/build-app.sh" >/dev/null 2>&1
B=$(sha256sum "$DEB" | cut -d' ' -f1)
if [ "$A" = "$B" ]; then ok "两次构建 SHA 一致 ($A)"; else bad "两次构建不一致：$A / $B"; fi

sec "9) 数据零改动实测（模拟 \$DSH_HOME 全量 SHA-256 指纹前后对比）"
if sh "$ROOT/verify-no-data-touch.sh" > "$TMP/vndt.log" 2>&1; then
    ok "verify-no-data-touch.sh 全部断言通过（装/卸 APP 零写入用户数据）"
else
    bad "verify-no-data-touch.sh 失败，输出："
    tail -40 "$TMP/vndt.log" >&2
fi

printf '\n=== 汇总: OK=%d FAIL=%d ===\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
echo "✔ dev.airdevs.dsh-app 独立核验全部通过（含全屏 Web Clip 与数据零改动实测）"
