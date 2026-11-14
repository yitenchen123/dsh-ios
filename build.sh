#!/bin/sh
# build.sh —— 在 Linux/macOS 上组装 rootless .deb（iphoneos-arm64）
#
# 产物: dist/dev.airdevs.dsh_<DSH_VER><IOS_TAG>_iphoneos-arm64.deb
#   默认 0.2.1-rc.5+ios15（真机 100% 验证过的稳定底座）
#   DSH_VER=0.2.2-rc.1 sh build.sh  → 0.2.2-rc.1+ios16（最新版 DSH 升级包，
#   同一套 dsh-iOS 补丁，已过 verify-022.sh 31 项核验）
# 需求: python3, dpkg-deb, sha256sum；node 仅用于构建期补丁脚本/语法自检
# 注意: 只在构建机跑，不在 iPhone 上跑；二进制与依赖树均随包固化，全程离线。
# 可复现: 所有 stage 文件固定 mtime + SOURCE_DATE_EPOCH，dpkg-deb -Zgzip -z9，
#         连续构建 SHA-256 完全一致（见 verify-repro.sh）。
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
DSH_VER="${DSH_VER:-0.2.1-rc.5}"
# 版本 → +ios 轮次标记。两个版本共用同一套补丁链路，只换依赖树离线 bundle。
case "$DSH_VER" in
    0.2.1-rc.5) IOS_TAG="+ios15"; FIX_NAME="fix-ios15.sh" ;;
    0.2.2-rc.1) IOS_TAG="+ios16"; FIX_NAME="fix-ios16.sh" ;;
    0.2.2-rc.3)
        cat >&2 <<'EOF'
DSH_VER=0.2.2-rc.3 走 one-package 单包构建链，不在 build.sh 的稳定链里。
原因：rc.3 是 pnpm 隔离布局且上游 client.js 锚点变化，+ios15 补丁链无法
直接命中；而 0.2.1-rc.5 稳定底座的 deb 必须与已发布 Release 逐字节一致，
不能为了加 rc.3 支持而改动 build.sh 的输出。

最新 DSH + 全屏 App 请执行：
    sh one-package/build-one-package.sh \
        bundles/dsh-nodemodules-0.2.2-rc.3+ios1.tar.gz \
        app-bundle/payload \
        dist/dev.airdevs.dsh_0.2.2-rc.3+ios18_iphoneos-arm64.deb
    sh one-package/verify-one-package.sh <deb>
EOF
        exit 2 ;;
    *) echo "不支持的 DSH_VER: $DSH_VER（可用 0.2.1-rc.5 / 0.2.2-rc.1；rc.3 见 one-package/）" >&2; exit 1 ;;
esac
# bootstrap.sh / verify-repro.sh 等子进程必须看到同一版本，才能下对 bundle。
export DSH_VER
# 内置 node：davghz/node22-ios-source 的 v22.12.0，静态链接纯 arm64、标准
# MAP_JIT、自带完整 JIT entitlements，上游 README 明确标注测试机为
# "iPhone X (iPhone10,3), iOS 13.2.3" —— 与目标机同款 A11 芯片，真机测过
# JS eval/loop 与 WebAssembly 编译执行。二进制已固化进 bundles/，构建完全离线、
# 字节级可复现，不再依赖 GitHub release（那个为 A9/无 APRR 打 mprotect W^X
# 补丁的 openclaw v22.19.0 在 A11 上 V8 初始化即 SIGBUS，已弃用）。
NODE_VER=22.12.0
NODE_SHA=f091585d9e3d63b2d8be1fadc17068a21d42d6b2912304462b8dca41a8cfc163
NODE_SIZE=101297040
WORK="$ROOT/.build"
STAGE="$WORK/stage"
DST="$ROOT/dist"
# 压缩方式：默认 gzip（原大小，兼容性最好）；DEB_COMP=xz 可显著减小体积
COMP="${DEB_COMP:-gzip}"
case "$COMP" in
    xz) ZARGS="-Zxz -z9";  SUF="${IOS_TAG}xz" ;;
    *)  ZARGS="-Zgzip -z9"; SUF="$IOS_TAG" ;;
esac
OUT="$DST/dev.airdevs.dsh_${DSH_VER}${SUF}_iphoneos-arm64.deb"
echo "==> 构建目标: dsh ${DSH_VER}${IOS_TAG} -> $(basename "$OUT")"

for c in python3 dpkg-deb sha256sum; do command -v "$c" >/dev/null 2>&1 || { echo "缺少 $c" >&2; exit 1; }; done

# --- 0. 可复现构建前置：GitHub clone 后缺的大二进制自动 bootstrap ---
# 仓库 .gitignore 排除了 node 二进制 / 依赖树 bundle（超 GitHub 单文件限制），
# 它们作为 Release 附件公开。缺任一文件就自动下载 + SHA-256 校验，保证任何
# clone 都能 1:1 重建出与本地字节一致的 deb。DSH_SKIP_BOOTSTRAP=1 可跳过。
NEED_BOOTSTRAP=0
[ -f "$ROOT/bundles/node-v${NODE_VER}-iphoneos-arm64" ] || NEED_BOOTSTRAP=1
[ -f "$ROOT/bundles/dsh-nodemodules-${DSH_VER}+ios1.tar.gz" ] || NEED_BOOTSTRAP=1
if [ "$NEED_BOOTSTRAP" -eq 1 ] && [ "${DSH_SKIP_BOOTSTRAP:-0}" != "1" ]; then
    echo "==> 缺构建大文件，自动运行 bootstrap.sh（从 Release 下载并校验）"
    sh "$ROOT/bootstrap.sh" || exit 1
fi

echo "==> 清理 workspace"
rm -rf "$WORK"; mkdir -p "$WORK/npm" "$STAGE/var/jb/usr/bin" "$STAGE/var/jb/usr/lib/dsh/bin" "$STAGE/var/jb/etc/dsh" "$DST"

# --- 1. iOS arm64 Node 二进制（固化在 bundles/，离线可复现） ---
CACHE="${NODE_IOS_BIN:-$ROOT/bundles/node-v${NODE_VER}-iphoneos-arm64}"
if [ ! -f "$CACHE" ]; then
    echo "缺少内置 node: $CACHE" >&2
    echo "该二进制来自 davghz/node22-ios-source 的 nodejs22-ios_22.12.0-26_iphoneos-arm.deb" >&2
    echo "（取其中 usr/local/bin/node22），或设置 NODE_IOS_BIN=/path/to/node。" >&2
    exit 1
fi
# 完整性校验：大小 + SHA-256 + Mach-O 头三重，避免把错版/截断二进制打进包。
SZ=$(stat -c%s "$CACHE" 2>/dev/null || stat -f%z "$CACHE" 2>/dev/null || echo 0)
if [ "$SZ" -ne "$NODE_SIZE" ]; then
    echo "Node 二进制大小不符: $SZ / $NODE_SIZE 字节。" >&2; exit 1
fi
ACTUAL_SHA=$(sha256sum "$CACHE" | cut -d' ' -f1)
if [ "$ACTUAL_SHA" != "$NODE_SHA" ]; then
    echo "Node 二进制 SHA-256 不符: $ACTUAL_SHA" >&2
    echo "期望: $NODE_SHA" >&2; exit 1
fi
if ! head -c 4 "$CACHE" | od -An -tx1 | grep -qE 'cf fa ed fe|ce fa ed fe'; then
    echo "Node 二进制不是 Mach-O arm64。" >&2; exit 1
fi
echo "    node v${NODE_VER} 校验通过 ($SZ 字节, SHA $(printf '%s' "$ACTUAL_SHA" | cut -c1-12)…)"
cp "$CACHE" "$STAGE/var/jb/usr/lib/dsh/bin/node"
chmod 755 "$STAGE/var/jb/usr/lib/dsh/bin/node"

# --- 2. dsh 依赖树：优先用随包固化的离线 bundle ---
# 该 bundle 是「已实测通过」的那一份：@deepseek-ai/dsh@0.2.1-rc.5
# --omit=optional，打过两个纯 JS shim（替代 iOS 上不存在的原生 addon），
# 删光 .node/平台包/.d.ts/.map。用离线包可避开 npm 网络波动，字节级可复现。
BUNDLE="$ROOT/bundles/dsh-nodemodules-${DSH_VER}+ios1.tar.gz"
NM="$WORK/npm/node_modules"
if [ -f "$BUNDLE" ]; then
    echo "==> 解包已验证的离线依赖树: $(basename "$BUNDLE")"
    mkdir -p "$WORK/npm"
    tar xzf "$BUNDLE" -C "$WORK/npm"
else
    echo "==> 未找到离线 bundle，回退到 npm install --omit=optional"
    cd "$WORK/npm"
    printf '{"name":"dsh-ios-bundle","private":true,"version":"1.0.0"}\n' > package.json
    npm install --omit=optional --no-audit --no-fund --loglevel=error "@deepseek-ai/dsh@${DSH_VER}"
    echo "==> 应用纯 JS shim"
    cp "$ROOT/shims/node-addon-require-builtin__lib__index.js" \
       "$NM/node-addon-require-builtin/lib/index.js"
    cp "$ROOT/shims/node-addon-system__lib__flock.js" \
       "$NM/@deepseek-ai/node-addon-system/lib/flock.js"
    echo "==> 裁剪依赖树"
    find "$NM" -type f \( -name '*.node' -o -name '*.d.ts' -o -name '*.map' -o -name '*.d.cts' -o -name '*.d.mts' \) -delete 2>/dev/null || true
    find "$NM" -type d \( -name test -o -name tests -o -name __tests__ -o -name docs -o -name .github -o -name prebuilds \) -prune -exec rm -rf {} + 2>/dev/null || true
    find "$NM" -type f \( -iname 'readme*' -o -iname 'changelog*' -o -iname '*.md' \) -delete 2>/dev/null || true
    rm -rf "$NM"/@deepseek-ai/node-addon-system-*-* "$NM"/@img "$NM"/@koromix "$NM"/sherpa-onnx-* "$NM"/node-pty 2>/dev/null || true
fi

# --- 3. Node 22.12 兼容补丁（精确字符串替换，带断言；命中不了即中止） ---
# 内置 node 是 v22.12.0，缺 import.meta.main(22.14+)/zstd(22.15+)/
# stripTypeScriptTypes(22.13+)，以及 +ios9 把会话默认压缩从 zstd 改成 none。
# 前四是 ESM 链接期硬依赖 / 读写自洽问题，运行时补不了，必须改源码。
# 脚本在干净 bundle 上已实测：5 个插件全激活、web/headless 全通、会话重启可恢复。
echo "==> 应用 Node ${NODE_VER} 兼容补丁"
python3 "$ROOT/shims/apply_compat_patches.py" "$NM" || exit 1

# --- 3a. +ios14 pnpm 绝对路径直连（修真机 `dsh plugin` 127） ---
# dsh 的 CLI 与 web service 分属两份构建产物（lib/types/operations.js 用单引号、
# lib/index.js 用双引号），两者都以 execa('pnpm', ..., {extendEnv:false}) 启动
# pnpm。真机上 dsh 自造的 env 里 PATH 找不到 /var/jb/usr/bin，或 pnpm 的
# /usr/bin/env node shebang 解析失败 -> ENOENT -> 退出码 127。
# 这里把 command 改成包内 node 绝对路径、把 pnpm.cjs 绝对路径前置到 args，
# 彻底绕开 PATH / shebang。构建机需要 node 来跑这份 .cjs（必须步骤，不可跳过）。
command -v node >/dev/null 2>&1 || { echo "构建中止：需要 node 运行 apply_pnpm_abs_patch.cjs" >&2; exit 1; }
echo "==> 应用 +ios14 pnpm 绝对路径直连补丁（CLI + service）"
PM="$NM/@deepseek-ai/dsh-plugin-manager/lib"
node "$ROOT/shims/apply_pnpm_abs_patch.cjs" "$PM" || exit 1
node --check "$PM/index.js" || { echo "补丁后 index.js 语法错误" >&2; exit 1; }
node --check "$PM/types/operations.js" || { echo "补丁后 operations.js 语法错误" >&2; exit 1; }

# --- 3a2. +ios15 手动安装 / 插件市场全链路修复（构建期应用，幂等） ---
# 修三处真机故障：GitHub 仓库手动安装的裸 execa("git") 预检、插件市场的
# 子 Worker(SIGBUS) + redirect:"error"、以及 Web UI 手动安装 spec 转化钩子。
# 断言式补丁：任一模式未精确命中就中止，绝不打出未经验证的包。
echo "==> 应用 +ios15 插件安装 / 插件市场修复补丁"
node "$ROOT/shims/apply_plugin_install_patch.cjs" "$NM" || exit 1
for f in "@deepseek-ai/dsh-plugin-manager/lib/index.js" \
         "@deepseek-ai/dsh-plugin-market/lib/index.js" \
         "@deepseek-ai/dsh-plugin-market/lib/worker-parse.cjs" \
         "@deepseek-ai/dsh-client-ui-plugin-manager/lib/client.js"; do
    node --check "$NM/$f" || { echo "补丁后 $f 语法错误" >&2; exit 1; }
done
grep -q 'dsh-ios +ios15' "$NM/@deepseek-ai/dsh-plugin-manager/lib/index.js" || \
    { echo "构建中止：git 预检短路未生效" >&2; exit 1; }
grep -q 'redirect: "follow"' "$NM/@deepseek-ai/dsh-plugin-market/lib/index.js" || \
    { echo "构建中止：插件市场 redirect follow 未生效" >&2; exit 1; }
[ -f "$NM/@deepseek-ai/dsh-plugin-market/lib/worker-parse.cjs" ] || \
    { echo "构建中止：worker-parse.cjs 未派生" >&2; exit 1; }
grep -q '__dshIosTransformSpec' "$NM/@deepseek-ai/dsh-client-ui-plugin-manager/lib/client.js" || \
    { echo "构建中止：手动安装转化钩子未注入" >&2; exit 1; }
echo "    +ios15 校验: git 预检短路 / 市场主线程解析 / redirect follow / 手动转化钩子 通过"

echo "    剩余 .node: $(find "$NM" -name '*.node' | wc -l)  体积: $(du -sh "$NM" | cut -f1)"
[ "$(find "$NM" -name '*.node' | wc -l)" -eq 0 ] || { echo "依赖树里仍有 .node，构建中止" >&2; exit 1; }
cp -a "$NM" "$STAGE/var/jb/usr/lib/dsh/node_modules"

# --- 3b. +ios12 内置纯 JS pnpm（让官方 dsh plugin add 可用） ---
# dsh 的 plugin 子命令把参数原样转发给 pnpm (bin.js:116)，默认命令名就是
# 字符串 'pnpm' (dsh-plugin-manager types/index.js:217)。真机没有
# pnpm/npm/corepack/git，所以 `dsh plugin add` 必然退出码 127。
# 这里放一份 pnpm 10.28.2 纯 JS 发行版（已去掉 4 个非 iOS 平台的 reflink
# .node，Linux 上验证 fallback 正常），由 $JB/usr/bin/pnpm 用包内 node 跑。
# store/cache 由 wrapper 全部落到 $DSH_HOME，不写 root 属主目录。
PNPMSRC="$ROOT/bundles/pnpm"
if [ ! -f "$PNPMSRC/bin/pnpm.cjs" ] || [ ! -f "$PNPMSRC/dist/pnpm.cjs" ]; then
    echo "缺少内置 pnpm: $PNPMSRC" >&2; exit 1
fi
mkdir -p "$STAGE/var/jb/usr/lib/dsh/libexec"
cp -a "$PNPMSRC" "$STAGE/var/jb/usr/lib/dsh/libexec/pnpm"
if [ "$(find "$STAGE/var/jb/usr/lib/dsh/libexec/pnpm" -name '*.node' | wc -l)" -ne 0 ]; then
    echo "构建中止：内置 pnpm 含原生 .node（iOS 无法加载）" >&2; exit 1
fi
echo "    内置 pnpm: $(du -sh "$PNPMSRC" | cut -f1) / 0 个 .node（插件不再随包预装）"

# --- 4b. Safari 16.7 (iPhone X / A11) 浏览器兼容垫片 ---
# AbortSignal.any / Promise.withResolvers / Object.groupBy / Map.groupBy /
# Array.fromAsync 均为 Safari 17.4+ API，iOS 16.7 的 WebKit 全缺。dsh 前端
# 运行时动态加载的插件 client.js 会调用它们，在手机 Safari 里直接抛
# "AbortSignal.any is not a function"。这是浏览器侧问题，与后端 node 无关。
# 垫片采用「特性检测 + 原生优先」，iPhone 17 / iOS 17.4+ 上完全不动。
echo "==> 注入 Safari 16.7 前端兼容垫片 (+ios4) + 手动安装转化逻辑 (+ios15)"
FRONT="$STAGE/var/jb/usr/lib/dsh/node_modules/@deepseek-ai/dsh-web-frontend/dist"
# 构建期/设备端热修/doctor 自愈共用同一个注入实现（apply_frontend_inject.cjs）
node "$ROOT/shims/apply_frontend_inject.cjs" \
    "$FRONT" \
    "$ROOT/shims/safari16-polyfill.js" \
    "$ROOT/shims/dsh-ios-manual-install-transform.js" || exit 1
# 构建期强校验：两个引用都在 <head>、module 之前，且语法可加载
for m in 'safari16-polyfill.js' 'dsh-ios-manual-install-transform.js'; do
    grep -q "$m" "$FRONT/index.html" || { echo "构建中止：index.html 缺 $m 引用" >&2; exit 1; }
    [ -f "$FRONT/assets/$m" ] || { echo "构建中止：缺 assets/$m" >&2; exit 1; }
    node --check "$FRONT/assets/$m" || { echo "构建中止：assets/$m 语法错误" >&2; exit 1; }
done
echo "    +ios15 校验: 前端垫片 + 转化逻辑已注入并通过语法检查"

# --- 5. entitlements / shim 说明 / 启动脚本 / 配置 ---
cp "$ROOT/ent.plist" "$STAGE/var/jb/usr/lib/dsh/ent.plist"
cat > "$STAGE/var/jb/usr/lib/dsh/README-shim.txt" <<'TXT'
dsh for iOS (rootless /var/jb) — 构建说明
Node:  v22.12.0 (纯 arm64, 标准 MAP_JIT, 自带完整 JIT entitlements)
       来自 davghz/node22-ios-source，上游测试机 iPhone X (iPhone10,3)/A11，
       真机验证过 JS eval/loop 与 WebAssembly 编译执行。A11 可用。
dsh:   0.2.1-rc.5 纯 JS 依赖树，无原生 addon；四处 22.12 兼容补丁见下
启动:  /var/jb/usr/bin/dsh 必须带 --expose-internals
两个 addon shim (纯 JS, 替代 iOS 上不存在的原生 .node):
  1) node-addon-require-builtin/lib/index.js  -> createRequire 加载 internal/*
  2) @deepseek-ai/node-addon-system/lib/flock.js -> 单实例恒成功锁
三个 Node 22.12 兼容补丁 (见 shims/apply_compat_patches.py):
  1) dsh/lib/bin.js            -> 去掉 import.meta.main (22.14+ 才有)
  2) session-persistence-jsonl -> zstd(22.15+) 降级为 gzip
  3) ptc-runtime-node          -> stripTypeScriptTypes(22.13+) 直通
已在 x86 Linux Node 22.12.0 实测: --version 正常、web 监听并输出带 token URL、
headless 到达模型调用层 (401)、5 个插件全部激活、0 did-not-activate warning。

+ios3 启动档位链（解决 A11 / iOS 16 rootless 上真 boot 的 SIGBUS）:
  smoke.js      真跑 fetch -> 内置 undici -> llhttp WASM 编译 -> HTTP 往返
  tier.sh       启动前逐档跑 smoke.js，选第一个不崩的档位并缓存
  fetch-shim.cjs nowasm 档：--jitless 下用 node:http 接管 fetch，完全不生成
                可执行代码，从原理上杜绝 SIGBUS（web/headless 已实测通过）
  档位: native / single / balanced / safe / nowasm（从优到保守）

+ios4 浏览器兼容垫片（iPhone X / iOS 16.7 / Safari 16.6）:
  AbortSignal.any / Promise.withResolvers / Object.groupBy / Map.groupBy /
  Array.fromAsync 都是 Safari 17.4+ 才有，iOS 16.7 全缺。dsh 前端动态加载
  的插件 client.js 会调用，手机 Safari 里报
  "AbortSignal.any is not a function. (In '...', 'AbortSignal.any' is undefined)"
  （括号措辞是 JavaScriptCore 独有；后端 node 是 V8，不受影响）。
  iPhone 17 Pro Max (iOS 26) 没有此问题；iOS 换浏览器也无效（强制 WebKit）。
  修法: assets/safari16-polyfill.js + index.html 在 <head> 同步引入，
  特性检测 + 原生优先，新设备零影响。已装 +ios3 的设备可直接跑
  dist/fix-safari16.sh 热修，无需重传 113MB deb。

+ios5 后端 API 断连修复（工作台弹窗 directoryPicker/list failed: Load failed）:
  这不是 Safari 版本问题。+ios3/+ios4 的 fetch-shim.cjs 把原生
  Headers/Request/Response/FormData 一起覆盖成半成品 Shim* 类，而 dsh 后端
  Web 框架正是用这些全局构造响应、解析 multipart —— 处理 /api/... POST 时抛
  异常并静默断开连接，手机 Safari 的 fetch() 就报 "Load failed"。
  只有 A11 会落到 nowasm 档加载这个 shim，能跑 native 档的设备不受影响。
  修法: shim 改为只覆盖 fetch / WebSocket，保留四个原生全局。
  A/B 实测: native 档 POST 200 / 旧 nowasm 档断连 / 新 shim 200，且
  headless 出站 HTTPS 到 401、WebSocket mux 101 握手、插件全激活。
  已装 +ios3/+ios4/+ios5 的设备可跑 dist/fix-api-load-failed.sh 就地热修
  （只替换一个 15KB 文件），之后必须 Ctrl+C 重启 dsh 才生效。

+ios6 SSE 流式 transport failed 修复（工作台发消息 DeepSeek TRANSPORT）:
  不是网络、不是 API key、不是 WebKit。旧 ShimResponse.body 不是幂等 getter，
  而 dsh-llm-deepseek/lib/index.js:2259-2260 连续读两次 response.body，
  第二次抛 "Body is unusable" -> generate() 兜底包成
  "DeepSeek Messages transport failed" (TRANSPORT)，重试 5/5 全失败。
  假 key 时 /messages 返回 401 走 !response.ok 分支，测不到这段。
  修法: body getter 缓存同一个 ReadableStream（幂等），并补 formData()/bytes()。
  端到端实测: 真实 dsh headless 对本地 mock DeepSeek API 收发 SSE，
  修复前 rc=1 TRANSPORT / 修复后 rc=0 正常输出模型回复（含 5 次重试对照）。
  另：插件安装报「退出码 127」是设备上没有 pnpm（本包只内置 node），
  且 Git 仓库插件还需要 git + 网络，属于前置工具缺失，不是本包缺陷。
  已装旧版的设备跑 dist/fix-transport.sh 就地热修，之后必须重启 dsh。

+ios7~+ios11 历史修订（预装插件路线，+ios12 起已废弃）:
  +ios7 预装 QQ Bot / +ios8 修重启丢对话 / +ios9 预装 dsh-im /
  +ios10 修 node:sqlite / +ios11 修 patch 属主与旧 pnpm 残留副本。
  这条「把插件随包固化」的路线和用户（或别的 AI）自己用 pnpm 装的那份
  形成两份副本，接连引发 root 属主 patch、.pnpm 残留、sessions 目录树
  root 属主等一连串故障。+ios12 起全部回退为干净底座。

+ios12 干净底座：不预装插件，改为修好官方安装命令
  dsh 的 plugin 子命令把参数原样转发给 pnpm（bin.js:116），默认命令名
  就是字符串 'pnpm'（dsh-plugin-manager types/index.js:217）。真机没有
  pnpm/npm/corepack/git，所以 `dsh plugin add` 必然退出码 127。
  本版把 pnpm 10.28.2 纯 JS 发行版固化进 $D/libexec/pnpm/，并提供
  $JB/usr/bin/pnpm 用包内 node 直接跑；store/cache 由 wrapper 全部落到
  $DSH_HOME。包内不再含 @xmanrui/dsh-im / @tencent-connect/dsh-qqbot，
  也不再写 cordis.patch.yml、不建软链、不改属主。装插件：
      dsh plugin --profile web add <包名>
      dsh-compat        # 装完 dsh-im 跑一次，补 A11 零 JIT WASM 补丁

+ios12 根治「无法创建新对话」(EACCES):
  真机报错：新建会话失败 gateway/internal: failed to create session:
    Error: EACCES: permission denied, open
    '$DSH_HOME/sessions/--private-preboot-...-DSH--/session-xxx/session.v4.jsonl'
  路径里的 --private-preboot-...-- 是 dsh 把当前工作目录编码成的会话分组名
  (projectKey(cwd))。整棵 sessions/ 目录树曾被 root + .zshenv 包装器建过，
  mobile 用户写不进去；gateway 建不了会话，依赖会话的插件自然「未运行」，
  而纯 Cordis 的 QQ Bot 绕开这条路，所以「另一个能成功运行」。
  旧 doctor 只测 $DSH_HOME 顶层可写（postinst chmod 过），没测子目录 = 假绿灯。
  修法：dsh-home-heal.cjs 用 rename(2) 免 root 修好属主 —— 只要求父目录
  可写，不要求对目标本身有写权限，也不需要 chown。单文件读内容后原子
  替换；sessions 整棵树改名搬到 sessions-legacy-root-<ts> 再重建，历史
  *.jsonl 复制回来。同时整块删除 cordis.patch.yml 里旧预装的两条
  - insert: 块，并只删指向包内的 node_modules 软链。幂等、每次启动都跑。
  dsh-doctor 新增第 20 项：真写一次 session 文件 + 扫描所有子目录可写。

+ios12 保留此前全部修复（回归保障）:
  tier.sh 自动选档 / nowasm 零 JIT / fetch-shim 幂等 body / Safari 16 垫片 /
  会话默认压缩 none / --experimental-sqlite / 全副本零 JIT 补丁扫描 /
  第 9 项 pending 与失败正则。装完插件后跑 dsh-compat 会自动给设备上
  所有 @xmanrui/dsh-im/lib/index.js 副本补补丁，不写配置、不建软链。
  老设备免重传 125MB deb：sh fix-ios14.sh（--status / --restore）。

+ios13 已修（+ios14 全部保留）真机上「doctor 全绿、敲 dsh 直接 fatal」与「plugin 仍 127」:
  A) 启动 fatal:
     dsh: fatal uncaught exception -> Error: patches: patches.yml/
     cordis.patch.yml must be a top-level YAML array of loader patch entries
       at parsePatchList (dsh-app-boot/lib/index.js:4000)
     +ios12 的 cleanPatch() 把两条旧预装 - insert: 整块删掉后，若文件原本
     只有这两块就写出纯注释；js-yaml.load 返回 null，parsePatchList 的
     !Array.isArray 直接抛错。更糟的是 doctor 第 15 项恰好会触发这次清理
     还报 OK，于是「doctor 跑完、一敲 dsh 就崩」。且 readProfilePatches 会读
     两类文件（$DSH_HOME/cordis.patch.yml 与 profiles/*/cordis.patch.yml），
     +ios12 只清了前者，后者残留引用两个已不预装的包 -> headless boot
     ERR_MODULE_NOT_FOUND。
     修法: dsh-home-heal.cjs 全量扫描两类 patch 文件，整块删目标后强制
     保证顶层是合法 YAML 数组（空则写官方模板 []），并能修复真机上已被
     +ios12 删坏的纯注释文件。严格只按 id 匹配，用户自装插件块保留。
  B) dsh plugin 127:
     package.json 的 exports 把 CLI（lib/types/operations.js，单引号）与
     web service（lib/index.js，双引号）分成两份产物，都以
     execa(options.command ?? 'pnpm', ..., {extendEnv:false}) 启动 pnpm。
     真机上 dsh 自造的 env 里 PATH 找不到 /var/jb/usr/bin，或 pnpm 的
     /usr/bin/env node shebang 解析失败 -> ENOENT -> 127。wrapper 改 PATH
     无效，因为这个 env 不继承 wrapper。
     修法: apply_pnpm_abs_patch.cjs 给两份产物各 5 处 command + 5 处 args
     注入包内 node 绝对路径与 pnpm.cjs 绝对路径，命令变成
       $D/bin/node $D/libexec/pnpm/bin/pnpm.cjs add <pkg>
     彻底绕开 PATH / shebang。构建期与设备端热修共用同一脚本，幂等。
  C) dsh-doctor 开头先跑 heal 再检测（否则第 9 项 headless boot 会先崩），
     第 15 项改为真解析所有 patch 文件校验顶层数组，新增第 22 项校验
     pnpm 绝对路径注入。老设备免重传 deb：sh fix-ios14.sh。

+ios14 修掉真机最新两张截图（+ios13 引入的回归 + EACCES 假绿）：
  A) 卸载插件 "Command was killed with SIGBUS (Bus error...)":
     +ios13 把 pnpm 改成绝对路径直连时丢掉了 tier.sh 档位参数。
     bin/pnpm.cjs 显式启用 module.enableCompileCache()/v8-compile-cache，
     dist/pnpm.cjs 是 7.2MB bundle；A11 上 V8 后台线程编译 JIT/WASM 时
     pthread_jit_write_protect_np 按线程生效，写可执行页即 SIGBUS。
     dsh 主进程有 tier_select 保护所以 web 正常，只有 plugin 子进程崩。
     修法: apply_pnpm_abs_patch.cjs 给 CLI + service 两份产物注入 nowasm
     档参数 --jitless --no-expose-wasm --require fetch-shim.cjs（与 tier.sh
     逐字一致），并支持把设备上已打的 +ios13 旧 helper 就地升级。
     pnpm wrapper、热修脚本里的 pnpm 调用同步带上，不再有任何裸跑。
  B) "新建会话失败 ... EACCES ... session.v4.jsonl":
     两个假绿坑：$DSH_HOME 本身 root 555 时 heal 第一行直接 return，后面
     sessions/profiles/patch 自愈一行没跑；treeWritable 只查目录 writable，
     root 444 的 session.v4.jsonl 漏检，doctor 又只测顶层 -w。
     修法: heal 新增 healHomeBySwap()（chmod 或整树 rename 交换，跳过可重建
     缓存目录）、treeWritable 连文件一起查、healSessionFiles() 逐个兜底；
     doctor 第 20 项改为真跑「每个分组目录 mkdir + 写 session.v4.jsonl +
     历史文件覆盖」。已用 nobody + root 555 树 1:1 复现并验证修复。

TXT
# README 内写死的 dsh 版本随 DSH_VER 同步（0.2.2 升级包不能还写 0.2.1）
if [ "$DSH_VER" != "0.2.1-rc.5" ]; then
    _README="$STAGE/var/jb/usr/lib/dsh/README-shim.txt"
    sed "s/0\.2\.1-rc\.5/$DSH_VER/g" "$_README" > "$_README.tmp" && mv "$_README.tmp" "$_README"
fi
cp "$ROOT/payload/var/jb/usr/bin/dsh" "$STAGE/var/jb/usr/bin/dsh"
cp "$ROOT/payload/var/jb/usr/bin/dsh-doctor" "$STAGE/var/jb/usr/bin/dsh-doctor"
cp "$ROOT/payload/var/jb/etc/dsh/dsh.env" "$STAGE/var/jb/etc/dsh/dsh.env"
for f in pnpm dsh-compat; do
    cp "$ROOT/payload/var/jb/usr/bin/$f" "$STAGE/var/jb/usr/bin/$f"
    chmod 755 "$STAGE/var/jb/usr/bin/$f"
    sh -n "$STAGE/var/jb/usr/bin/$f" || { echo "$f 语法错误" >&2; exit 1; }
done
cp "$ROOT/payload/var/jb/usr/lib/dsh/README-A11.txt" "$STAGE/var/jb/usr/lib/dsh/README-A11.txt"
# --- 5b. +ios3 启动档位链（WASM 冒烟探针 / 自动选档 / 零 JIT 兜底） ---
for f in smoke.js tier.sh; do
    [ -f "$ROOT/payload/var/jb/usr/lib/dsh/$f" ] || { echo "缺少 $f" >&2; exit 1; }
    cp "$ROOT/payload/var/jb/usr/lib/dsh/$f" "$STAGE/var/jb/usr/lib/dsh/$f"
done
for f in fetch-shim.cjs; do
    [ -f "$ROOT/shims/$f" ] || { echo "缺少 shims/$f" >&2; exit 1; }
    cp "$ROOT/shims/$f" "$STAGE/var/jb/usr/lib/dsh/$f"
done
# --- 5c. +ios8 会话修复热修脚本（设备端常驻，升级安装时 postinst 自动跑） ---
[ -f "$ROOT/dist/fix-session.sh" ] || { echo "缺少 dist/fix-session.sh" >&2; exit 1; }
cp "$ROOT/dist/fix-session.sh" "$STAGE/var/jb/usr/lib/dsh/fix-session.sh"
chmod 755 "$STAGE/var/jb/usr/lib/dsh/fix-session.sh"
sh -n "$STAGE/var/jb/usr/lib/dsh/fix-session.sh" || { echo "fix-session.sh 语法错误" >&2; exit 1; }
# 构建期强校验：会话默认压缩必须是 none，否则又会打出「重启丢对话」的包。
PJ="$STAGE/var/jb/usr/lib/dsh/node_modules/@deepseek-ai/dsh-session-persistence-jsonl/lib/index.js"
if ! grep -q 'const DEFAULT_COMPRESSION = "none";' "$PJ"; then
    echo "构建中止：会话默认压缩不是 none，+ios8 修复未生效" >&2; exit 1
fi
echo "    +ios8 会话修复: 默认压缩 none，构建期校验通过"
# --- 5e. +ios15 自愈/兼容/补丁脚本、设备端热修、启动链路强校验 ---
for f in dsh-home-heal.cjs dsh-plugin-compat.cjs apply_pnpm_abs_patch.cjs \
         apply_plugin_install_patch.cjs apply_frontend_inject.cjs \
         safari16-polyfill.js dsh-ios-manual-install-transform.js; do
    SRC="$ROOT/shims/$f"
    [ -f "$SRC" ] || { echo "缺少 shims/$f" >&2; exit 1; }
    cp "$SRC" "$STAGE/var/jb/usr/lib/dsh/$f"
    chmod 644 "$STAGE/var/jb/usr/lib/dsh/$f"
    node --check "$STAGE/var/jb/usr/lib/dsh/$f" || { echo "$f 语法错误" >&2; exit 1; }
done
# 热修包每次构建从 payload + shims + 已注入的前端 dist + bundles/pnpm 重新生成，
# 内嵌文件与 deb 内对应文件字节一致
FIX_OUT="$DST/$FIX_NAME"
python3 "$ROOT/shims/make_fix_ios15.py" "$ROOT" \
    "$STAGE/var/jb/usr/lib/dsh/node_modules/@deepseek-ai/dsh-web-frontend/dist" \
    "$FIX_OUT" \
    || { echo "生成 $FIX_NAME 失败" >&2; exit 1; }
cp "$FIX_OUT" "$STAGE/var/jb/usr/lib/dsh/$FIX_NAME"
chmod 755 "$STAGE/var/jb/usr/lib/dsh/$FIX_NAME"
sh -n "$STAGE/var/jb/usr/lib/dsh/$FIX_NAME" || { echo "$FIX_NAME 语法错误" >&2; exit 1; }

# 启动链路必须带 sqlite 开关（漏一处就重演 +ios9 整包 import 失败）
for f in tier.sh fix-session.sh "$FIX_NAME"; do
    P="$STAGE/var/jb/usr/lib/dsh/$f"
    grep -q -- '--experimental-sqlite' "$P" || \
        { echo "构建中止：$P 缺 --experimental-sqlite" >&2; exit 1; }
done
for f in dsh dsh-doctor; do
    P="$STAGE/var/jb/usr/bin/$f"
    grep -q -- 'TIER_SQLITE_ARGS' "$P" || \
        { echo "构建中止：$P 缺 sqlite 开关" >&2; exit 1; }
    grep -q -- 'dsh-home-heal' "$P" || \
        { echo "构建中止：$P 缺 +ios12 用户数据自愈" >&2; exit 1; }
done
# 用户明确要求：包内不再默认自带两个插件
for p in '@xmanrui/dsh-im' '@tencent-connect/dsh-qqbot'; do
    [ ! -e "$STAGE/var/jb/usr/lib/dsh/node_modules/$p" ] || \
        { echo "构建中止：包内仍含预装插件 $p" >&2; exit 1; }
done
# pnpm 必须纯 JS（iOS 不能加载 macOS/Windows 的 .node）
[ "$(find "$STAGE/var/jb/usr/lib/dsh/libexec/pnpm" -name '*.node' | wc -l)" -eq 0 ] || \
    { echo "构建中止：pnpm 含 .node" >&2; exit 1; }
echo "    +ios14 校验: 干净底座 / pnpm 纯 JS / 自愈链路 / sqlite 开关 通过"
# --- 5f. +ios14 强校验（漏一处就会重演真机 fatal / 127 / SIGBUS / EACCES） ---
HEAL="$STAGE/var/jb/usr/lib/dsh/dsh-home-heal.cjs"
grep -q 'cleanAllPatches' "$HEAL" || { echo "构建中止：heal 缺全量 patch 扫描" >&2; exit 1; }
grep -q 'patchLooksValid' "$HEAL" || { echo "构建中止：heal 缺顶层数组校验" >&2; exit 1; }
grep -q 'healHomeBySwap' "$HEAL" || { echo "构建中止：heal 缺 \$DSH_HOME 属主自愈" >&2; exit 1; }
grep -q 'healSessionFiles' "$HEAL" || { echo "构建中止：heal 缺会话文件兜底" >&2; exit 1; }
for f in index.js types/operations.js; do
    P="$STAGE/var/jb/usr/lib/dsh/node_modules/@deepseek-ai/dsh-plugin-manager/lib/$f"
    grep -q 'dsh-ios +ios14' "$P" || { echo "构建中止：$f 缺 pnpm 绝对路径补丁" >&2; exit 1; }
    grep -q '__dshPnpmFlags' "$P" || { echo "构建中止：$f 缺 pnpm 零 JIT 档参数（真机会 SIGBUS）" >&2; exit 1; }
done
grep -q -- '--jitless' "$STAGE/var/jb/usr/bin/pnpm" || \
    { echo "构建中止：pnpm wrapper 缺零 JIT 档参数" >&2; exit 1; }
FIXSH="$STAGE/var/jb/usr/lib/dsh/$FIX_NAME"
for m in 'dsh-home-heal.cjs' 'apply_pnpm_abs_patch.cjs' 'apply_plugin_install_patch.cjs' \
         'dsh-ios +ios14' 'dsh-ios +ios15' 'dsh-ios-manual-install-transform.js'; do
    grep -q "$m" "$FIXSH" || { echo "构建中止：$FIX_NAME 缺 $m" >&2; exit 1; }
done
# 源码级标记在压缩 base64 里搜不到，必须真解出内嵌 tar 再校验。
VT=$(mktemp -d) || exit 1
python3 - "$FIXSH" "$VT/pack.tar" <<'PY' || { echo "构建中止：无法解出热修内嵌 tar" >&2; rm -rf "$VT"; exit 1; }
import sys, re, base64, gzip
s = open(sys.argv[1], encoding='utf-8').read()
m = re.search(r"<<'DSH_IOS15_B64'\n([\s\S]*?)\nDSH_IOS15_B64", s)
if not m: sys.exit(2)
open(sys.argv[2], 'wb').write(gzip.decompress(base64.b64decode(re.sub(r'\s', '', m.group(1)))))
PY
tar xf "$VT/pack.tar" -C "$VT" 2>/dev/null || \
    { echo "构建中止：热修内嵌 tar 解包失败" >&2; rm -rf "$VT"; exit 1; }
grep -q 'healHomeBySwap'   "$VT/lib/dsh-home-heal.cjs"        || { echo "构建中止：热修内嵌 heal 缺 HOME 自愈" >&2; rm -rf "$VT"; exit 1; }
grep -q 'healSessionFiles' "$VT/lib/dsh-home-heal.cjs"        || { echo "构建中止：热修内嵌 heal 缺会话文件兜底" >&2; rm -rf "$VT"; exit 1; }
grep -q '__dshPnpmFlags'   "$VT/lib/apply_pnpm_abs_patch.cjs" || { echo "构建中止：热修内嵌补丁缺零 JIT 档" >&2; rm -rf "$VT"; exit 1; }
grep -q 'git-probe-shortcircuit' "$VT/lib/apply_plugin_install_patch.cjs" || { echo "构建中止：热修内嵌 +ios15 补丁缺 git 预检短路" >&2; rm -rf "$VT"; exit 1; }
grep -q '__dshIosTransformSpec' "$VT/web/assets/dsh-ios-manual-install-transform.js" || { echo "构建中止：热修内嵌前端缺转化逻辑" >&2; rm -rf "$VT"; exit 1; }
# 内嵌文件与 deb 内对应文件逐字节比对（cmp），防止热修覆盖出的文件与整包不一致
for f in safari16-polyfill.js dsh-ios-manual-install-transform.js \
         apply_plugin_install_patch.cjs apply_frontend_inject.cjs; do
    cmp -s "$VT/lib/$f" "$STAGE/var/jb/usr/lib/dsh/$f" || \
        { echo "构建中止：热修内嵌 lib/$f 与 deb 不一致" >&2; rm -rf "$VT"; exit 1; }
done
FRONT="$STAGE/var/jb/usr/lib/dsh/node_modules/@deepseek-ai/dsh-web-frontend/dist"
for f in index.html assets/safari16-polyfill.js assets/dsh-ios-manual-install-transform.js; do
    cmp -s "$VT/web/$f" "$FRONT/$f" || \
        { echo "构建中止：热修内嵌 web/$f 与 deb 不一致" >&2; rm -rf "$VT"; exit 1; }
done
rm -rf "$VT"
echo "    +ios15 校验: HOME 自愈 / 会话兜底 / patch 数组 / pnpm 零 JIT / +ios15 补丁 / 前端注入 / 热修内嵌逐字节一致 通过"
# node 只用于构建期语法自检，构建机没有 node 时跳过（不引入额外依赖）。
if command -v node >/dev/null 2>&1; then
    node --check "$STAGE/var/jb/usr/lib/dsh/smoke.js" || { echo "smoke.js 语法错误" >&2; exit 1; }
    node --check "$STAGE/var/jb/usr/lib/dsh/fetch-shim.cjs" || { echo "fetch-shim.cjs 语法错误" >&2; exit 1; }
fi
sh -n "$STAGE/var/jb/usr/lib/dsh/tier.sh" || { echo "tier.sh 语法错误" >&2; exit 1; }
sh -n "$STAGE/var/jb/usr/bin/dsh" || { echo "dsh 语法错误" >&2; exit 1; }
sh -n "$STAGE/var/jb/usr/bin/dsh-doctor" || { echo "dsh-doctor 语法错误" >&2; exit 1; }
chmod 755 "$STAGE/var/jb/usr/bin/dsh" "$STAGE/var/jb/usr/bin/dsh-doctor"
chmod 644 "$STAGE/var/jb/usr/lib/dsh/smoke.js" "$STAGE/var/jb/usr/lib/dsh/tier.sh" "$STAGE/var/jb/usr/lib/dsh/fetch-shim.cjs"

# --- 6. DEBIAN ---
cp -a "$ROOT/DEBIAN" "$STAGE/DEBIAN"
# control 的 Version 必须与构建目标一致（0.2.1-rc.5+ios15 / 0.2.2-rc.1+ios16）。
# 只在 stage 副本上改，仓库里的 DEBIAN/control 仍是稳定底座的默认版本。
_CONTROL="$STAGE/DEBIAN/control"
# 关键：0.2.1-rc.5+ios15 是已发布、真机验证过的稳定底座，control 必须保持
# 与仓库里的 DEBIAN/control 逐字节一致，否则重新构建出的 deb 与已发布 Release
# 附件 SHA 不同，破坏「别人 clone 后 1:1 重建」的承诺。只有升级包才改 control。
if [ "$DSH_VER" != "0.2.1-rc.5" ]; then
    sed "s|^Version: .*|Version: ${DSH_VER}${IOS_TAG}|" "$ROOT/DEBIAN/control" > "$_CONTROL.tmp"
    mv "$_CONTROL.tmp" "$_CONTROL"
    # Debian control 的 Description 续行以空格开头，空行写成 " ."
    cat >> "$_CONTROL" <<EOF
 .
 Build: dsh ${DSH_VER} on Node 22.12.0 with dsh-iOS ${IOS_TAG} patches.
 The 0.2.2-rc.1 build passes verify-022.sh (31 checks incl. real boot,
 session create and resume) on the same Node 22.12.0 as the device.
EOF
fi
chmod 755 "$STAGE/DEBIAN/postinst" "$STAGE/DEBIAN/prerm"

# --- 7. 不重签 node ---
# 内置二进制自带上游在 iPhone X 真机签好的完整 JIT entitlements。构建机用 ldid
# 预签会覆盖掉它、还会改动字节（破坏上面的 size/SHA 校验与可复现性），所以这里
# 原样保留。设备端 postinst 也只在 entitlement 确实缺失时才兜底补签。

# --- 8. 打包（字节级可复现） ---
# dpkg-deb 会把 stage 内文件的 mtime/mode/uid/gid/排序写进 tar 与 control.tar；
# 不同 clone 时间、不同 umask、不同解包方式会导致 deb SHA 变化。这里统一：
#   * 所有 stage 文件/目录/链接 mtime 固定到 SOURCE_DATE_EPOCH
#   * 属主统一 0:0（dpkg 安装时按 postinst/包管理还原，iOS rootless 下都是 root）
#   * 文件/目录 mode 按 git 语义归一到固定两档（见下）
#   * dpkg-deb 用固定的 gzip -z9，且 SOURCE_DATE_EPOCH 让 control 时间戳确定
# 实测连续构建 SHA-256 完全一致；verify-repro.sh 会真跑两次比对。
SDE="${SOURCE_DATE_EPOCH:-1700000000}"
echo "==> 固定 stage 文件 mode（消除 umask / clone / 解包方式差异）"
# git 只记录「可执行位」两档：100644 → 644、100755 → 755。但用
# `git archive | tar -x`（root）解包会把它们写成 664/775，某些 umask 也会
# 让 clone 检出成 660/770，都会被打进 deb 的 tar 导致 SHA 漂移。
# 这里把 mode 按「目录 755；普通文件 owner 有 x → 755，否则 → 644」归一化，
# 与真实 git clone 的检出结果一致，且对已是 644/755 的工作区完全幂等
# （本地交付 deb 的字节因此不变）。符号链接不处理（-type f/-type d 不匹配，
# 其 lmode 由 tar 固定记录）。
find "$STAGE" -type d -exec chmod 755 {} +
find "$STAGE" -type f -perm /100 -exec chmod 755 {} +
find "$STAGE" -type f '!' -perm /100 -exec chmod 644 {} +
echo "==> 固定 stage 时间戳 / 属主（SOURCE_DATE_EPOCH=$SDE）"
# -h 处理符号链接本身；先目录后文件，避免改父目录 mtime 影响子项写入
chown -R 0:0 "$STAGE" 2>/dev/null || true
find "$STAGE" -depth -exec touch -h -d "@$SDE" {} + 2>/dev/null || \
    find "$STAGE" -depth -exec touch -h -t "$(date -u -r "$SDE" +%Y%m%d%H%M.%S 2>/dev/null || echo 202311142013.20)" {} + 2>/dev/null || true
echo "==> dpkg-deb 组装（压缩: $COMP，可复现）"
SOURCE_DATE_EPOCH="$SDE" dpkg-deb -b $ZARGS "$STAGE" "$OUT"
echo
echo "完成: $OUT"
echo "大小: $(du -sh "$OUT" | cut -f1)"
echo "SHA-256: $(sha256sum "$OUT" | cut -d' ' -f1)"
