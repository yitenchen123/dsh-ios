#!/bin/sh
# 单包构建：rc.3 引擎树 + native APP + **真全屏 Web Clip** + extras -> 一个 deb
#
# 用法: sh build-one-package.sh <引擎树目录 | rc3 bundle .tar.gz> <APP payload 目录> [输出.deb]
#   引擎树目录需含 node_modules/（可选 bin/node）；bundle 顶层为 node_modules/。
#   内置 node 二进制优先取引擎树的 bin/node，其次 bundles/node-v22.12.0-iphoneos-arm64
#   （由 bootstrap.sh 下载），也可 NODE_IOS_BIN=/path 指定。缺则直接中止，绝不
#   产出「装得上但起不来」的残包。
#
# 旧版断裂点（本脚本逐一补齐）：
#   * 没复制 dsh-extras-postinst.sh / prerm.sh -> postinst 的 `[ -x "$EX" ]`
#     恒为假，全屏 Web Clip 从来没装进设备；
#   * 没复制 prebuilt/DSHLauncher / dsh-app-helper / 图标 -> .app 空壳；
#   * 没复制根 payload 的 usr/bin/dsh 等 wrapper -> daemon 要 exec 的文件
#     根本不在包里；
#   * 没调用固定 token 补丁 / rc.3 transform 补丁；
#   * 没有 chown 0:0 / SOURCE_DATE_EPOCH / -z9，不可复现。
set -eu

ENGINE_IN="${1:?engine tree dir or rc3 bundle .tar.gz}"
APPDIR="${2:?app payload dir (app-bundle/payload)}"
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT=$(CDPATH= cd -- "$HERE/.." && pwd)
OUT="${3:-$ROOT/dist/dev.airdevs.dsh_0.2.2-rc.3+ios18_iphoneos-arm64.deb}"
TOKEN=$(tr -d '\r\n' < "$HERE/dsh-web-token")
SDE="${SOURCE_DATE_EPOCH:-1700000000}"

for c in python3 node dpkg-deb sha256sum tar; do
    command -v "$c" >/dev/null 2>&1 || { echo "缺少 $c" >&2; exit 1; }
done
[ -n "$TOKEN" ] || { echo "one-package/dsh-web-token 为空" >&2; exit 1; }
[ -f "$APPDIR/var/jb/Applications/DSH.app/Info.plist" ] || { echo "APP payload 不对: $APPDIR" >&2; exit 1; }

WORK="$ROOT/.build/one-package"
STAGE="$WORK/stage"
ENGINE="$WORK/engine"
rm -rf "$WORK"; mkdir -p "$STAGE" "$ENGINE"
trap 'rm -rf "$WORK"' EXIT INT TERM

# ---------------------------------------------------------------- 0) 令牌一致性
# 四处必须逐字相同：dsh-web-token / Web Clip URL / launchd plist /
# apply_fixed_token_patch.cjs 缺省值。任一漂移都会让静态 URL 401。
echo "==> 校验固定 token 一致性 ($TOKEN)"
python3 - "$HERE/webclip/Info.plist" \
          "$APPDIR/var/jb/Library/LaunchDaemons/dev.airdevs.dsh.plist" \
          "$ROOT/shims/apply_fixed_token_patch.cjs" "$TOKEN" <<'PY'
import plistlib, sys
wc, ld, patch, tok = sys.argv[1:5]
d = plistlib.load(open(wc, 'rb'))
assert d.get('FullScreen') is True, 'Web Clip 不是 FullScreen'
assert d.get('URL', '').endswith('?token=' + tok), 'Web Clip URL 的 token 与 dsh-web-token 不一致'
l = plistlib.load(open(ld, 'rb'))
assert l.get('EnvironmentVariables', {}).get('DSH_WEB_TOKEN') == tok, 'launchd plist 未注入同一个 token'
assert '/var/jb/var/log/dsh-app/' in l.get('StandardOutPath', ''), 'daemon 日志仍写在 $DSH_HOME'
s = open(patch, encoding='utf-8').read()
assert ('"'+tok+'"') in s, '固定 token 补丁的缺省值与 dsh-web-token 不一致'
print('    Web Clip / plist / 补丁 / 常量文件 四处一致')
PY

# ---------------------------------------------------------------- 1) 引擎树
if [ -f "$ENGINE_IN" ]; then
    echo "==> 解包 rc.3 依赖树: $(basename "$ENGINE_IN")"
    tar xzf "$ENGINE_IN" -C "$ENGINE"
elif [ -d "$ENGINE_IN" ]; then
    echo "==> 复制引擎树: $ENGINE_IN"
    cp -a "$ENGINE_IN/." "$ENGINE/"
else
    echo "引擎树不存在: $ENGINE_IN" >&2; exit 1
fi
[ -d "$ENGINE/node_modules/@deepseek-ai/dsh" ] || { echo "引擎树缺 node_modules/@deepseek-ai/dsh" >&2; exit 1; }

# 内置 node 二进制（daemon/cli 的真实执行者）
if [ ! -f "$ENGINE/bin/node" ]; then
    NODE_SRC=""
    for p in "$ROOT/bundles/node-v22.12.0-iphoneos-arm64" "${NODE_IOS_BIN:-}"; do
        [ -n "$p" ] && [ -f "$p" ] && { NODE_SRC="$p"; break; }
    done
    [ -n "$NODE_SRC" ] || {
        echo "缺少内置 node 二进制。请先跑 sh bootstrap.sh，或 NODE_IOS_BIN=/path 指定。" >&2
        echo "（绝不能省：daemon 要 exec /var/jb/usr/bin/dsh -> 包内 node）" >&2
        exit 1; }
    mkdir -p "$ENGINE/bin"; cp "$NODE_SRC" "$ENGINE/bin/node"
    echo "    内置 node: $NODE_SRC"
fi

# ---------------------------------------------------------------- 2) iOS 补丁
echo "==> 应用固定 loopback token 补丁（rc.3 静态 URL 鉴权）"
node "$ROOT/shims/apply_fixed_token_patch.cjs" "$ENGINE/node_modules" || exit 1
python3 - "$ENGINE/node_modules" "$TOKEN" <<'PY'
import os, sys
root, tok = sys.argv[1:3]
hits = 0
for dp, dns, fns in os.walk(root):
    for n in fns:
        p = os.path.join(dp, n)
        if p.replace('\\', '/').endswith('dsh-client-connection/lib/index.js'):
            s = open(p, encoding='utf-8').read()
            assert 'process.env.DSH_WEB_TOKEN' in s, '未打补丁: ' + p
            assert ('"'+tok+'"') in s, '缺省 token 不一致: ' + p
            hits += 1
assert hits >= 1, '没有任何 dsh-client-connection/lib/index.js 被打补丁'
print('    已打补丁文件: %d' % hits)
PY
for f in $(find "$ENGINE/node_modules" -path '*dsh-client-connection/lib/index.js'); do
    node --check "$f" || { echo "补丁后 $f 语法错误" >&2; exit 1; }
done

# rc.3 前端「生态插件转化」钩子：上游 client.js 锚点与 +ios15 补丁不一致，
# 用已验证的成品替换。提供了 DSH_RC3_CLIENT 才执行；没提供则明确标注跳过，
# 不影响 Web UI / 插件 / 工作区 / 对话的加载主链。
if [ -n "${DSH_RC3_CLIENT:-}" ] && [ -f "$DSH_RC3_CLIENT" ]; then
    echo "==> 应用 rc.3 前端 manual-install transform"
    sh "$HERE/patch-rc3-client-transform.sh" "$DSH_RC3_CLIENT" "$ENGINE/node_modules" || exit 1
else
    echo "    [note] 未指定 DSH_RC3_CLIENT，跳过前端转化钩子（主加载链不受影响）"
fi

# ---------------------------------------------------------------- 3) 组装 stage
echo "==> 组装 stage"
mkdir -p "$STAGE/DEBIAN" "$STAGE/var/jb/usr/lib/dsh" "$STAGE/var/jb/usr/bin" \
         "$STAGE/var/jb/etc/dsh" "$STAGE/var/jb/Applications/DSH.app" \
         "$STAGE/var/jb/Library/LaunchDaemons"

# 3a 引擎树（node_modules + bin/node + 可选 libexec）
cp -a "$ENGINE/." "$STAGE/var/jb/usr/lib/dsh/"

# 3b 根 payload：wrapper / doctor / pnpm / 档位链 / 环境文件
cp -a "$ROOT/payload/var/jb/usr/bin/." "$STAGE/var/jb/usr/bin/"
cp -a "$ROOT/payload/var/jb/etc/dsh/." "$STAGE/var/jb/etc/dsh/"
cp -a "$ROOT/payload/var/jb/usr/lib/dsh/." "$STAGE/var/jb/usr/lib/dsh/"
cp "$ROOT/ent.plist" "$STAGE/var/jb/usr/lib/dsh/ent.plist"

# 3c 设备端运行时/热修脚本（dsh wrapper 与 doctor 会用到）
for f in fetch-shim.cjs dsh-home-heal.cjs dsh-plugin-compat.cjs \
         apply_pnpm_abs_patch.cjs apply_plugin_install_patch.cjs \
         apply_frontend_inject.cjs apply_fixed_token_patch.cjs \
         safari16-polyfill.js dsh-ios-manual-install-transform.js; do
    [ -f "$ROOT/shims/$f" ] || { echo "缺少 shims/$f" >&2; exit 1; }
    cp "$ROOT/shims/$f" "$STAGE/var/jb/usr/lib/dsh/$f"
done

# 3d APP payload（Info.plist / entitlements / LaunchDaemon / dsh-app-* 脚本）
cp -a "$APPDIR/." "$STAGE/"

# 3e prebuilt 可执行 + setuid helper + 图标
APPB="$ROOT/app-bundle"
cp "$APPB/prebuilt/DSHLauncher"     "$STAGE/var/jb/Applications/DSH.app/DSHLauncher"
cp "$APPB/prebuilt/dsh-app-helper"  "$STAGE/var/jb/usr/bin/dsh-app-helper"
python3 "$APPB/make_app_icon.py" "$STAGE/var/jb/Applications/DSH.app" | sed 's/^/    /'

# 3f 全屏 Web Clip（真正装进设备的那一份）
mkdir -p "$STAGE/var/jb/usr/lib/dsh/webclip"
cp "$HERE/webclip/Info.plist" "$STAGE/var/jb/usr/lib/dsh/webclip/Info.plist"
cp "$HERE/webclip/icon.png"   "$STAGE/var/jb/usr/lib/dsh/webclip/icon.png"

# 3g extras 必须进包 —— 旧版漏在这里，导致全屏入口从未安装
cp "$HERE/dsh-extras-postinst.sh" "$STAGE/var/jb/usr/lib/dsh/dsh-extras-postinst.sh"
cp "$HERE/dsh-extras-prerm.sh"   "$STAGE/var/jb/usr/lib/dsh/dsh-extras-prerm.sh"
chmod 755 "$STAGE/var/jb/usr/lib/dsh/dsh-extras-postinst.sh" \
          "$STAGE/var/jb/usr/lib/dsh/dsh-extras-prerm.sh"

# 3h DEBIAN
cp -a "$HERE/DEBIAN/." "$STAGE/DEBIAN/"
chmod 755 "$STAGE/DEBIAN/postinst" "$STAGE/DEBIAN/prerm"

# ---------------------------------------------------------------- 4) 完整性断言
echo "==> 构建期完整性断言"
for f in \
  "$STAGE/var/jb/usr/bin/dsh" \
  "$STAGE/var/jb/usr/bin/dsh-doctor" \
  "$STAGE/var/jb/usr/bin/dsh-daemon" \
  "$STAGE/var/jb/usr/bin/dsh-app-ctl" \
  "$STAGE/var/jb/usr/bin/dsh-app-ui" \
  "$STAGE/var/jb/usr/bin/dsh-app-helper" \
  "$STAGE/var/jb/usr/lib/dsh/bin/node" \
  "$STAGE/var/jb/usr/lib/dsh/node_modules/@deepseek-ai/dsh/lib/bin.js" \
  "$STAGE/var/jb/usr/lib/dsh/node_modules/@deepseek-ai/dsh-client-connection/lib/index.js" \
  "$STAGE/var/jb/usr/lib/dsh/dsh-extras-postinst.sh" \
  "$STAGE/var/jb/usr/lib/dsh/dsh-extras-prerm.sh" \
  "$STAGE/var/jb/usr/lib/dsh/webclip/Info.plist" \
  "$STAGE/var/jb/usr/lib/dsh/webclip/icon.png" \
  "$STAGE/var/jb/Applications/DSH.app/DSHLauncher" \
  "$STAGE/var/jb/Applications/DSH.app/Info.plist" \
  "$STAGE/var/jb/Applications/DSH.app/entitlements.plist" \
  "$STAGE/var/jb/Library/LaunchDaemons/dev.airdevs.dsh.plist" \
  "$STAGE/DEBIAN/postinst" "$STAGE/DEBIAN/prerm" "$STAGE/DEBIAN/control"; do
    [ -e "$f" ] || { echo "构建中止：缺 $f" >&2; exit 1; }
done
for f in "$STAGE/var/jb/usr/bin/dsh" "$STAGE/var/jb/usr/bin/dsh-daemon" \
         "$STAGE/var/jb/usr/bin/dsh-app-ctl" "$STAGE/var/jb/usr/bin/dsh-app-ui" \
         "$STAGE/var/jb/usr/lib/dsh/dsh-extras-postinst.sh" \
         "$STAGE/var/jb/usr/lib/dsh/dsh-extras-prerm.sh" \
         "$STAGE/DEBIAN/postinst" "$STAGE/DEBIAN/prerm"; do
    sh -n "$f" || { echo "$f 语法错误" >&2; exit 1; }
done
# daemon 必须真的 exec dsh web，且不得写 $DSH_HOME
grep -q 'web --no-open --port' "$STAGE/var/jb/usr/bin/dsh-daemon" || { echo "daemon 未 exec web" >&2; exit 1; }

# ---------------------------------------------------------------- 5) 可复现归一化
echo "==> 固定 mode / mtime / 属主（SOURCE_DATE_EPOCH=$SDE）"
python3 - "$STAGE" <<'PY'
import os, sys
root = sys.argv[1]
for dp, dns, fns in os.walk(root):
    os.chmod(dp, 0o755)
    for n in fns:
        p = os.path.join(dp, n)
        if os.path.islink(p):
            continue
        m = os.stat(p).st_mode
        os.chmod(p, 0o755 if (m & 0o100) else 0o644)
PY
# 顺序很重要：chown(2) 会清掉 setuid/setgid 位，所以 4755 必须在
# chown -R 0:0 之后再设。旧版两个构建脚本都在 chown 之前设 4755，
# 结果 helper 实际是 755 —— App 以 mobile 身份执行它时无法 bootstrap
# launchd daemon，点图标根本起不来服务。
chown -R 0:0 "$STAGE" 2>/dev/null || true
chmod 755 "$STAGE/var/jb/Applications/DSH.app/DSHLauncher" \
          "$STAGE/var/jb/usr/bin/dsh" "$STAGE/var/jb/usr/bin/dsh-doctor" \
          "$STAGE/var/jb/usr/bin/dsh-daemon" "$STAGE/var/jb/usr/bin/dsh-app-ctl" \
          "$STAGE/var/jb/usr/bin/dsh-app-ui" "$STAGE/var/jb/usr/bin/pnpm" \
          "$STAGE/var/jb/usr/bin/dsh-compat" \
          "$STAGE/var/jb/usr/lib/dsh/dsh-extras-postinst.sh" \
          "$STAGE/var/jb/usr/lib/dsh/dsh-extras-prerm.sh" \
          "$STAGE/DEBIAN/postinst" "$STAGE/DEBIAN/prerm"
chmod 4755 "$STAGE/var/jb/usr/bin/dsh-app-helper"
find "$STAGE" -depth -exec touch -h -d "@$SDE" {} + 2>/dev/null || \
    find "$STAGE" -depth -exec touch -h -t 202311142013.20 {} + 2>/dev/null || true

# ---------------------------------------------------------------- 6) 打包
mkdir -p "$(dirname "$OUT")"
rm -f "$OUT"
echo "==> dpkg-deb 组装（-Zgzip -z9，可复现）"
SOURCE_DATE_EPOCH="$SDE" dpkg-deb -b -Zgzip -z9 "$STAGE" "$OUT" >/dev/null
echo "==> 产物"
echo "    $(du -h "$OUT" | cut -f1)  $OUT"
sha256sum "$OUT" | sed 's/^/    /'
