#!/usr/bin/env python3
"""
make_fix_ios11.py —— 生成 +ios11 设备端热修（dist/fix-ios11.sh 与 fix-sqlite.sh）。

真机第二轮暴露的两个问题：
  1) /var/jb/usr/bin/dsh: 45: cannot create .../cordis.patch.yml: Permission denied
     —— patch 文件被旧版热修以 root 创建，mobile 用 >> 追加失败，旧代码
        || true 吞掉错误还打印「已挂载」，是假成功。
  2) TypeError: ge.lthashantitampering_new is not a function
     堆栈指向 node_modules/.pnpm/@xmanrui+dsh-im/5.10.0/.../lib/index.js
     —— 旧安装残留的另一份 dsh-im 没打 +ios9 零 JIT 补丁；dpkg 升级只覆盖
        自己清单里的文件，不会清理它。第 17 项只 grep 扁平那份，报假 OK。

本脚本每次 build 都从 payload 重新打一个自包含 shell 包，内嵌当前的
dsh / dsh-doctor / tier.sh，并现场完成：
  - 覆盖 3 个启动文件（原子追加版，root 属主也能修好）
  - 扫描所有 @xmanrui/dsh-im/lib/index.js 并逐份补零 JIT 补丁
  - 重建 cordis.patch.yml 修正属主、补挂两个插件
  - 真跑 headless boot 验证 WASM 补丁与插件激活

同一份内容同时写成 dist/fix-ios11.sh 和 dist/fix-sqlite.sh，避免老用户
误跑旧名的脚本把启动文件刷回 +ios10。

用法: python3 shims/make_fix_ios11.py <工程根目录>
"""
import base64
import gzip
import io
import sys
import tarfile
import textwrap
from pathlib import Path

FILES = {
    "dsh": "payload/var/jb/usr/bin/dsh",
    "dsh-doctor": "payload/var/jb/usr/bin/dsh-doctor",
    "tier.sh": "payload/var/jb/usr/lib/dsh/tier.sh",
}

HEAD = r'''#!/bin/sh
# ============================================================================
# fix-ios11.sh —— +ios11 设备端热修（自包含，免重传 125MB deb）
#
# 修两件事：
#  A) "/var/jb/usr/bin/dsh: 45: cannot create .../cordis.patch.yml: Permission
#     denied" + 假「已挂载」：patch 文件归 root，mobile 用 >> 写不进去。
#     本脚本用「同目录写临时文件 + mv 原子替换」重建它，属主归当前用户；
#     并覆盖成新版 dsh / dsh-doctor，它们也改用原子替换。
#  B) "xmanrui-dsh-im: failed to import: TypeError:
#     ge.lthashantitampering_new is not a function"：真机上还有一份
#     node_modules/.pnpm/@xmanrui+dsh-im/5.10.0/.../lib/index.js（旧安装
#     残留，dpkg 升级不会清理），没打 +ios9 零 JIT 补丁。本脚本扫描设备上
#     所有 @xmanrui/dsh-im/lib/index.js 并逐份补上补丁。
#
# 用法: sh fix-ios11.sh            # 安装热修（幂等）
#       sh fix-ios11.sh --status   # 只看状态
#       sh fix-ios11.sh --restore # 回滚 3 个启动文件
# 注: dist/fix-sqlite.sh 与本文件内容完全相同，跑任意一个效果一致。
# ============================================================================
set -u
JB=/var/jb
D="$JB/usr/lib/dsh"
NODE="$D/bin/node"
BIN="$D/node_modules/@deepseek-ai/dsh/lib/bin.js"
HOME_DSH="${DSH_HOME:-$JB/var/mobile/.dsh}"
UPATCH="$HOME_DSH/cordis.patch.yml"
QPATCH="$JB/etc/dsh/qqbot.patch.yml"
IMPATCH="$D/node_modules/@xmanrui/dsh-im/cordis.patch.yml"
BK="$HOME_DSH/backup-before-ios11"
MARK="$HOME_DSH/.dsh-ios11"
TMP=/tmp/dsh-fix-ios11.$$
MODE="${1:-install}"

ok(){   printf '  [ ok ] %s\n' "$1"; }
warn(){ printf '  [warn] %s\n' "$1"; }
die(){  printf '  [FAIL] %s\n' "$1" >&2; exit 1; }

[ -L "$JB" ] || die "未检测到 rootless 越狱 (/var/jb)；先打开 Dopamine 点 Jailbreak"
[ -x "$NODE" ] || die "缺包内 node：$NODE"
[ -f "$BIN" ] || die "缺 dsh 主程序：$BIN"

SQFLAGS="--experimental-sqlite --disable-warning=ExperimentalWarning"
TIERFLAGS="$SQFLAGS"
[ -f "$D/fetch-shim.cjs" ] && TIERFLAGS="$TIERFLAGS --jitless --no-expose-wasm --require $D/fetch-shim.cjs"

# 原子 patch 追加：同目录建临时文件再 mv，能替换属主为 root 的旧文件。
patch_append() {
    _pa_src=$1; _pa_id=$2
    _pa_tmp="$HOME_DSH/.cordis.patch.fix.$$"
    [ -f "$_pa_src" ] || return 1
    if grep -q "id: $_pa_id" "$UPATCH" 2>/dev/null; then return 0; fi
    if [ -f "$UPATCH" ]; then
        { cat "$UPATCH"; printf '\n'; cat "$_pa_src"; } > "$_pa_tmp" 2>/dev/null \
            || { rm -f "$_pa_tmp" 2>/dev/null; return 1; }
    else
        cat "$_pa_src" > "$_pa_tmp" 2>/dev/null \
            || { rm -f "$_pa_tmp" 2>/dev/null; return 1; }
    fi
    if ! mv "$_pa_tmp" "$UPATCH" 2>/dev/null; then
        rm -f "$UPATCH" 2>/dev/null || true
        mv "$_pa_tmp" "$UPATCH" 2>/dev/null \
            || { rm -f "$_pa_tmp" 2>/dev/null; return 1; }
    fi
    return 0
}

scan_im() {
    find "$D/node_modules" "$HOME_DSH" -maxdepth 14 \
         -path '*/@xmanrui/dsh-im/lib/index.js' -type f 2>/dev/null | sort -u
}

echo "=== dsh +ios11 热修 / patch 属主 + 全副本零 JIT 补丁 ==="
echo "    node  : $("$NODE" -v 2>/dev/null)"
echo "    DSH_HOME: $HOME_DSH"

# ---- --status ----
if [ "$MODE" = "--status" ]; then
    # shellcheck disable=SC2086
    if "$NODE" $SQFLAGS -e 'const m=require("node:sqlite");process.exit(typeof m.DatabaseSync==="function"?0:2)' >/dev/null 2>&1; then
        ok "node:sqlite 可加载"
    else
        warn "node:sqlite 不可加载"
    fi
    if grep -q 'patch_append' "$JB/usr/bin/dsh" 2>/dev/null; then
        ok "dsh 已是 +ios11 原子追加版"
    else
        warn "dsh 仍是旧版（跑 sh fix-ios11.sh）"
    fi
    if [ -f "$UPATCH" ] && [ ! -w "$UPATCH" ]; then
        warn "$UPATCH 当前用户不可写（跑 sh fix-ios11.sh 重建）"
    else
        ok "$UPATCH 可写"
    fi
    TOT=0; BAD=0
    for f in $(scan_im); do
        TOT=$((TOT+1))
        grep -q 'dsh-ios +ios9' "$f" 2>/dev/null || BAD=$((BAD+1))
    done
    if [ "$TOT" -eq 0 ]; then warn "未找到 dsh-im 副本"
    elif [ "$BAD" -eq 0 ]; then ok "全部 $TOT 份 dsh-im 副本已打零 JIT 补丁"
    else warn "$BAD/$TOT 份 dsh-im 副本缺补丁（跑 sh fix-ios11.sh）"; fi
    for id in xmanrui-dsh-im im-qqbot; do
        grep -q "id: $id" "$UPATCH" 2>/dev/null && ok "$id 已挂载" || warn "$id 未挂载"
    done
    [ -f "$MARK" ] && ok "已打过 +ios11 热修" || warn "尚未打 +ios11 热修"
    exit 0
fi

# ---- --restore ----
if [ "$MODE" = "--restore" ]; then
    [ -d "$BK" ] || die "没有备份目录 $BK"
    for f in dsh dsh-doctor tier.sh; do
        case "$f" in
            tier.sh) DEST="$D/tier.sh" ;;
            *)       DEST="$JB/usr/bin/$f" ;;
        esac
        [ -f "$BK/$f" ] || { warn "备份缺 $f，跳过"; continue; }
        cp "$BK/$f" "$DEST" || die "恢复 $DEST 失败"
        chmod 755 "$DEST" 2>/dev/null || true
    done
    rm -f "$MARK" 2>/dev/null || true
    ok "已回滚 3 个启动文件（dsh-im 副本补丁与用户数据保留）"
    exit 0
fi

[ "$MODE" = "install" ] || die "未知参数：$MODE（可用 --status / --restore）"

mkdir -p "$HOME_DSH" 2>/dev/null || true
if [ ! -d "$BK" ]; then
    mkdir -p "$BK" 2>/dev/null || die "无法创建备份 $BK"
    cp "$JB/usr/bin/dsh" "$BK/dsh" 2>/dev/null || true
    cp "$JB/usr/bin/dsh-doctor" "$BK/dsh-doctor" 2>/dev/null || true
    cp "$D/tier.sh" "$BK/tier.sh" 2>/dev/null || true
    ok "启动文件已备份到 $BK"
else
    ok "备份已存在，保留第一次的原始版本"
fi

mkdir -p "$TMP" 2>/dev/null || die "无法创建临时目录"
cleanup(){ rm -rf "$TMP" 2>/dev/null || true; }
trap cleanup EXIT INT TERM

# ---- 1) 覆盖 3 个启动文件 ----
cat > "$TMP/pack.b64" <<'DSH_IOS11_B64'
__B64__
DSH_IOS11_B64

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
for f in dsh dsh-doctor tier.sh; do [ -f "$TMP/$f" ] || die "包内缺 $f"; done
cp "$TMP/dsh" "$JB/usr/bin/dsh" || die "覆盖 dsh 失败"
cp "$TMP/dsh-doctor" "$JB/usr/bin/dsh-doctor" || die "覆盖 dsh-doctor 失败"
cp "$TMP/tier.sh" "$D/tier.sh" || die "覆盖 tier.sh 失败"
chmod 755 "$JB/usr/bin/dsh" "$JB/usr/bin/dsh-doctor" 2>/dev/null || true
chmod 644 "$D/tier.sh" 2>/dev/null || true
sh -n "$JB/usr/bin/dsh" 2>/dev/null || die "新 dsh 语法错误"
sh -n "$JB/usr/bin/dsh-doctor" 2>/dev/null || die "新 dsh-doctor 语法错误"
sh -n "$D/tier.sh" 2>/dev/null || die "新 tier.sh 语法错误"
ok "dsh / dsh-doctor / tier.sh 已更新为 +ios11（原子追加版）"

# ---- 2) 扫描所有 dsh-im 副本，逐份补零 JIT 补丁 ----
cat > "$TMP/patch.cjs" <<'DSH_IM_PATCH_EOF'
const fs = require('node:fs');
const p = process.argv[2];
let s;
try { s = fs.readFileSync(p, 'utf8'); } catch (e) { console.error('[FAIL] 读不到 ' + p); process.exit(1); }
if (s.includes('dsh-ios +ios9')) { console.log('[skip] 已打补丁'); process.exit(0); }
const TOP = 'var JCe=new VC;';
const FIN = 'let e=JCe.subtractThenAdd(t,a,o);';
const NEWTOP = 'var JCe=null;try{JCe=new VC}catch(_dshImWasmErr){}/* dsh-ios +ios9: libsignal WASM unavailable */';
const NEWFIN = 'let e=JCe?JCe.subtractThenAdd(t,a,o):Buffer.alloc(128);/* dsh-ios +ios9: degrade */';
const c1 = s.split(TOP).length - 1, c2 = s.split(FIN).length - 1;
if (c1 === 1 && c2 === 1) {
  s = s.replace(TOP, NEWTOP).replace(FIN, NEWFIN);
} else {
  // 兜底：变量名被改写过的构建。先由 subtractThenAdd 反查单例变量名。
  const mm = /let\s+([A-Za-z_$][\w$]*)=([A-Za-z_$][\w$]*)\.subtractThenAdd\(([^)]*)\);/.exec(s);
  if (!mm) { console.error('[FAIL] 找不到 subtractThenAdd 收尾，拒绝打坏包'); process.exit(1); }
  const V = mm[2];
  const topRe = new RegExp('var\\s+' + V + '=new\\s+([A-Za-z_$][\\w$]*);');
  const tm = topRe.exec(s);
  if (!tm) { console.error('[FAIL] 找不到 ' + V + ' 的顶层构造，拒绝打坏包'); process.exit(1); }
  s = s.replace(tm[0], 'var ' + V + '=null;try{' + V + '=new ' + tm[1] + '}catch(_dshImWasmErr){}/* dsh-ios +ios9: libsignal WASM unavailable */');
  s = s.replace(mm[0], 'let ' + mm[1] + '=' + V + '?' + V + '.subtractThenAdd(' + mm[3] + '):Buffer.alloc(128);/* dsh-ios +ios9: degrade */');
}
fs.writeFileSync(p, s);
console.log('[ ok ] 已打零 JIT 补丁');
DSH_IM_PATCH_EOF

IMTOT=0; IMOK=0; IMSKIP=0; IMFAIL=0
for f in $(scan_im); do
    IMTOT=$((IMTOT+1))
    R=$("$NODE" "$TMP/patch.cjs" "$f" 2>&1)
    case "$R" in
        *'已打零 JIT 补丁'*) IMOK=$((IMOK+1));   printf '  [ ok ] 补丁 -> %s\n' "$(printf '%s' "$f" | sed "s|$D/||")" ;;
        *'[skip]'*)          IMSKIP=$((IMSKIP+1)) ;;
        *)                   IMFAIL=$((IMFAIL+1)); warn "补丁失败 $f : $(printf '%s' "$R" | head -1)" ;;
    esac
done
if [ "$IMTOT" -eq 0 ]; then
    warn "未找到任何 dsh-im 副本（若尚未装 dsh-im 属正常）"
else
    ok "dsh-im 副本共 $IMTOT 份：新打 $IMOK / 已有 $IMSKIP / 失败 $IMFAIL"
    [ "$IMFAIL" -eq 0 ] || warn "有副本补丁失败，把上面这行回传给我"
fi

# ---- 3) 重建 cordis.patch.yml（修属主 + 补挂两个插件） ----
if [ -f "$UPATCH" ] && [ ! -w "$UPATCH" ]; then
    if cp "$UPATCH" "$TMP/patch.yml" 2>/dev/null && mv "$TMP/patch.yml" "$UPATCH" 2>/dev/null; then
        ok "已重建 $UPATCH（属主修正为当前用户，内容不变）"
    else
        warn "无法重建 $UPATCH；若后续仍报 Permission denied，请 sudo chown mobile:mobile $UPATCH"
    fi
else
    ok "$UPATCH 当前用户可写"
fi
if [ "${DSH_QQBOT:-1}" != "0" ] && [ -f "$QPATCH" ]; then
    if patch_append "$QPATCH" im-qqbot; then ok "im-qqbot 已挂载"; else warn "补挂 im-qqbot 失败"; fi
fi
if [ "${DSH_IM:-1}" != "0" ] && [ -f "$IMPATCH" ]; then
    if patch_append "$IMPATCH" xmanrui-dsh-im; then ok "xmanrui-dsh-im 已挂载"; else warn "补挂 xmanrui-dsh-im 失败"; fi
fi

# ---- 4) 真跑验证 ----
FAIL=0
# shellcheck disable=SC2086
if "$NODE" $SQFLAGS -e 'const m=require("node:sqlite");process.exit(typeof m.DatabaseSync==="function"?0:2)' >/dev/null 2>&1; then
    ok "node:sqlite builtin 已注册"
else
    warn "node:sqlite 不可加载"; FAIL=$((FAIL+1))
fi

BAD2=0; TOT2=0
for f in $(scan_im); do
    TOT2=$((TOT2+1)); grep -q 'dsh-ios +ios9' "$f" 2>/dev/null || BAD2=$((BAD2+1))
done
if [ "$TOT2" -gt 0 ] && [ "$BAD2" -eq 0 ]; then
    ok "全部 $TOT2 份 dsh-im 副本均带零 JIT 补丁"
elif [ "$TOT2" -gt 0 ]; then
    warn "仍有 $BAD2 份副本缺补丁"; FAIL=$((FAIL+1))
fi

# 真 boot 一次：这是唯一能证明 WASM 补丁生效的检查
BL="$TMP/boot.log"
# shellcheck disable=SC2086
DEEPSEEK_API_KEY=sk-fix-ios11-check HOME="${HOME:-/var/mobile}" DSH_HOME="$HOME_DSH" \
    "$NODE" $TIERFLAGS --expose-internals "$BIN" headless ping >"$BL" 2>&1 &
BPID=$!
i=0
while [ "$i" -lt 18 ]; do
    grep -qiE '401|api key|authentication|AUTH:|failed to import|lthashantitampering' "$BL" 2>/dev/null && break
    kill -0 "$BPID" 2>/dev/null || break
    sleep 1; i=$((i+1))
done
kill "$BPID" 2>/dev/null || true
wait "$BPID" 2>/dev/null || true
if grep -qiE 'lthashantitampering|ge\.[a-z_]+ is not a function|failed to import' "$BL" 2>/dev/null; then
    warn "真 boot 仍有插件 import 失败：$(grep -iE 'failed to import|lthashantitampering' "$BL" | head -1 | cut -c1-110)"
    FAIL=$((FAIL+1))
elif grep -qiE '401|api key|authentication|AUTH:' "$BL" 2>/dev/null; then
    ok "真 boot 穿过全部启动阶段，无 WASM import 失败（到达模型层 401）"
else
    warn "真 boot 未在窗口内归类（可能是无网络；不影响已写入的文件）"
fi

printf '%s\n' "+ios11" > "$MARK" 2>/dev/null || true
echo
if [ "$FAIL" -eq 0 ]; then
    echo "=== +ios11 热修完成。Ctrl+C 退出正在跑的 dsh，再敲 dsh；然后跑 dsh-doctor 复查 ==="
else
    echo "=== 已写入但有 $FAIL 项待确认，跑 dsh-doctor 看第 19 项 ==="
fi
exit "$FAIL"
'''


def main(argv):
    if len(argv) != 2:
        print("用法: make_fix_ios11.py <工程根目录>", file=sys.stderr)
        return 1
    root = Path(argv[1])
    for name, rel in FILES.items():
        if not (root / rel).is_file():
            print(f"[FAIL] 缺源文件: {root / rel}", file=sys.stderr)
            return 1

    raw = io.BytesIO()
    with tarfile.open(fileobj=raw, mode="w", format=tarfile.GNU_FORMAT) as tf:
        for name, rel in sorted(FILES.items()):
            data = (root / rel).read_bytes()
            ti = tarfile.TarInfo(name)
            ti.size, ti.mtime, ti.mode = len(data), 0, 0o644
            ti.uid = ti.gid = 0
            ti.uname = ti.gname = ""
            tf.addfile(ti, io.BytesIO(data))
    pkg = gzip.compress(raw.getvalue(), compresslevel=9, mtime=0)
    b64 = "\n".join(textwrap.wrap(base64.b64encode(pkg).decode(), 76))
    body = HEAD.replace("__B64__", b64)

    dist = root / "dist"
    dist.mkdir(parents=True, exist_ok=True)
    # 两个名字写同一份内容：老用户跑 fix-sqlite.sh 也不会把启动文件刷回 +ios10。
    for name in ("fix-ios11.sh", "fix-sqlite.sh"):
        out = dist / name
        out.write_text(body, encoding="utf-8")
        out.chmod(0o755)
        print(f"    +ios11 热修已生成: {name} ({out.stat().st_size} 字节)")
    print(f"    内嵌 3 启动文件与 payload 同步 (tar {raw.tell()} -> gz {len(pkg)} 字节)")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
