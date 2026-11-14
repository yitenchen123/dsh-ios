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
# 版本标签：默认 ios18（Node 22.12.0 稳定档，逐字节保持已发布产物）。
# 用 CI 编出的 Node 24 时显式传 DSH_IOS_TAG=ios24，产出并列实验档，
# 绝不覆盖 +ios18 交付物，也不改仓库里的 control 原文件。
TAG="${DSH_IOS_TAG:-ios18}"

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
# 显式 NODE_IOS_BIN 必须优先于 bundles 里的默认 22.12.0：rc.3 的
# engines.node >= 24.9.0 且 bin.js 用 import.meta.main（Node 24 才支持），
# 用 CI 编出的 24.x 时若被旧版覆盖，包会「装得上但起不来」。
if [ ! -f "$ENGINE/bin/node" ]; then
    NODE_SRC=""
    for p in "${NODE_IOS_BIN:-}" "$ROOT/bundles/node-v22.12.0-iphoneos-arm64"; do
        [ -n "$p" ] && [ -f "$p" ] && { NODE_SRC="$p"; break; }
    done
    [ -n "$NODE_SRC" ] || {
        echo "缺少内置 node 二进制。请先跑 sh bootstrap.sh，或 NODE_IOS_BIN=/path 指定。" >&2
        echo "（绝不能省：daemon 要 exec /var/jb/usr/bin/dsh -> 包内 node）" >&2
        exit 1; }
    mkdir -p "$ENGINE/bin"; cp "$NODE_SRC" "$ENGINE/bin/node"
    echo "    内置 node: $NODE_SRC"
fi
# 无论来源都做 Mach-O + 大小校验，防止 x86 / 截断 / 占位文件混进包
NB="$ENGINE/bin/node"
NMAGIC=$(od -An -tx1 -N4 "$NB" 2>/dev/null | tr -d ' \n')
[ "$NMAGIC" = "cffaedfe" ] || { echo "内置 node 不是 arm64 Mach-O (magic=$NMAGIC)" >&2; exit 1; }
[ "$(wc -c < "$NB" | tr -d '[:space:]')" -gt 20000000 ] || {
    echo "内置 node 疑似占位/截断文件" >&2; exit 1; }
echo "    内置 node OK（arm64 Mach-O, $(wc -c < "$NB" | tr -d '[:space:]') 字节）"

# ---------------------------------------------------------------- 2) iOS 补丁
# 单包必须打与稳定底座 build.sh 完全相同的全套兼容补丁。历史缺陷：
# 本脚本只把 shims/*.cjs 复制进包（3c），却一个都没执行，于是 rc.3 的
# 引擎树是「裸」的 —— 真机上表现为：
#   * 插件市场索引 fetch(url,{redirect:"error"}) 遇到 CDN 跳转直接失败，
#     且 parseIndexInWorker() 起子 Worker 在 A11 上 SIGBUS -> 全部 fetch failed；
#   * dsh plugin 子进程找不到 pnpm / 裸 execa("git") 预检 -> 安装失败；
#   * 前端 index.html 没注入 safari16-polyfill.js，iOS 16.7(Safari 16.6)
#     缺 AbortSignal.any -> 工作区目录弹窗直接抛 "is not a function"。
# 补丁全部幂等，且带「锚点未精确命中即中止」断言，绝不打出未验证的包。
NM="$ENGINE/node_modules"
FRONT="$NM/@deepseek-ai/dsh-web-frontend/dist"
[ -f "$FRONT/index.html" ] || { echo "引擎树缺前端 dist/index.html: $FRONT" >&2; exit 1; }

# [1/6] 是 Node 22.12 专用兼容补丁（补 import.meta.main / zstd /
# stripTypeScriptTypes，并把新会话默认压缩 zstd 改成 none）。Node 24 原生
# 支持这些 API，且 +ios24 已实证「裸引擎就能把 Web UI 跑起来」，此时打它
# 只会无谓改动已验证的组合（还改新会话压缩格式）。因此按包内 node 的
# 真实主版本分流：>=24 跳过，22.x 必打。
NVER=$(strings "$NB" 2>/dev/null | grep -m1 -oE '^v2[0-9]+\.[0-9]+\.[0-9]+$' || true)
NMAJOR=$(printf '%s' "$NVER" | sed -E 's/^v([0-9]+)\..*/\1/')
case "$NMAJOR" in ''|*[!0-9]*) NMAJOR=0 ;; esac
if [ "$NMAJOR" -ge 24 ]; then
    echo "==> [1/6] 跳过 Node 22 兼容补丁（内置 node ${NVER:-v24.x} 原生支持，保持已验证组合）"
else
    echo "==> [1/6] 应用 Node 22 兼容补丁（内置 node ${NVER:-v22.12.0}）"
    python3 "$ROOT/shims/apply_compat_patches.py" "$NM" || exit 1
fi

echo "==> [2/6] pnpm 绝对路径直连（修真机 dsh plugin 127 / SIGBUS）"
PM="$NM/@deepseek-ai/dsh-plugin-manager/lib"
node "$ROOT/shims/apply_pnpm_abs_patch.cjs" "$PM" || exit 1
node --check "$PM/index.js" || { echo "补丁后 index.js 语法错误" >&2; exit 1; }
node --check "$PM/types/operations.js" || { echo "补丁后 operations.js 语法错误" >&2; exit 1; }

echo "==> [3/6] 插件安装 / 插件市场全链路（git 预检短路 + 主线程解析 + redirect follow + 手动转化钩子）"
# 必须用单包专用副本：共享 shims/apply_plugin_install_patch.cjs 会被
# make_fix_ios15.py 内嵌进 fix-ios15.sh、进而打进稳定底座 deb。为 rc.3
# 改它会连锁改变稳定底座 SHA（违反「稳定包逐字节不动」）。这份副本额外
# 支持 rc.3 client.js 的 minify bundle 锚点，A/B 段与共享 shim 完全一致。
node "$HERE/apply_plugin_install_patch_rc3.cjs" "$NM" || exit 1
for f in "@deepseek-ai/dsh-plugin-manager/lib/index.js" \
         "@deepseek-ai/dsh-plugin-market/lib/index.js" \
         "@deepseek-ai/dsh-plugin-market/lib/worker-parse.cjs" \
         "@deepseek-ai/dsh-client-ui-plugin-manager/lib/client.js"; do
    node --check "$NM/$f" || { echo "补丁后 $f 语法错误" >&2; exit 1; }
done

echo "==> [4/6] 注入 Safari 16.7 前端垫片 + 手动安装转化逻辑"
node "$ROOT/shims/apply_frontend_inject.cjs" \
    "$FRONT" \
    "$ROOT/shims/safari16-polyfill.js" \
    "$ROOT/shims/dsh-ios-manual-install-transform.js" || exit 1
for m in 'safari16-polyfill.js' 'dsh-ios-manual-install-transform.js'; do
    grep -q "$m" "$FRONT/index.html" || { echo "构建中止：index.html 缺 $m 引用" >&2; exit 1; }
    [ -f "$FRONT/assets/$m" ] || { echo "构建中止：缺 assets/$m" >&2; exit 1; }
    node --check "$FRONT/assets/$m" || { echo "构建中止：assets/$m 语法错误" >&2; exit 1; }
done

echo "==> [5/6] 内置纯 JS pnpm（让「安装插件前需配置 pnpm 环境」不再出现）"
PNPMSRC="$ROOT/bundles/pnpm"
if [ ! -f "$PNPMSRC/bin/pnpm.cjs" ] || [ ! -f "$PNPMSRC/dist/pnpm.cjs" ]; then
    echo "缺少内置 pnpm: $PNPMSRC（插件安装必须有它）" >&2; exit 1
fi
mkdir -p "$ENGINE/libexec"
cp -a "$PNPMSRC" "$ENGINE/libexec/pnpm"
[ "$(find "$ENGINE/libexec/pnpm" -name '*.node' | wc -l)" -eq 0 ] || {
    echo "构建中止：内置 pnpm 含原生 .node（iOS 无法加载）" >&2; exit 1; }

echo "==> [6/6] 应用固定 loopback token 补丁（rc.3 静态 URL 鉴权）"
node "$ROOT/shims/apply_fixed_token_patch.cjs" "$NM" || exit 1
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

# rc.3 前端「生态插件转化」钩子已由 [3/6] 的 apply_plugin_install_patch.cjs
# 通过「源码 / minify bundle 双锚点」通用注入，不再依赖外部成品替换。
# 构建期强校验：四处补丁真正落到引擎树，绝不打出「脚本在包里但没执行」的裸树。
for spec in \
  "@deepseek-ai/dsh-web-frontend/dist/assets/safari16-polyfill.js|AbortSignal.any" \
  "@deepseek-ai/dsh-web-frontend/dist/assets/dsh-ios-manual-install-transform.js|__dshIosTransformSpec" \
  "@deepseek-ai/dsh-plugin-manager/lib/index.js|git-probe-shortcircuit" \
  "@deepseek-ai/dsh-plugin-market/lib/index.js|redirect: \"follow\"" \
  "@deepseek-ai/dsh-client-ui-plugin-manager/lib/client.js|__dshIosTransformSpec"; do
    rel=${spec%%|*}; needle=${spec#*|}
    [ -f "$NM/$rel" ] || { echo "构建中止：补丁产物缺失 $rel" >&2; exit 1; }
    grep -qF "$needle" "$NM/$rel" || { echo "构建中止：$rel 缺 $needle（补丁未生效）" >&2; exit 1; }
done
[ -f "$NM/@deepseek-ai/dsh-plugin-market/lib/worker-parse.cjs" ] || {
    echo "构建中止：worker-parse.cjs 未派生" >&2; exit 1; }
grep -q 'safari16-polyfill.js' "$FRONT/index.html" || { echo "构建中止：index.html 未注入垫片" >&2; exit 1; }
echo "    补丁链校验通过：垫片注入 / 插件市场 / git 预检 / pnpm / 转化钩子 / 固定 token"

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
         apply_pnpm_abs_patch.cjs \
         apply_frontend_inject.cjs apply_fixed_token_patch.cjs \
         safari16-polyfill.js dsh-ios-manual-install-transform.js; do
    [ -f "$ROOT/shims/$f" ] || { echo "缺少 shims/$f" >&2; exit 1; }
    cp "$ROOT/shims/$f" "$STAGE/var/jb/usr/lib/dsh/$f"
done
# apply_plugin_install_patch.cjs 用单包专用副本：设备端 dsh-doctor 热修在
# rc.3 树上重跑时也需要支持 minify bundle 锚点，否则会命中 0 次失败。
# 文件名保持不变，doctor 的调用路径不用改。
cp "$HERE/apply_plugin_install_patch_rc3.cjs" \
   "$STAGE/var/jb/usr/lib/dsh/apply_plugin_install_patch.cjs"
node --check "$STAGE/var/jb/usr/lib/dsh/apply_plugin_install_patch.cjs" || {
    echo "构建中止：单包专用插件补丁语法错误" >&2; exit 1; }

# 3d APP payload（Info.plist / entitlements / LaunchDaemon / dsh-app-* 脚本）
cp -a "$APPDIR/." "$STAGE/"

# 3d-2 单包只保留「一个全屏入口」。native DSH.app 用的是
# SFSafariViewController，永远带 Safari 顶栏/底栏/关闭按钮（真机截图
# "127.0.0.1 / 关闭 / 大小"），与用户要求的「和官方 App 一样全屏」冲突。
# 真全屏的是 FullScreen=true 的 Web Clip（3f）。这里给 native APP 注入
# SBAppTags=hidden 让 SpringBoard 不再显示它，并改个不混淆的名字；APP 文件
# 本身保留（终端 dsh-app-ctl ensure / 兜底仍可用），但不再是点开的入口。
# 只改 stage 内的副本，app-bundle 独立包的源 Info.plist 一个字节不动。
python3 - "$STAGE/var/jb/Applications/DSH.app/Info.plist" <<'PY'
import plistlib, sys
p = sys.argv[1]
d = plistlib.load(open(p, 'rb'))
d['SBAppTags'] = ['hidden']
d['CFBundleDisplayName'] = 'DSH (Safari fallback)'
with open(p, 'wb') as f:
    plistlib.dump(d, f, sort_keys=False)
print('    native APP 已标记隐藏，桌面主入口 = 全屏 Web Clip')
PY

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
# 并列实验档（如 Node 24）只改 stage 内 control 的 Version，仓库原文件
# 不动；默认 ios18 时一字不改，保证已发布产物逐字节可复现。
if [ "$TAG" != "ios18" ]; then
    sed "s/^Version: .*/Version: 0.2.2-rc.3+${TAG}/" \
        "$HERE/DEBIAN/control" > "$STAGE/DEBIAN/control"
    echo "    版本标签: +$TAG（并列实验档，不覆盖 +ios18）"
fi
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
  "$STAGE/var/jb/usr/lib/dsh/libexec/pnpm/bin/pnpm.cjs" \
  "$STAGE/var/jb/usr/lib/dsh/libexec/pnpm/dist/pnpm.cjs" \
  "$STAGE/var/jb/usr/lib/dsh/node_modules/@deepseek-ai/dsh/lib/bin.js" \
  "$STAGE/var/jb/usr/lib/dsh/node_modules/@deepseek-ai/dsh-client-connection/lib/index.js" \
  "$STAGE/var/jb/usr/lib/dsh/node_modules/@deepseek-ai/dsh-web-frontend/dist/assets/safari16-polyfill.js" \
  "$STAGE/var/jb/usr/lib/dsh/node_modules/@deepseek-ai/dsh-web-frontend/dist/assets/dsh-ios-manual-install-transform.js" \
  "$STAGE/var/jb/usr/lib/dsh/node_modules/@deepseek-ai/dsh-plugin-market/lib/worker-parse.cjs" \
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
