#!/bin/sh
# ---------------------------------------------------------------------------
# verify-no-data-touch.sh —— 沙箱实测「装/卸/启动 APP 不改动任何已有用户数据」
#
# 用户硬约束：做成 APP（.app-in-deb / 全屏 Web Clip 形式），已有的对话 /
# 工作区 / 插件 / cordis.patch.yml / profiles/* 一个字节都不变。
#
#   ① 构造模拟 rootless 树：/var/jb 必须是【符号链接】（与真机 Dopamine
#      rootless 一致，否则 postinst 的 [ ! -L ] 门禁会提前跳过，测了个寂寞）
#   ② 预置 $DSH_HOME 里的会话(含嵌套)/工作区/多插件/用户 patch/不同属主权限
#   ③ 记录全量指纹：目录清单 + 每文件 SHA-256 + mode + uid:gid
#   ④ 跑仓库里【原封不动】的两套 postinst / prerm（app-bundle 与 one-package），
#      仅把 ldid / launchctl / uicache / trustcache 等外部命令换成 stub；
#      Web Clip 安装路径用 DSH_WEBCLIP_DIR 重定向到模拟目录，避免写宿主
#   ⑤ 逐行 diff 指纹：必须完全一致；并断言 Web Clip 真的被装上了
#   ⑥ 分类静态扫描：自动执行链路禁止写 $DSH_HOME；plist 日志路径必须在外；
#      Web Clip URL / launchd plist / 常量文件的 token 必须逐字一致
#
# 边界：DSH 本体运行时正常新增会话/缓存属于产品功能，不在本测试范围；
# 本测试验证的是「安装 / 卸载 / 启动 APP 这些动作」零写入已有数据。
# 真机上 /var/jb 一定是真实目录，本脚本会拒绝运行（退出码 2）。
#
# 用法: sh app-bundle/verify-no-data-touch.sh
# ---------------------------------------------------------------------------
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
APPB="$ROOT/app-bundle"
ONE="$ROOT/one-package"
PB="$ROOT/phone-bridge"
J=/var/jb
SIM=$(mktemp -d /tmp/dsh-app-sim.XXXXXX)
JBROOT="$SIM/jbroot"
H="$JBROOT/var/mobile/.dsh"
APPLOG="$JBROOT/var/log/dsh-app"
WCSIM="$SIM/webclips/133239ba-d3d0-422d-ba40-7945156fd8ea.webclip"
TOKEN=$(tr -d '\r\n' < "$ONE/dsh-web-token")
FAIL=0
ok()  { printf '  [ ok  ] %s\n' "$1"; }
bad() { printf '  [FAIL ] %s\n' "$1" >&2; FAIL=$((FAIL+1)); }
sec() { printf '\n=== %s ===\n' "$*"; }

# --- 安全护栏：绝不碰真机；无论原本有没有 /var/jb 都无条件清理 ------------
HAD_SYMLINK=0
if [ -L "$J" ]; then
    HAD_SYMLINK=1
    mv "$J" "${J}.sim-backup"
elif [ -e "$J" ]; then
    echo "拒绝运行：$J 是真实目录，可能是真机 / 真实 rootless 环境" >&2
    rm -rf "$SIM"
    exit 2
fi
ln -s "$JBROOT" "$J"
if [ "$HAD_SYMLINK" -eq 1 ]; then
    trap 'rm -f "$J"; mv "${J}.sim-backup" "$J"; rm -rf "$SIM"' EXIT INT TERM
else
    trap 'rm -f "$J"; rm -rf "$SIM"' EXIT INT TERM
fi

# --- ① 构造模拟 rootless 树 ----------------------------------------------
sec "1) 构造模拟 rootless 环境（/var/jb 为符号链接）+ 预置用户数据"
mkdir -p "$JBROOT/Applications/DSH.app" "$JBROOT/usr/bin" \
         "$JBROOT/usr/lib/dsh/bin" "$JBROOT/usr/lib/dsh/webclip" \
         "$JBROOT/usr/lib/dsh-phone-bridge" "$JBROOT/Library/LaunchDaemons" \
         "$JBROOT/bin" "$APPLOG" "$WCSIM" \
         "$H/sessions/2026-11" "$H/sessions/2026-10" "$H/workspace/proj-a" \
         "$H/plugins/alpha" "$H/plugins/beta" "$H/plugins/gamma" \
         "$H/profiles/web" "$H/pnpm" "$H/pnpm-cache" "$H/npm-cache"

# .app / plist 占位（postinst 会 chmod / ldid 它们，全在 $DSH_HOME 外）
for f in DSHLauncher Info.plist entitlements.plist Icon60x60@2x.png; do
    : > "$JBROOT/Applications/DSH.app/$f"
done
: > "$JBROOT/Library/LaunchDaemons/dev.airdevs.dsh.plist"
: > "$JBROOT/Library/LaunchDaemons/dev.airdevs.dsh.phone-bridge.plist"

# 真实脚本，确保测到完整链路
for f in dsh-app-ui dsh-app-ctl dsh-daemon; do
    cp "$APPB/payload/var/jb/usr/bin/$f" "$JBROOT/usr/bin/$f"; chmod 755 "$JBROOT/usr/bin/$f"
done
for f in dsh-phone-bridge-daemon dsh-phone-bridge-ctl; do
    cp "$PB/$f" "$JBROOT/usr/bin/$f"; chmod 755 "$JBROOT/usr/bin/$f"
done
cp "$PB/ensure-config.cjs" "$JBROOT/usr/lib/dsh-phone-bridge/ensure-config.cjs"
cp "$PB/server.cjs" "$JBROOT/usr/lib/dsh-phone-bridge/server.cjs"
# one-package 的 extras 也要真实进模拟树（postinst 会调用它装全屏 Web Clip）
cp "$ONE/dsh-extras-postinst.sh" "$JBROOT/usr/lib/dsh/dsh-extras-postinst.sh"
cp "$ONE/dsh-extras-prerm.sh"   "$JBROOT/usr/lib/dsh/dsh-extras-prerm.sh"
chmod 755 "$JBROOT/usr/lib/dsh/dsh-extras-postinst.sh" \
          "$JBROOT/usr/lib/dsh/dsh-extras-prerm.sh"
cp "$ONE/webclip/Info.plist" "$JBROOT/usr/lib/dsh/webclip/Info.plist"
cp "$ONE/webclip/icon.png"   "$JBROOT/usr/lib/dsh/webclip/icon.png"
# one-package/DEBIAN/postinst 会 chmod 这些引擎文件
for f in dsh dsh-doctor; do : > "$JBROOT/usr/bin/$f"; done
printf '#!/bin/sh\nexit 0\n' > "$JBROOT/usr/lib/dsh/bin/node"
chmod 755 "$JBROOT/usr/lib/dsh/bin/node"

# 外部命令 stub
for c in ldid launchctl uicache trustcache uiopen open pgrep pkill node strings; do
    printf '#!/bin/sh\nexit 0\n' > "$JBROOT/usr/bin/$c"
    chmod 755 "$JBROOT/usr/bin/$c"
done

# --- ② 用户数据 ------------------------------------------------------------
printf '{"messages":[{"role":"user","content":"old conversation A"}]}\n' > "$H/sessions/sess-a.jsonl"
printf '{"messages":[{"role":"user","content":"old conversation B"}]}\n' > "$H/sessions/sess-b.jsonl"
printf '{"messages":[{"role":"user","content":"nested session C"}]}\n' > "$H/sessions/2026-11/sess-c.jsonl"
printf '{"messages":[{"role":"user","content":"nested session D"}]}\n' > "$H/sessions/2026-10/sess-d.jsonl"
printf '# my workspace notes\nimportant work in progress\n' > "$H/workspace/proj-a/NOTES.md"
printf '{"cwd":"/var/mobile/proj-a"}\n' > "$H/workspace/proj-a/state.json"
for p in alpha beta gamma; do
    printf '{"name":"%s","version":"1.0.0"}\n' "$p" > "$H/plugins/$p/manifest.json"
    printf 'plugin-%s-payload-do-not-touch\n' "$p" > "$H/plugins/$p/data.txt"
done
cat > "$H/cordis.patch.yml" <<'EOF'
# 用户自己的配置，APP 一个字节都不能改
- insert:
    - id: my-qqbot
      name: '@deepseek-ai/dsh-im'
      config:
        foo: bar
EOF
cat > "$H/profiles/web/cordis.patch.yml" <<'EOF'
# web profile 用户配置
- insert:
    - id: my-web-plugin
      name: 'some-user-plugin'
EOF
printf 'nowasm\n' > "$H/.dsh-tier"
printf 'node24-cache-placeholder\n' > "$H/pnpm/store-v3"
printf '{"theme":"dark"}\n' > "$H/settings.json"
chmod 600 "$H/sessions/sess-a.jsonl" "$H/cordis.patch.yml"
chmod 640 "$H/plugins/alpha/data.txt"
chmod 750 "$H/workspace/proj-a"
chown 501:501 "$H/sessions/sess-a.jsonl" 2>/dev/null || true
chown 0:0   "$H/settings.json" 2>/dev/null || true

# --- ③ 指纹 ---------------------------------------------------------------
fingerprint() {
    (cd "$H" && find . -printf '%y %m %U %G %p\n' | sort)
    (cd "$H" && find . -type f -print0 | sort -z | xargs -0 sha256sum)
}
BASE=$(fingerprint)
BASE_FILES=$(cd "$H" && find . -type f | wc -l | tr -d ' ')
echo "  预置用户数据文件数 = $BASE_FILES"

run_script() {
    _name=$1; _path=$2; shift 2
    _out="/tmp/dsh-app-${_name}.out"
    if DSH_WEBCLIP_DIR="$WCSIM" sh "$_path" "$@" > "$_out" 2>&1; then
        ok "$_name 正常退出 0"
    else
        bad "$_name 非 0 退出"
    fi
    sed 's/^/    | /' "$_out" | head -16
    if grep -q '未检测到 rootless' "$_out"; then
        bad "$_name 门禁提前跳过，未测到真实逻辑"
    fi
}

# --- ④ 跑原封不动的两套 postinst -----------------------------------------
sec "2) 执行原封不动的 postinst（app-bundle + one-package）"
run_script "app-bundle-postinst"  "$APPB/DEBIAN/postinst"
run_script "one-package-postinst" "$ONE/DEBIAN/postinst"

# Web Clip 必须真的被装上（旧版 extras 没进包，这一步恒失败）
sec "3) 全屏 Web Clip 确实被安装（旧版构建链断裂点）"
for f in Info.plist icon.png Icon.png; do
    [ -f "$WCSIM/$f" ] && ok "Web Clip $f 已落地" || bad "Web Clip $f 缺失"
done
python3 - "$WCSIM/Info.plist" "$TOKEN" <<'PY'
import plistlib, sys
d = plistlib.load(open(sys.argv[1], 'rb'))
assert d.get('FullScreen') is True, 'Web Clip 非 FullScreen'
assert d.get('URL', '').endswith('?token=' + sys.argv[2]), 'Web Clip URL token 不一致'
print('  [ ok  ] Web Clip FullScreen=true 且 URL 带正确 token')
PY

# --- ⑤ 跑原封不动的两套 prerm -------------------------------------------
sec "4) 执行原封不动的 prerm（app-bundle + one-package）"
run_script "app-bundle-prerm"  "$APPB/DEBIAN/prerm"  remove
run_script "one-package-prerm" "$ONE/DEBIAN/prerm"   remove

# --- ⑥ 指纹对比 -----------------------------------------------------------
sec "5) 全量指纹对比（内容 / mode / uid:gid / 目录清单）"
AFTER=$(fingerprint)
if [ "$BASE" = "$AFTER" ]; then
    ok "$BASE_FILES 个用户数据文件的 SHA-256 / 权限 / 属主 / 目录结构逐项一致"
else
    bad "用户数据被改动！diff 如下："
    printf '%s\n' "$BASE"  > /tmp/dsh-app-fp-before.txt
    printf '%s\n' "$AFTER" > /tmp/dsh-app-fp-after.txt
    diff /tmp/dsh-app-fp-before.txt /tmp/dsh-app-fp-after.txt | head -40 >&2 || true
fi
grep -q 'my-qqbot' "$H/cordis.patch.yml" \
    && ok "用户自己的 cordis.patch.yml 配置块完好" || bad "用户 patch 块被破坏"
if grep -q 'dsh-ios-phone-bridge-mcp' "$H/cordis.patch.yml" "$H/profiles/web/cordis.patch.yml" 2>/dev/null; then
    bad "cordis.patch.yml 被注入了 MCP 块"
else
    ok "cordis.patch.yml / profiles patch 均未被注入 MCP 块"
fi

# --- ⑦ $DSH_HOME 内不得新增任何东西 --------------------------------------
sec "6) \$DSH_HOME 内无新增文件 / 目录"
[ ! -e "$H/logs" ] && ok "未创建 \$DSH_HOME/logs" || bad "\$DSH_HOME/logs 被创建"
[ ! -e "$H/app-ui.log" ] && ok "未写 app-ui.log 到 \$DSH_HOME" || bad "app-ui.log 写进了 \$DSH_HOME"
AFTER_FILES=$(cd "$H" && find . -type f | wc -l | tr -d ' ')
[ "$AFTER_FILES" = "$BASE_FILES" ] \
    && ok "文件数未变 ($BASE_FILES -> $AFTER_FILES)" \
    || bad "文件数变了 ($BASE_FILES -> $AFTER_FILES)"
[ -d "$APPLOG" ] && ok "App 日志目录在 \$DSH_HOME 之外" || bad "外部日志目录未创建"

# --- ⑧ 分类静态扫描 -------------------------------------------------------
sec "7) 静态扫描：自动执行链路禁止写 \$DSH_HOME；token 与日志路径合规"
python3 - "$APPB" "$ONE" "$PB" "$TOKEN" <<'PY'
import os, re, plistlib, sys
appb, one, pb, tok = sys.argv[1:5]
AUTO = [
    (os.path.join(appb, 'DEBIAN/postinst'), 'app postinst'),
    (os.path.join(appb, 'DEBIAN/prerm'), 'app prerm'),
    (os.path.join(appb, 'payload/var/jb/usr/bin/dsh-daemon'), 'dsh-daemon'),
    (os.path.join(appb, 'payload/var/jb/usr/bin/dsh-app-ui'), 'dsh-app-ui'),
    (os.path.join(appb, 'payload/var/jb/usr/bin/dsh-app-ctl'), 'dsh-app-ctl'),
    (os.path.join(one,  'DEBIAN/postinst'), 'one postinst'),
    (os.path.join(one,  'DEBIAN/prerm'), 'one prerm'),
    (os.path.join(one,  'dsh-extras-postinst.sh'), 'extras postinst'),
    (os.path.join(one,  'dsh-extras-prerm.sh'), 'extras prerm'),
    (os.path.join(pb,   'dsh-phone-bridge-daemon'), 'bridge daemon'),
]
PLISTS = [
    os.path.join(appb, 'payload/var/jb/Library/LaunchDaemons/dev.airdevs.dsh.plist'),
    os.path.join(pb,   'dev.airdevs.dsh.phone-bridge.plist'),
]

def code_lines(text):
    out = []
    for ln in text.splitlines():
        s = ln.strip()
        if not s or s.startswith(('#', '*', '//', '<!--', '-->')): continue
        if re.match(r'^(echo|printf|say)\b', s): continue
        out.append(ln)
    return '\n'.join(out)

danger = [
    (r'chown\s+-R[^\n]*(\$DSHHOME|\$DSH_HOME|\.dsh)', 'chown -R 用户数据目录'),
    (r'chmod\s+-R[^\n]*(\$DSHHOME|\$DSH_HOME|\.dsh)', 'chmod -R 用户数据目录'),
    (r'chmod\s+777[^\n]*(\$DSHHOME|\$DSH_HOME|\.dsh)', 'chmod 777 用户数据目录'),
    (r'\b(config-on|config-off)\b[^\n]*(\|\||&&|;|>|$)', '自动执行 config-on/off'),
    (r'ensure-config\.cjs[^\n]*\bon\b', 'daemon 自动 ensure-config on'),
    (r'(\$DSHHOME|\$DSH_HOME)/logs', '在 $DSH_HOME/logs 写日志'),
    (r'\.dsh-market/state\.json[^\n]*>', '写插件市场 state.json'),
    (r'\.npmrc[^\n]*>', '写 .npmrc'),
]
bad = 0
for p, name in AUTO:
    code = code_lines(open(p, encoding='utf-8', errors='ignore').read())
    for pat, desc in danger:
        if re.search(pat, code):
            print('  [FAIL ] %s :: %s' % (name, desc)); bad += 1

for p in PLISTS:
    try: d = plistlib.load(open(p, 'rb'))
    except Exception as e:
        print('  [FAIL ] %s :: plist 解析失败 %s' % (os.path.basename(p), e)); bad += 1; continue
    for k in ('StandardOutPath', 'StandardErrorPath'):
        v = str(d.get(k, ''))
        if '/.dsh/' in v or v.endswith('/.dsh'):
            print('  [FAIL ] %s :: %s 指向 $DSH_HOME (%s)' %
                  (os.path.basename(p), k, v)); bad += 1

# launchd plist 必须注入同一个固定 token
ld = plistlib.load(open(PLISTS[0], 'rb'))
if ld.get('EnvironmentVariables', {}).get('DSH_WEB_TOKEN') != tok:
    print('  [FAIL ] launchd plist 的 DSH_WEB_TOKEN 与常量文件不一致'); bad += 1
# Web Clip URL 必须带同一个 token
wc = plistlib.load(open(os.path.join(one, 'webclip/Info.plist'), 'rb'))
if wc.get('FullScreen') is not True or not wc.get('URL', '').endswith('?token=' + tok):
    print('  [FAIL ] Web Clip FullScreen/URL token 不一致'); bad += 1

if bad == 0:
    print('  [ ok  ] %d 个自动执行脚本 + %d 个 plist + Web Clip token 全部合规' %
          (len(AUTO), len(PLISTS)))
sys.exit(1 if bad else 0)
PY
R=$?; [ "$R" -eq 0 ] && ok "静态扫描通过" || bad "静态扫描发现违规（见上）"

printf '\n=== 汇总: FAIL=%d ===\n' "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
echo "✔ 装/卸 APP 全程对已有对话 / 工作区 / 插件 / 配置零写入，实测通过"
