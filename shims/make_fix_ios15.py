#!/usr/bin/env python3
"""
make_fix_ios15.py —— 生成设备端一键热修 dist/fix-ios15.sh

用法: make_fix_ios15.py <ROOT> <已注入的 dsh-web-frontend/dist 目录>

内嵌内容（每次构建从 payload + shims + 已注入的前端 dist + bundles/pnpm
重新生成，与 deb 内对应文件字节一致）:
  bin/dsh, bin/dsh-doctor, bin/pnpm, bin/dsh-compat
  lib/tier.sh, dsh-home-heal.cjs, dsh-plugin-compat.cjs,
      apply_pnpm_abs_patch.cjs, apply_plugin_install_patch.cjs,
      safari16-polyfill.js, dsh-ios-manual-install-transform.js
  web/index.html, web/assets/safari16-polyfill.js,
      web/assets/dsh-ios-manual-install-transform.js
  etc/dsh.env
  pnpm/           整个纯 JS pnpm 10.28.2 发行版

设计要点（沿用 +ios14 的成熟结构）:
  * 已装 +ios14 的设备免重传 125MB deb。
  * 包目录 $D 归 root；mobile 跑热修覆盖 node_modules 可能失败。因此
    「用户数据自愈」放最前、不依赖 root 写权限；补丁/前端覆盖计入 FAILW，
    失败明确提示用 root 重跑或装新 deb，不静默假成功。
  * +ios15 新增：设备端用包内 node 跑 apply_plugin_install_patch.cjs 重新
    打补丁（幂等、会派生 worker-parse.cjs），并覆盖前端 dist 的 index.html
    与两个 assets（Safari 垫片 + 手动安装转化逻辑）。
"""
import base64
import gzip
import io
import sys
import tarfile
import textwrap
from pathlib import Path

HEAD = r'''#!/bin/sh
# ============================================================================
# fix-ios15.sh —— +ios15 设备端热修（已装 +ios14 的设备免重传 125MB deb）
#
# 本轮收口真机反馈的三类故障（全部是「Web UI 手动安装」/「插件市场」）：
#  A) 「点击插件 → 安装插件」里所有手动方式都失败（AI 帮你装成功）:
#     service 产物 dsh-plugin-manager/lib/index.js 的 installBundle() 先跑
#     checkGithubConnection()，对 git/github spec 裸调 execa("git") —— iOS
#     rootless 没有 git 二进制，ENOENT 判成 network 后直接 throw，安装中止。
#     这就是「GitHub 仓库安装不再是 127、有别的报错」。AI 装会智能把仓库
#     地址转成 npm 包名/tarball，不触发预检，故成功。
#     修法: +ios15 短路这个【可选】预检（真下载由 pnpm 走 codeload HTTP）。
#  B) 「插件市场点进去直接加载失败，一堆报错」:
#     fetchIndex() 用 redirect:"error"，目录站/CDN/http->https 一跳转就抛错；
#     parseIndexInWorker() 用 new Worker(execArgv:[]) 起子线程，在 A11 nowasm
#     零 JIT 主进程下子线程重新启用 V8 JIT，写可执行页即 SIGBUS。
#     修法: redirect 改 follow；索引解析改主线程（同源 worker-parse.cjs）。
#  C) 生态插件 iOS/浏览器兼容性：Web UI 手动安装对话框提交 spec 前接入
#     __dshIosTransformSpec，把 GitHub/git 地址转成 hosted-git 简写、并对
#     【已知不兼容】插件给提示+替代建议（不硬拦）。
#     ★ 硬约束：AI 帮你装（tools.js）与命令行（operations.js）不经过该前端
#       钩子，绝不应用转化；浏览器垫片同步补齐生态插件用到的高版本 API。
#
# 同时保留 +ios14 及此前全部修复：pnpm 绝对路径直连 + 零 JIT / HOME 属主
# 自愈 / 会话文件兜底 / patch 顶层数组 / Safari 16 垫片 / 会话压缩 none /
# --experimental-sqlite / tier.sh 自动选档 / fetch-shim 幂等 body。
#
# 用法: sh fix-ios15.sh            # 安装 +ios15 热修
#       sh fix-ios15.sh --status   # 只看状态，不改文件
#       sh fix-ios15.sh --restore # 回滚启动文件到安装前（用户数据不动）
# ============================================================================
set -u
JB=/var/jb
D="$JB/usr/lib/dsh"
NODE="${DSH_NODE:-$D/bin/node}"
NODE_PATH="$D/node_modules"; export NODE_PATH
DSH_NODE="$NODE"; export DSH_NODE
BIN="$D/node_modules/@deepseek-ai/dsh/lib/bin.js"
NM="$D/node_modules"
FRONT="$NM/@deepseek-ai/dsh-web-frontend/dist"
HOME_DSH="${DSH_HOME:-$JB/var/mobile/.dsh}"
BK="$HOME_DSH/backup-ios15"
MARK="$HOME_DSH/.dsh-ios15"
TMP=/tmp/dsh-fix-ios15.$$
MODE="${1:-install}"
SQFLAGS="--experimental-sqlite --disable-warning=ExperimentalWarning"
TIERFLAGS="$SQFLAGS"
[ -f "$D/fetch-shim.cjs" ] && TIERFLAGS="$TIERFLAGS --jitless --no-expose-wasm --require $D/fetch-shim.cjs"

ok(){   printf '  [ ok ] %s\n' "$1"; }
warn(){ printf '  [warn] %s\n' "$1"; }
die(){  printf '  [FAIL] %s\n' "$1" >&2; exit 1; }

[ -L "$JB" ] || die "未检测到 rootless 越狱 (/var/jb)；先打开 Dopamine 点 Jailbreak"
[ -x "$NODE" ] || die "缺包内 node：$NODE"
[ -f "$BIN" ] || die "缺 dsh 主程序：$BIN"

echo "=== dsh +ios15 热修 / 修手动安装全方式 + 修插件市场加载 + 生态插件转化 ==="
echo "    node     : $("$NODE" -v 2>/dev/null)"
echo "    DSH_HOME : $HOME_DSH"

# ---- --status ----
if [ "$MODE" = "--status" ]; then
    S="$HOME_DSH/sessions"
    mkdir -p "$S" 2>/dev/null || true
    P="$S/.status-probe.$$"
    if [ -w "$S" ] && (printf x > "$P" 2>/dev/null); then
        rm -f "$P" 2>/dev/null || true; ok "sessions 可新建会话文件（无 EACCES）"
    else
        warn "sessions 不可写（跑 sh fix-ios15.sh 修复）"
    fi
    if "$NODE" $SQFLAGS -e 'const m=require("node:sqlite");process.exit(typeof m.DatabaseSync==="function"?0:2)' >/dev/null 2>&1; then
        ok "node:sqlite 可加载"
    else
        warn "node:sqlite 不可加载（启动链路缺 --experimental-sqlite）"
    fi
    if [ -x "$JB/usr/bin/pnpm" ] && "$JB/usr/bin/pnpm" --version >/dev/null 2>&1; then
        ok "包内 pnpm 可用（dsh plugin add 可用）"
    elif [ -f "$D/libexec/pnpm/bin/pnpm.cjs" ]; then
        ok "pnpm 文件已就位（命令包装缺失，跑 sh fix-ios15.sh 补齐）"
    else
        warn "缺包内 pnpm（dsh plugin add 仍是 127）"
    fi
    # +ios15：git 预检短路 / 市场主线程解析 / 手动转化钩子
    PM="$NM/@deepseek-ai/dsh-plugin-manager/lib/index.js"
    MK="$NM/@deepseek-ai/dsh-plugin-market/lib/index.js"
    CJS="$NM/@deepseek-ai/dsh-client-ui-plugin-manager/lib/client.js"
    if grep -q 'dsh-ios +ios15' "$PM" 2>/dev/null; then ok "GitHub 手动安装已不依赖 git（预检短路）"; else warn "GitHub 手动安装仍会因缺 git 报新错；跑 sh fix-ios15.sh"; fi
    if grep -q 'redirect: "follow"' "$MK" 2>/dev/null && [ -f "$NM/@deepseek-ai/dsh-plugin-market/lib/worker-parse.cjs" ]; then ok "插件市场已改主线程解析 + redirect follow（不 SIGBUS / 不跳转即报错）"; else warn "插件市场仍是旧链路；跑 sh fix-ios15.sh"; fi
    if grep -q '__dshIosTransformSpec' "$CJS" 2>/dev/null && [ -f "$FRONT/assets/dsh-ios-manual-install-transform.js" ]; then ok "手动安装转化逻辑已就位（AI 帮你装不受影响）"; else warn "手动安装转化逻辑缺失；跑 sh fix-ios15.sh"; fi
    # +ios14 回归
    PATCHBAD=0; PATCHN=0
    for pf in "$HOME_DSH/cordis.patch.yml" "$HOME_DSH/patches.yml" \
              "$HOME_DSH"/profiles/*/cordis.patch.yml "$HOME_DSH"/profiles/*/patches.yml; do
        [ -f "$pf" ] || continue
        PATCHN=$((PATCHN+1))
        if grep -qE '^[[:space:]]*\[[[:space:]]*\]' "$pf" 2>/dev/null || \
           grep -qE '^-' "$pf" 2>/dev/null; then :; else PATCHBAD=$((PATCHBAD+1)); fi
    done
    if [ "$PATCHBAD" -eq 0 ]; then ok "全部 $PATCHN 个 patch 文件顶层为合法数组"; else warn "$PATCHBAD 个 patch 文件顶层非法；跑 sh fix-ios15.sh"; fi
    PML="$NM/@deepseek-ai/dsh-plugin-manager/lib"
    if grep -q 'dsh-ios +ios14' "$PML/index.js" 2>/dev/null && grep -q '__dshPnpmFlags' "$PML/index.js" 2>/dev/null; then
        ok "pnpm 绝对路径直连 + 零 JIT 已注入（不 127 / 不 SIGBUS）"
    else
        warn "pnpm 补丁缺失；跑 sh fix-ios15.sh"
    fi
    [ -f "$MARK" ] && ok "已打过 +ios15 热修" || warn "尚未打 +ios15 热修"
    exit 0
fi

# ---- --restore ----
if [ "$MODE" = "--restore" ]; then
    [ -d "$BK" ] || die "没有备份目录 $BK"
    for f in dsh dsh-doctor pnpm dsh-compat; do
        [ -f "$BK/$f" ] && cp "$BK/$f" "$JB/usr/bin/$f" 2>/dev/null \
            && chmod 755 "$JB/usr/bin/$f" 2>/dev/null || true
    done
    for f in tier.sh dsh-home-heal.cjs dsh-plugin-compat.cjs apply_pnpm_abs_patch.cjs apply_plugin_install_patch.cjs; do
        [ -f "$BK/$f" ] && cp "$BK/$f" "$D/$f" 2>/dev/null || true
    done
    [ -f "$BK/dsh.env" ] && cp "$BK/dsh.env" "$JB/etc/dsh/dsh.env" 2>/dev/null || true
    rm -f "$MARK" 2>/dev/null || true
    ok "已回滚启动文件到安装前（用户数据未动；新增的 pnpm / 前端注入保留）"
    exit 0
fi

[ "$MODE" = "install" ] || die "未知参数：$MODE（可用 --status / --restore）"

# ---- 1) 备份（只第一次，避免二次安装把备份覆盖成已修版本） ----
mkdir -p "$HOME_DSH" 2>/dev/null || true
if [ ! -d "$BK" ]; then
    mkdir -p "$BK" 2>/dev/null || die "无法创建备份目录 $BK"
    for f in dsh dsh-doctor pnpm dsh-compat; do
        cp "$JB/usr/bin/$f" "$BK/$f" 2>/dev/null || true
    done
    for f in tier.sh dsh-home-heal.cjs dsh-plugin-compat.cjs apply_pnpm_abs_patch.cjs apply_plugin_install_patch.cjs; do
        cp "$D/$f" "$BK/$f" 2>/dev/null || true
    done
    cp "$JB/etc/dsh/dsh.env" "$BK/dsh.env" 2>/dev/null || true
    ok "原文件已备份到 $BK"
else
    ok "备份已存在，保留第一次的原始版本"
fi

# ---- 2) 解包（用包内 node 解码，不依赖设备上的 base64/python/gzip 命令） ----
mkdir -p "$TMP" 2>/dev/null || die "无法创建临时目录"
cleanup(){ rm -rf "$TMP" 2>/dev/null || true; }
trap cleanup EXIT INT TERM

cat > "$TMP/pack.b64" <<'DSH_IOS15_B64'
__B64__
DSH_IOS15_B64

if ! "$NODE" -e '
const fs=require("fs"),z=require("zlib");
const s=fs.readFileSync(process.argv[1],"utf8").replace(/\s/g,"");
fs.writeFileSync(process.argv[2],z.gunzipSync(Buffer.from(s,"base64")));
' "$TMP/pack.b64" "$TMP/pack.tar" 2>"$TMP/decode.err"; then
    die "解码失败：$(head -1 "$TMP/decode.err" 2>/dev/null)"
fi
# gunzipSync 已经把 gzip 剥掉，pack.tar 是【纯 tar】（+ios13 及更早曾误用 tar xzf）
if ! tar xf "$TMP/pack.tar" -C "$TMP" 2>"$TMP/tar.err"; then
    die "解包失败：$(head -1 "$TMP/tar.err" 2>/dev/null)"
fi
for f in bin/dsh bin/dsh-doctor bin/pnpm bin/dsh-compat lib/tier.sh \
         lib/dsh-home-heal.cjs lib/dsh-plugin-compat.cjs \
         lib/apply_pnpm_abs_patch.cjs lib/apply_plugin_install_patch.cjs \
         lib/apply_frontend_inject.cjs \
         lib/safari16-polyfill.js lib/dsh-ios-manual-install-transform.js \
         web/index.html web/assets/safari16-polyfill.js \
         web/assets/dsh-ios-manual-install-transform.js etc/dsh.env \
         pnpm/bin/pnpm.cjs pnpm/dist/pnpm.cjs; do
    [ -f "$TMP/$f" ] || die "包内缺 $f"
done
ok "热修包解包完成（含纯 JS pnpm + +ios15 补丁 + 前端注入产物）"

# ---- 3) ★ 用户数据自愈（不依赖包目录写权限，最先做、必定生效） ----
echo
echo "--- 3) 修「无法创建新对话」EACCES（免 root） ---"
"$NODE" "$TMP/lib/dsh-home-heal.cjs" "$HOME_DSH" "$D" 2>&1 | sed 's/^/    /' || true
S="$HOME_DSH/sessions"
mkdir -p "$S" 2>/dev/null || true
PROBE="$S/.fix15-ns-$$/session--probe"
if mkdir -p "$PROBE" 2>/dev/null && \
   printf '{"v":4}\n' > "$PROBE/session.v4.jsonl" 2>/dev/null; then
    rm -rf "$S/.fix15-ns-$$" 2>/dev/null || true
    ok "新建会话全链路写入成功（深层 mkdir + session.v4.jsonl，EACCES 已消除）"
else
    warn "sessions 仍不可写；检查 $HOME_DSH 属主"
fi

# ---- 4) ★ 已装 dsh-im 副本补零 JIT 补丁（也从临时目录跑） ----
echo
echo "--- 4) 扫描并补齐设备上所有 dsh-im 副本的零 JIT 补丁 ---"
"$NODE" "$TMP/lib/dsh-plugin-compat.cjs" "$HOME_DSH" "$NM" 2>&1 \
    | sed 's/^/    /' || true

# ---- 5) 覆盖包内文件（$D 归 root，mobile 身份可能写不进去） ----
echo
echo "--- 5) 覆盖启动文件、补丁脚本、前端注入产物、内置 pnpm ---"
FAILW=0
put(){ # src dest mode
    if cp "$1" "$2" 2>/dev/null; then
        chmod "$3" "$2" 2>/dev/null || true
    else
        FAILW=$((FAILW+1))
    fi
}
put "$TMP/bin/dsh"                "$JB/usr/bin/dsh"        755
put "$TMP/bin/dsh-doctor"         "$JB/usr/bin/dsh-doctor" 755
put "$TMP/bin/pnpm"               "$JB/usr/bin/pnpm"       755
put "$TMP/bin/dsh-compat"         "$JB/usr/bin/dsh-compat" 755
put "$TMP/lib/tier.sh"            "$D/tier.sh"             644
put "$TMP/lib/dsh-home-heal.cjs"  "$D/dsh-home-heal.cjs"   644
put "$TMP/lib/dsh-plugin-compat.cjs" "$D/dsh-plugin-compat.cjs" 644
put "$TMP/lib/apply_pnpm_abs_patch.cjs" "$D/apply_pnpm_abs_patch.cjs" 644
put "$TMP/lib/apply_plugin_install_patch.cjs" "$D/apply_plugin_install_patch.cjs" 644
put "$TMP/lib/apply_frontend_inject.cjs" "$D/apply_frontend_inject.cjs" 644
put "$TMP/lib/safari16-polyfill.js" "$D/safari16-polyfill.js" 644
put "$TMP/lib/dsh-ios-manual-install-transform.js" "$D/dsh-ios-manual-install-transform.js" 644
put "$TMP/etc/dsh.env"            "$JB/etc/dsh/dsh.env"    644
mkdir -p "$FRONT/assets" 2>/dev/null || true
put "$TMP/web/index.html"                                  "$FRONT/index.html" 644
put "$TMP/web/assets/safari16-polyfill.js"                "$FRONT/assets/safari16-polyfill.js" 644
put "$TMP/web/assets/dsh-ios-manual-install-transform.js" "$FRONT/assets/dsh-ios-manual-install-transform.js" 644

# ---- 5b) ★ +ios14 保底：pnpm 绝对路径直连（就地升级/首次注入，幂等） ----
PML="$NM/@deepseek-ai/dsh-plugin-manager/lib"
if "$NODE" "$TMP/lib/apply_pnpm_abs_patch.cjs" "$PML" >/dev/null 2>&1; then
    ok "pnpm 绝对路径直连 + 零 JIT 已注入（不 127 / 不 SIGBUS）"
else
    FAILW=$((FAILW+1)); warn "pnpm 补丁应用失败（$PML 归 root 或依赖树版本不符）"
fi

# ---- 5c) ★ +ios15：重新打手动安装/插件市场补丁（派生 worker-parse.cjs） ----
echo
echo "--- 5c) 应用 +ios15 手动安装 / 插件市场修复补丁 ---"
if "$NODE" "$TMP/lib/apply_plugin_install_patch.cjs" "$NM" 2>&1 | sed 's/^/    /'; then
    ok "git 预检短路 / 市场主线程解析 / redirect follow / 手动转化钩子 已应用"
else
    FAILW=$((FAILW+1)); warn "+ios15 补丁应用失败（$NM 归 root？用 root 重跑热修）"
fi
# 前端注入再用统一实现幂等兜底一次（防止 index.html 被旧版覆盖）
if "$NODE" "$TMP/lib/apply_frontend_inject.cjs" "$FRONT" \
      "$TMP/lib/safari16-polyfill.js" \
      "$TMP/lib/dsh-ios-manual-install-transform.js" 2>&1 | sed 's/^/    /'; then
    ok "前端垫片 + 手动安装转化逻辑注入完成（幂等）"
else
    FAILW=$((FAILW+1)); warn "前端注入失败（$FRONT 归 root？用 root 重跑热修）"
fi

if mkdir -p "$D/libexec/pnpm" 2>/dev/null; then
    if ! cp -R "$TMP/pnpm/." "$D/libexec/pnpm/" 2>/dev/null; then FAILW=$((FAILW+1)); fi
else
    FAILW=$((FAILW+1))
fi
if [ "$FAILW" -eq 0 ]; then
    ok "启动文件 + 补丁脚本 + 前端注入 + 内置 pnpm 已全部更新为 +ios15"
else
    warn "$FAILW 项未覆盖：$D 归 root，当前身份（$(id -un 2>/dev/null)）写不进去"
    echo "        完整升级请二选一："
    echo "          sudo sh fix-ios15.sh    或   su root -c 'sh fix-ios15.sh'"
    echo "          或重传安装 +ios15 的 .deb"
    echo "        但第 3 步的「新建会话 EACCES 修复」已经生效，不依赖 root。"
fi

# ---- 6) 真跑验证 ----
echo
echo "--- 6) 验证 ---"
VERR=0
if "$NODE" $SQFLAGS -e 'const m=require("node:sqlite");process.exit(typeof m.DatabaseSync==="function"?0:2)' >/dev/null 2>&1; then
    ok "node:sqlite builtin 可加载（--experimental-sqlite 生效）"
else
    warn "node:sqlite 不可加载"; VERR=$((VERR+1))
fi
PV=$("$NODE" $TIERFLAGS "$TMP/pnpm/bin/pnpm.cjs" --version 2>/dev/null | head -1)
if [ -n "$PV" ]; then ok "纯 JS pnpm 可运行（$PV）—— dsh plugin add 不再 127"; else warn "pnpm 无法运行"; VERR=$((VERR+1)); fi
PBAD=0; PN=0
for pf in "$HOME_DSH/cordis.patch.yml" "$HOME_DSH/patches.yml" \
          "$HOME_DSH"/profiles/*/cordis.patch.yml "$HOME_DSH"/profiles/*/patches.yml; do
    [ -f "$pf" ] || continue
    PN=$((PN+1))
    if grep -qE '^[[:space:]]*\[[[:space:]]*\]' "$pf" 2>/dev/null || \
       grep -qE '^-' "$pf" 2>/dev/null; then :; else PBAD=$((PBAD+1)); fi
done
if [ "$PBAD" -eq 0 ]; then ok "全部 $PN 个 patch 文件顶层为合法数组"; else warn "$PBAD 个 patch 文件顶层非法"; VERR=$((VERR+1)); fi
# +ios15 补丁落地核验
PM="$NM/@deepseek-ai/dsh-plugin-manager/lib/index.js"
MK="$NM/@deepseek-ai/dsh-plugin-market/lib/index.js"
WP="$NM/@deepseek-ai/dsh-plugin-market/lib/worker-parse.cjs"
CJS="$NM/@deepseek-ai/dsh-client-ui-plugin-manager/lib/client.js"
if grep -q 'dsh-ios +ios15' "$PM" 2>/dev/null; then ok "GitHub 手动安装不再依赖 git（预检短路）"; else warn "git 预检短路未落地"; VERR=$((VERR+1)); fi
if grep -q 'redirect: "follow"' "$MK" 2>/dev/null && [ -f "$WP" ]; then ok "插件市场改主线程解析 + redirect follow（不 SIGBUS）"; else warn "插件市场补丁未落地"; VERR=$((VERR+1)); fi
if grep -q '__dshIosTransformSpec' "$CJS" 2>/dev/null && [ -f "$FRONT/assets/dsh-ios-manual-install-transform.js" ]; then ok "手动安装转化逻辑已就位（AI 帮你装不受影响）"; else warn "转化逻辑未落地"; VERR=$((VERR+1)); fi
# 前端 index.html 两个引用
if grep -q 'safari16-polyfill.js' "$FRONT/index.html" 2>/dev/null && \
   grep -q 'dsh-ios-manual-install-transform.js' "$FRONT/index.html" 2>/dev/null; then
    ok "前端 index.html 已引入垫片 + 转化逻辑"
else
    warn "前端 index.html 引用缺失"; VERR=$((VERR+1))
fi
# dsh plugin 真跑一遍检测 127
DP="$HOME_DSH/.fix15-plugin.$$"
"$NODE" $TIERFLAGS --expose-internals "$BIN" plugin --profile web list >"$DP" 2>&1 || true
if grep -qE 'exit code 127|pnpm was not found|command not found|ENOENT: pnpm|SIGBUS|Bus error|killed with' "$DP" 2>/dev/null; then
    warn "dsh plugin 仍报 127 或 SIGBUS"; VERR=$((VERR+1))
else
    ok "dsh plugin 转发链路正常（无 127 / 无 SIGBUS）"
fi
rm -f "$DP" 2>/dev/null || true
PJ="$NM/@deepseek-ai/dsh-session-persistence-jsonl/lib/index.js"
grep -q 'const DEFAULT_COMPRESSION = "none";' "$PJ" 2>/dev/null \
    && ok "会话默认压缩 none（重启不丢对话）" \
    || warn "会话压缩未确认为 none，可跑 sh fix-session.sh"

printf '%s\n' "+ios15" > "$MARK" 2>/dev/null || true
echo
if [ "$VERR" -eq 0 ]; then
    echo "=== +ios15 热修完成。Ctrl+C 退出正在跑的 dsh，再敲 dsh 重启；然后跑 dsh-doctor 复查 ==="
else
    echo "=== 热修已写入但有 $VERR 项未通过；多为写权限问题，用 root 重跑或跑 dsh-doctor 看 23~26 项 ==="
fi
exit 0
'''


def main():
    if len(sys.argv) not in (3, 4):
        raise SystemExit('[FAIL] 用法: make_fix_ios15.py <ROOT> <已注入的 dsh-web-frontend/dist> [输出脚本路径]')
    root = Path(sys.argv[1]).resolve()
    front = Path(sys.argv[2]).resolve()
    payload = root / 'payload' / 'var' / 'jb'
    pnpm = root / 'bundles' / 'pnpm'

    files = {
        'bin/dsh':        payload / 'usr/bin/dsh',
        'bin/dsh-doctor': payload / 'usr/bin/dsh-doctor',
        'bin/pnpm':       payload / 'usr/bin/pnpm',
        'bin/dsh-compat': payload / 'usr/bin/dsh-compat',
        'lib/tier.sh':             payload / 'usr/lib/dsh/tier.sh',
        'lib/dsh-home-heal.cjs':   root / 'shims/dsh-home-heal.cjs',
        'lib/dsh-plugin-compat.cjs': root / 'shims/dsh-plugin-compat.cjs',
        'lib/apply_pnpm_abs_patch.cjs': root / 'shims/apply_pnpm_abs_patch.cjs',
        'lib/apply_plugin_install_patch.cjs': root / 'shims/apply_plugin_install_patch.cjs',
        'lib/apply_frontend_inject.cjs': root / 'shims/apply_frontend_inject.cjs',
        'lib/safari16-polyfill.js': root / 'shims/safari16-polyfill.js',
        'lib/dsh-ios-manual-install-transform.js': root / 'shims/dsh-ios-manual-install-transform.js',
        'web/index.html': front / 'index.html',
        'web/assets/safari16-polyfill.js': front / 'assets/safari16-polyfill.js',
        'web/assets/dsh-ios-manual-install-transform.js': front / 'assets/dsh-ios-manual-install-transform.js',
        'etc/dsh.env':    payload / 'etc/dsh/dsh.env',
    }
    for name, src in files.items():
        if not src.is_file():
            raise SystemExit(f'[FAIL] 缺文件 {src}')

    raw = io.BytesIO()
    with tarfile.open(fileobj=raw, mode='w', format=tarfile.GNU_FORMAT) as tf:
        def add(name, data, mode=0o644):
            ti = tarfile.TarInfo(name)
            ti.size, ti.mtime, ti.mode, ti.uid, ti.gid = len(data), 0, mode, 0, 0
            ti.uname = ti.gname = ''
            tf.addfile(ti, io.BytesIO(data))

        for name, src in sorted(files.items()):
            add(name, src.read_bytes(), 0o755 if name.startswith('bin/') else 0o644)
        count = 0
        for f in sorted(pnpm.rglob('*')):
            if f.is_file():
                rel = 'pnpm/' + str(f.relative_to(pnpm))
                add(rel, f.read_bytes(), 0o755 if f.name == 'pnpm.cjs' else 0o644)
                count += 1
    packed = gzip.compress(raw.getvalue(), compresslevel=9, mtime=0)
    b64 = '\n'.join(textwrap.wrap(base64.b64encode(packed).decode(), 76))
    print(f'pack: tar {raw.tell()} -> gzip {len(packed)} -> b64 {len(b64)} bytes / pnpm {count} files')

    out = HEAD.replace('__B64__', b64)
    if len(sys.argv) == 4:
        # 0.2.2-rc.1 升级包用 fix-ios16.sh，避免覆盖 0.2.1 稳定包的
        # dist/fix-ios15.sh（两者内嵌的 web/index.html 来自不同 DSH 版本）。
        dest = Path(sys.argv[3]).resolve()
        out = out.replace('fix-ios15.sh', dest.name)
        dest.parent.mkdir(parents=True, exist_ok=True)
    else:
        dest = root / 'dist/fix-ios15.sh'
    dest.write_text(out, encoding='utf-8')
    dest.chmod(0o755)
    print(f'written: {dest} ({dest.stat().st_size} bytes)')


if __name__ == '__main__':
    main()
