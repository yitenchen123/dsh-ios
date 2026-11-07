#!/bin/sh
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
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
3n/ef95/3n/ef95/3n/ef/4/+/w/E8LljACgAAA=
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
