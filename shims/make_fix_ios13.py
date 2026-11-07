#!/usr/bin/env python3
"""
make_fix_ios13.py —— 生成设备端一键热修 dist/fix-ios13.sh

内嵌内容（每次构建从 payload + bundles/pnpm 重新生成，与 deb 字节一致）:
  bin/dsh, bin/dsh-doctor, bin/pnpm, bin/dsh-compat
  lib/tier.sh, lib/dsh-home-heal.cjs, lib/dsh-plugin-compat.cjs,
  lib/apply_pnpm_abs_patch.cjs
  etc/dsh.env
  pnpm/           整个纯 JS pnpm 10.28.2 发行版

设计要点:
  * 已装 +ios12 的设备免重传 125MB deb。
  * 包目录 $D 归 root；若用户以 mobile 跑热修，覆盖包内文件可能失败。
    因此把「用户数据自愈」和「插件兼容补丁」放在最前面、直接从临时目录
    执行 —— 这两项（尤其是无法创建新对话的 EACCES）不依赖任何 root 写权限，
    无论后面覆盖成不成功，都一定修好。
  * 覆盖失败时明确提示用 root 重跑或装新 deb，不再静默假成功。
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
# fix-ios13.sh —— +ios13 设备端热修（已装 +ios12 的设备免重传 125MB deb）
# dsh-ios +ios13: patch 全量清理 + pnpm 绝对路径直连 + 会话树属主自愈
#
# 本版收口真机截图里的三个致命问题（+ios12 引入 / 遗留）：
#  A) 「敲 dsh 直接 fatal uncaught exception」:
#     patches: patches.yml/cordis.patch.yml must be a top-level YAML array
#     +ios12 的 cleanPatch() 删空后把 patch 写成纯注释（js-yaml -> null），
#     还只清 home 级、没清 profiles/*/cordis.patch.yml（残留引用两个已不
#     预装的包 -> headless ERR_MODULE_NOT_FOUND）。本版全量扫描两类文件，
#     整块删目标并强制写回合法 YAML 数组 []，能修复已被删坏的设备。
#  B) 「dsh plugin 仍报 127（pnpm 未找到）」:
#     CLI 与 web service 是两份构建产物，都以 execa('pnpm', ...,
#     {extendEnv:false}) 启动；真机 PATH/shebang 不可靠。本版用
#     apply_pnpm_abs_patch.cjs 就地改成「包内 node + pnpm.cjs」绝对路径直连。
#  C) 「无法创建新对话」EACCES:
#     另一个 AI 用 root + .zshenv 包装器跑过 dsh，把 sessions/ 整棵树建成
#     root 属主；mobile 写不进去 -> gateway 建不了会话 -> 插件「未运行」。
#     本脚本用 rename(2) 免 root 修好属主并迁移历史 *.jsonl（不需 chown）。
#
# 同时保留此前全部修复：tier.sh 自动选档 / nowasm 零 JIT / fetch-shim 幂等
# body / Safari 16 垫片 / 会话默认压缩 none / --experimental-sqlite /
# 所有 dsh-im 副本零 JIT 补丁扫描。装完 dsh-im 后跑 dsh-compat 补补丁。
#
# 用法: sh fix-ios13.sh            # 安装 +ios13 热修
#       sh fix-ios13.sh --status   # 只看状态，不改文件
#       sh fix-ios13.sh --restore # 回滚启动文件到安装前（用户数据不动）
# ============================================================================
set -u
JB=/var/jb
D="$JB/usr/lib/dsh"
NODE="${DSH_NODE:-$D/bin/node}"
NODE_PATH="$D/node_modules"; export NODE_PATH
DSH_NODE="$NODE"; export DSH_NODE
BIN="$D/node_modules/@deepseek-ai/dsh/lib/bin.js"
HOME_DSH="${DSH_HOME:-$JB/var/mobile/.dsh}"
BK="$HOME_DSH/backup-ios12"
MARK="$HOME_DSH/.dsh-ios13"
TMP=/tmp/dsh-fix-ios13.$$
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

echo "=== dsh +ios13 热修 / 修启动 fatal + 修 plugin 127 + 修新建会话 EACCES ==="
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
        warn "sessions 不可写（跑 sh fix-ios13.sh 修复）"
    fi
    if "$NODE" $SQFLAGS -e 'const m=require("node:sqlite");process.exit(typeof m.DatabaseSync==="function"?0:2)' >/dev/null 2>&1; then
        ok "node:sqlite 可加载"
    else
        warn "node:sqlite 不可加载（启动链路缺 --experimental-sqlite）"
    fi
    if [ -x "$JB/usr/bin/pnpm" ] && "$JB/usr/bin/pnpm" --version >/dev/null 2>&1; then
        ok "包内 pnpm 可用（dsh plugin add 可用）"
    elif [ -f "$D/libexec/pnpm/bin/pnpm.cjs" ]; then
        ok "pnpm 文件已就位（命令包装缺失，跑 sh fix-ios13.sh 补齐）"
    else
        warn "缺包内 pnpm（dsh plugin add 仍是 127）"
    fi
    grep -q 'dsh-home-heal' "$JB/usr/bin/dsh" 2>/dev/null \
        && ok "dsh 启动链路已带 +ios13 自愈" \
        || warn "dsh 启动链路仍是 +ios12"
    # +ios13：patch 文件顶层必须是合法 YAML 数组，否则敲 dsh 直接 fatal
    PATCHBAD=0; PATCHN=0
    for pf in "$HOME_DSH/cordis.patch.yml" "$HOME_DSH/patches.yml" \
              "$HOME_DSH"/profiles/*/cordis.patch.yml "$HOME_DSH"/profiles/*/patches.yml; do
        [ -f "$pf" ] || continue
        PATCHN=$((PATCHN+1))
        if grep -qE '^[[:space:]]*\[[[:space:]]*\]' "$pf" 2>/dev/null || \
           grep -qE '^-' "$pf" 2>/dev/null; then :; else PATCHBAD=$((PATCHBAD+1)); fi
    done
    if [ "$PATCHBAD" -eq 0 ]; then
        ok "全部 $PATCHN 个 patch 文件顶层为合法数组（启动不会 fatal）"
    else
        warn "$PATCHBAD 个 patch 文件顶层非法（dsh 会 fatal）；跑 sh fix-ios13.sh 修复"
    fi
    # +ios13：两份构建产物都必须注入 pnpm 绝对路径直连
    PML="$D/node_modules/@deepseek-ai/dsh-plugin-manager/lib"
    if grep -q 'dsh-ios +ios13' "$PML/index.js" 2>/dev/null && \
       grep -q 'dsh-ios +ios13' "$PML/types/operations.js" 2>/dev/null; then
        ok "pnpm 绝对路径直连已注入（CLI + service，dsh plugin 不再 127）"
    else
        warn "pnpm 绝对路径补丁未注入（dsh plugin 仍可能 127）；跑 sh fix-ios13.sh"
    fi
    [ -f "$MARK" ] && ok "已打过 +ios13 热修" || warn "尚未打 +ios13 热修"
    exit 0
fi

# ---- --restore ----
if [ "$MODE" = "--restore" ]; then
    [ -d "$BK" ] || die "没有备份目录 $BK"
    for f in dsh dsh-doctor pnpm dsh-compat; do
        [ -f "$BK/$f" ] && cp "$BK/$f" "$JB/usr/bin/$f" 2>/dev/null \
            && chmod 755 "$JB/usr/bin/$f" 2>/dev/null || true
    done
    for f in tier.sh dsh-home-heal.cjs dsh-plugin-compat.cjs apply_pnpm_abs_patch.cjs; do
        [ -f "$BK/$f" ] && cp "$BK/$f" "$D/$f" 2>/dev/null || true
    done
    [ -f "$BK/dsh.env" ] && cp "$BK/dsh.env" "$JB/etc/dsh/dsh.env" 2>/dev/null || true
    rm -f "$MARK" 2>/dev/null || true
    ok "已回滚启动文件到安装前（用户数据未动；新增的 pnpm/ 目录保留）"
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
    for f in tier.sh dsh-home-heal.cjs dsh-plugin-compat.cjs apply_pnpm_abs_patch.cjs; do
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

cat > "$TMP/pack.b64" <<'DSH_IOS13_B64'
__B64__
DSH_IOS13_B64

if ! "$NODE" -e '
const fs=require("fs"),z=require("zlib");
const s=fs.readFileSync(process.argv[1],"utf8").replace(/\s/g,"");
fs.writeFileSync(process.argv[2],z.gunzipSync(Buffer.from(s,"base64")));
' "$TMP/pack.b64" "$TMP/pack.tar.gz" 2>"$TMP/decode.err"; then
    die "解码失败：$(head -1 "$TMP/decode.err" 2>/dev/null)"
fi
if ! tar xzf "$TMP/pack.tar.gz" -C "$TMP" 2>"$TMP/tar.err"; then
    die "解包失败：$(head -1 "$TMP/tar.err" 2>/dev/null)"
fi
for f in bin/dsh bin/dsh-doctor bin/pnpm bin/dsh-compat lib/tier.sh \
         lib/dsh-home-heal.cjs lib/dsh-plugin-compat.cjs \
         lib/apply_pnpm_abs_patch.cjs etc/dsh.env \
         pnpm/bin/pnpm.cjs pnpm/dist/pnpm.cjs; do
    [ -f "$TMP/$f" ] || die "包内缺 $f"
done
ok "热修包解包完成（含纯 JS pnpm）"

# ---- 3) ★ 用户数据自愈（不依赖包目录写权限，最先做、必定生效） ----
echo
echo "--- 3) 修「无法创建新对话」EACCES（免 root） ---"
"$NODE" "$TMP/lib/dsh-home-heal.cjs" "$HOME_DSH" "$D" 2>&1 | sed 's/^/    /' || true
S="$HOME_DSH/sessions"
mkdir -p "$S" 2>/dev/null || true
PROBE="$S/.fix12-new-session.$$"
if [ -w "$S" ] && (printf '{"v":4}\n' > "$PROBE" 2>/dev/null); then
    rm -f "$PROBE" 2>/dev/null || true
    ok "新建会话文件写入成功（EACCES 已消除）"
else
    warn "sessions 仍不可写；检查 $HOME_DSH 属主（需对 $HOME_DSH 可写才能 rename）"
fi

# ---- 4) ★ 已装 dsh-im 副本补零 JIT 补丁（也从临时目录跑） ----
echo
echo "--- 4) 扫描并补齐设备上所有 dsh-im 副本的零 JIT 补丁 ---"
"$NODE" "$TMP/lib/dsh-plugin-compat.cjs" "$HOME_DSH" "$D/node_modules" 2>&1 \
    | sed 's/^/    /' || true

# ---- 5) 覆盖包内文件（$D 归 root，mobile 身份可能写不进去） ----
echo
echo "--- 5) 覆盖启动文件与内置 pnpm ---"
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
put "$TMP/etc/dsh.env"            "$JB/etc/dsh/dsh.env"    644
# ---- 5b) ★ 给 CLI + service 两份构建产物注入 pnpm 绝对路径直连 ----
#      直接从临时目录跑，补丁脚本用目标文件的 import.meta.url 推导包根，
#      不依赖它在哪个目录。失败计入 FAILW（包目录归 root 时写不进去）。
PML="$D/node_modules/@deepseek-ai/dsh-plugin-manager/lib"
if "$NODE" "$TMP/lib/apply_pnpm_abs_patch.cjs" "$PML" >/dev/null 2>&1; then
    ok "pnpm 绝对路径直连已注入（CLI + service，dsh plugin 不再 127）"
else
    FAILW=$((FAILW+1))
    warn "pnpm 绝对路径补丁应用失败（$PML 归 root 或依赖树版本不符）"
fi
if mkdir -p "$D/libexec/pnpm" 2>/dev/null; then
    if ! cp -R "$TMP/pnpm/." "$D/libexec/pnpm/" 2>/dev/null; then
        FAILW=$((FAILW+1))
    fi
else
    FAILW=$((FAILW+1))
fi
if [ "$FAILW" -eq 0 ]; then
    ok "启动文件 + 内置 pnpm 已全部更新为 +ios13"
else
    warn "$FAILW 项未覆盖：$D 归 root，当前身份（$(id -un 2>/dev/null)）写不进去"
    echo "        完整升级请二选一："
    echo "          sudo sh fix-ios13.sh    或   su root -c 'sh fix-ios13.sh'"
    echo "          或重传安装 +ios13 的 .deb"
    echo "        但上面第 3 步的「新建会话 EACCES 修复」已经生效，不依赖 root。"
fi

# ---- 6) 真跑验证（尽量用临时目录里的副本，不依赖覆盖是否成功） ----
echo
echo "--- 6) 验证 ---"
VERR=0
if "$NODE" $SQFLAGS -e 'const m=require("node:sqlite");process.exit(typeof m.DatabaseSync==="function"?0:2)' >/dev/null 2>&1; then
    ok "node:sqlite builtin 可加载（--experimental-sqlite 生效）"
else
    warn "node:sqlite 不可加载"; VERR=$((VERR+1))
fi
PV=$("$NODE" "$TMP/pnpm/bin/pnpm.cjs" --version 2>/dev/null | head -1)
if [ -n "$PV" ]; then
    ok "纯 JS pnpm 可运行（$PV）—— dsh plugin add 不再 127"
else
    warn "pnpm 无法运行"; VERR=$((VERR+1))
fi
# patch 文件顶层必须是合法 YAML 数组（+ios13 启动 fatal 回归检查）
PBAD=0; PN=0
for pf in "$HOME_DSH/cordis.patch.yml" "$HOME_DSH/patches.yml" \
          "$HOME_DSH"/profiles/*/cordis.patch.yml "$HOME_DSH"/profiles/*/patches.yml; do
    [ -f "$pf" ] || continue
    PN=$((PN+1))
    if grep -qE '^[[:space:]]*\[[[:space:]]*\]' "$pf" 2>/dev/null || \
       grep -qE '^-' "$pf" 2>/dev/null; then :; else PBAD=$((PBAD+1)); fi
done
if [ "$PBAD" -eq 0 ]; then
    ok "全部 $PN 个 patch 文件顶层为合法数组（敲 dsh 不会 fatal）"
else
    warn "$PBAD 个 patch 文件顶层非法（dsh 会 fatal）"; VERR=$((VERR+1))
fi
# dsh plugin 真跑一遍检测 127（补丁从临时目录应用，与包目录覆盖是否成功无关）
DP="$HOME_DSH/.fix13-plugin.$$"
# shellcheck disable=SC2086
"$NODE" $TIERFLAGS --expose-internals "$BIN" plugin --profile web list >"$DP" 2>&1 || true
if grep -qE 'exit code 127|pnpm was not found|command not found|ENOENT: pnpm' "$DP" 2>/dev/null; then
    warn "dsh plugin 仍报 127"; VERR=$((VERR+1))
else
    ok "dsh plugin 转发链路正常（无 127）"
fi
rm -f "$DP" 2>/dev/null || true
# 会话压缩 none（+ios8 回归）
PJ="$D/node_modules/@deepseek-ai/dsh-session-persistence-jsonl/lib/index.js"
grep -q 'const DEFAULT_COMPRESSION = "none";' "$PJ" 2>/dev/null \
    && ok "会话默认压缩 none（重启不丢对话）" \
    || warn "会话压缩未确认为 none，可跑 sh fix-session.sh"

printf '%s\n' "+ios13" > "$MARK" 2>/dev/null || true
echo
if [ "$VERR" -eq 0 ]; then
    echo "=== +ios13 热修完成。Ctrl+C 退出正在跑的 dsh，再敲 dsh 重启；然后跑 dsh-doctor 复查 ==="
else
    echo "=== 热修已写入但有 $VERR 项未通过；跑 dsh-doctor 看第 17/20 项 ==="
fi
exit 0
'''


def main():
    root = Path(sys.argv[1] if len(sys.argv) > 1 else '.').resolve()
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
    dest = root / 'dist/fix-ios13.sh'
    dest.write_text(out, encoding='utf-8')
    dest.chmod(0o755)
    print(f'written: {dest} ({dest.stat().st_size} bytes)')


if __name__ == '__main__':
    main()
