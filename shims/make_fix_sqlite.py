#!/usr/bin/env python3
"""
make_fix_sqlite.py —— 生成 dist/fix-sqlite.sh（+ios10 设备端热修）。

每次 build.sh 都会调用本脚本，把 payload 里**当前**的
    usr/bin/dsh、usr/bin/dsh-doctor、usr/lib/dsh/tier.sh
打进一个 gzip+base64 的自包含 shell 脚本。这样热修包永远与 deb 里的
启动文件字节一致，不会出现「改了 doctor 却忘了重打热修包」的回归。

用法: python3 shims/make_fix_sqlite.py <工程根目录>
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
# fix-sqlite.sh —— +ios10 设备端热修（已装 +ios9 的设备无需重传 125MB deb）
#
# 症状（dsh-doctor 汇总 OK=20 WARN=1 FAIL=1）:
#     [FAIL] headless boot 撞到依赖或插件加载问题
#       -> dsh: warning: 1 extraneous did not activate:
#          xmanrui-dsh-im (@xmanrui/dsh-im): failed to import:
#          Error [ERR_UNKNOWN_BUILTIN_MODULE]: No such built-in module: node:sqlite
#
# 根因: 包内 Node 22.12.0 把 node:sqlite 标为实验性 builtin，必须显式传
#       --experimental-sqlite 才注册；22.13+ 才默认打开（构建机因此漏测）。
#       dsh-im 5.10.0 的 lib/index.js 顶层是静态 ESM import，缺 flag 时
#       整包 import 失败，10 个 IM 渠道全废、网页里也没有「IM机器人」入口。
#       二进制本身已编译进 SQLite（node::sqlite::DatabaseSync），加开关即可
#       零降级修好，不需要删功能、不需要重打包。
#
# 本脚本做 4 件事（幂等，可重复跑）:
#   1) 用包内 node 解出修好的 dsh / dsh-doctor / tier.sh 三个文件并覆盖；
#   2) 补挂 im-qqbot 到 $DSH_HOME/cordis.patch.yml（消掉那条 WARN）；
#   3) 真跑一次 require('node:sqlite') 验证 builtin 已注册；
#   4) 真跑一次 dsh --dump-config，确认 xmanrui-dsh-im / im-qqbot 都激活。
#   原文件备份到 $DSH_HOME/backup-ios9/，`sh fix-sqlite.sh --restore` 可回滚。
#
# 用法: sh fix-sqlite.sh            # 安装 +ios10 热修
#       sh fix-sqlite.sh --status   # 只看状态，不改文件
#       sh fix-sqlite.sh --restore # 回滚到备份
# ============================================================================
set -u
JB=/var/jb
D="$JB/usr/lib/dsh"
NODE="$D/bin/node"
BIN="$D/node_modules/@deepseek-ai/dsh/lib/bin.js"
HOME_DSH="${DSH_HOME:-$JB/var/mobile/.dsh}"
UPATCH="$HOME_DSH/cordis.patch.yml"
QPATCH="$JB/etc/dsh/qqbot.patch.yml"
BK="$HOME_DSH/backup-ios9"
MARK="$HOME_DSH/.dsh-ios10"
TMP=/tmp/dsh-fix-sqlite.$$
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

echo "=== dsh +ios10 热修 / node:sqlite builtin ==="
echo "    node  : $("$NODE" -v 2>/dev/null)"
echo "    DSH_HOME: $HOME_DSH"

# ---- --status ----
if [ "$MODE" = "--status" ]; then
    # shellcheck disable=SC2086
    if "$NODE" $SQFLAGS -e 'const m=require("node:sqlite");process.exit(typeof m.DatabaseSync==="function"?0:2)' >/dev/null 2>&1; then
        ok "node:sqlite 可加载"
    else
        warn "node:sqlite 不可加载（未带 --experimental-sqlite）"
    fi
    if grep -q 'TIER_SQLITE_ARGS' "$JB/usr/bin/dsh" 2>/dev/null; then
        ok "dsh 启动链路已带 +ios10 开关"
    else
        warn "dsh 启动链路仍是 +ios9（跑 sh fix-sqlite.sh 修复）"
    fi
    grep -q 'id: im-qqbot' "$UPATCH" 2>/dev/null && ok "im-qqbot 已挂载" || warn "im-qqbot 未挂载"
    [ -f "$MARK" ] && ok "已打过 +ios10 热修" || warn "尚未打 +ios10 热修"
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
    ok "已回滚到 +ios9 三个启动文件（用户数据未动）"
    exit 0
fi

[ "$MODE" = "install" ] || die "未知参数：$MODE（可用 --status / --restore）"

# ---- 1) 备份（只在第一次，避免二次安装把备份覆盖成已修版本） ----
mkdir -p "$HOME_DSH" 2>/dev/null || true
if [ ! -d "$BK" ]; then
    mkdir -p "$BK" 2>/dev/null || die "无法创建备份目录 $BK"
    cp "$JB/usr/bin/dsh" "$BK/dsh" 2>/dev/null || true
    cp "$JB/usr/bin/dsh-doctor" "$BK/dsh-doctor" 2>/dev/null || true
    cp "$D/tier.sh" "$BK/tier.sh" 2>/dev/null || true
    ok "原文件已备份到 $BK"
else
    ok "备份已存在，保留第一次的原始版本"
fi

# ---- 2) 解出三个修好的启动文件 ----
mkdir -p "$TMP" 2>/dev/null || die "无法创建临时目录"
cleanup(){ rm -rf "$TMP" 2>/dev/null || true; }
trap cleanup EXIT INT TERM

cat > "$TMP/pack.b64" <<'DSH_IOS10_B64'
__B64__
DSH_IOS10_B64

# 用包内 node 解码（不依赖设备上的 base64 / python / gzip 命令行）
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
for f in dsh dsh-doctor tier.sh; do
    [ -f "$TMP/$f" ] || die "包内缺 $f"
done

cp "$TMP/dsh" "$JB/usr/bin/dsh" || die "覆盖 dsh 失败"
cp "$TMP/dsh-doctor" "$JB/usr/bin/dsh-doctor" || die "覆盖 dsh-doctor 失败"
cp "$TMP/tier.sh" "$D/tier.sh" || die "覆盖 tier.sh 失败"
chmod 755 "$JB/usr/bin/dsh" "$JB/usr/bin/dsh-doctor" 2>/dev/null || true
chmod 644 "$D/tier.sh" 2>/dev/null || true
sh -n "$JB/usr/bin/dsh" 2>/dev/null || die "新 dsh 语法错误（已回滚前请检查）"
sh -n "$JB/usr/bin/dsh-doctor" 2>/dev/null || die "新 dsh-doctor 语法错误"
sh -n "$D/tier.sh" 2>/dev/null || die "新 tier.sh 语法错误"
ok "dsh / dsh-doctor / tier.sh 已更新为 +ios10"

# ---- 3) 补挂 im-qqbot（消掉唯一那条 WARN） ----
if [ "${DSH_QQBOT:-1}" != "0" ] && [ -f "$QPATCH" ]; then
    if grep -q 'id: im-qqbot' "$UPATCH" 2>/dev/null; then
        ok "im-qqbot 已挂载，无需改动"
    else
        printf '\n' >> "$UPATCH" 2>/dev/null || true
        if cat "$QPATCH" >> "$UPATCH" 2>/dev/null && grep -q 'id: im-qqbot' "$UPATCH" 2>/dev/null; then
            ok "已补挂 im-qqbot 到 $UPATCH"
        else
            warn "补挂 im-qqbot 失败（可手动跑 sh install-qqbot.sh）"
        fi
    fi
else
    warn "未找到 $QPATCH 或 DSH_QQBOT=0，跳过 QQ Bot 挂载"
fi

# ---- 4) 真跑验证 ----
FAIL=0
# shellcheck disable=SC2086
if "$NODE" $SQFLAGS -e '
const m=require("node:sqlite");
process.exit(typeof m.DatabaseSync==="function"?0:2);
' >/dev/null 2>&1; then
    ok "node:sqlite builtin 已注册（DatabaseSync 可用）"
else
    warn "node:sqlite 仍不可加载 —— 该 node 可能未编译 SQLite，跑 dsh-doctor 看第 18 项"
    FAIL=$((FAIL+1))
fi

# 真跑 dsh 配置树：插件被成功 import 才会出现在 dump 里
DUMP="$TMP/dump.txt"
# shellcheck disable=SC2086
if HOME="${HOME:-/var/mobile}" DSH_HOME="$HOME_DSH" "$NODE" $TIERFLAGS \
        --expose-internals "$BIN" --profile web --dump-config >"$DUMP" 2>"$TMP/dump.err"; then
    if grep -q 'id: xmanrui-dsh-im' "$DUMP" 2>/dev/null; then
        ok "dsh-im 已成功激活（10 渠道可用，零降级）"
    else
        warn "配置树里没有 xmanrui-dsh-im；若未跑过 install-im.sh 属正常"
    fi
    if grep -q 'id: im-qqbot' "$DUMP" 2>/dev/null; then
        ok "im-qqbot 已成功激活"
    else
        warn "配置树里没有 im-qqbot（检查 cordis.patch.yml）"
    fi
else
    warn "配置树未能 dump（不影响热修文件已就位）：$(head -1 "$TMP/dump.err" 2>/dev/null | cut -c1-110)"
fi

printf '%s\n' "+ios10" > "$MARK" 2>/dev/null || true
echo
if [ "$FAIL" -eq 0 ]; then
    echo "=== +ios10 热修完成。Ctrl+C 退出正在跑的 dsh，再敲 dsh 重启；然后跑 dsh-doctor 复查 ==="
else
    echo "=== 热修已写入但有 $FAIL 项未通过，请跑 dsh-doctor 看第 18 项 ==="
fi
exit "$FAIL"
'''


def main(argv):
    if len(argv) != 2:
        print("用法: make_fix_sqlite.py <工程根目录>", file=sys.stderr)
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

    out = root / "dist" / "fix-sqlite.sh"
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(HEAD.replace("__B64__", b64), encoding="utf-8")
    out.chmod(0o755)
    print(f"    +ios10 热修已生成: {out.name} "
          f"(tar {raw.tell()} -> gz {len(pkg)} -> b64 {len(b64)} 字节，内嵌 3 文件与 payload 同步)")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
