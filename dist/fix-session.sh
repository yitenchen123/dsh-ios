#!/bin/sh
# ============================================================================
# dsh-ios  +ios8 —— 修「重启 DSH 后上一次的对话不会保留」
#
# 症状：每次 Ctrl+C 重启 dsh / 重开工作台，上一次的对话就消失了，
#       历史会话列表空，或者点进去报会话损坏。
#
# 根因（已在 x86 Linux 按 iOS 目录布局 1:1 复现，见下方实验记录）：
#   +ios2 为兼容包内 Node 22.12（zstd 系列 API 要 22.15+ 才有），把
#   dsh-session-persistence-jsonl 的 zstdCompress / createZstdCompress 等
#   降级成了 gzip 族。但该文件里 DEFAULT_COMPRESSION 仍是 "zstd"：
#
#     写：compressZstdFrame() -> gzip()，帧头 1f 8b 08 ...
#     读：scanZstdFrames() 强制校验 ZSTD_MAGIC = 0xFD2FB528
#         -> "corrupt Zstandard session log: invalid frame magic at byte 0"
#
#   于是会话**写得出、读不回**：文件落在
#     $DSH_HOME/sessions/--<cwd>--/<session-id>/session.v4.jsonl.zstd
#   内容是 gzip，重启时被判损坏，历史列表空 / --session-id 恢复 rc=1。
#   这跟网络、API Key、Safari、A11、QQ 插件都无关，是 +ios2~+ios7
#   本包自己引入的读写不自洽。
#
# 实测复现（修复前）：
#   headless 跑一次 -> session.v4.jsonl.zstd 9679 字节，头 8 字节 1f 8b 08 00
#   重启 --session-id 恢复 -> rc=1
#     dsh: stored session "..." is corrupt: corrupt Zstandard session log:
#          header frame failed validation: invalid frame magic at byte 0
#
# 修法：把 DEFAULT_COMPRESSION 从 "zstd" 改成 "none"，会话日志走明文
#   JSONL。读写都走 SessionLogScanner 明文分支，彻底绕开 zstd/gzip，
#   Node 22.12 自洽。明文约压缩版 3 倍大，但省掉解压 CPU、更好排查；
#   仍与桌面端 dsh 的 zstd 会话不互通（原本就不互通）。
#
#   修复后实测：
#     headless 跑一次 -> session.v4.jsonl 28487 字节，首行 {"type":"session"...
#     重启 --session-id 恢复 -> 正常输出「你好，这是 mock 回复」，0 error
#
# 另外必须处理历史遗留：改成 none 之后，只要 sessions/ 里还留着任何一个
#   *.jsonl.zstd，backend 会在启动时直接拒绝：
#     "session artifact ... uses .jsonl.zstd, but this backend is configured
#      for compression "none""（实测普通启动也 rc=1，不只是恢复时）。
#   所以本脚本会把每个旧文件用**包内 node 的 zlib.gunzipSync** 解成
#   *.jsonl（21/21 行合法 JSONL 已验证），再把原件移到备份目录：
#     $DSH_HOME/sessions-legacy-zstd/<原来的相对路径>
#   两阶段执行：先全部解压校验通过，再统一写入+移走，任一失败就一个文件
#   都不动，绝不静默丢数据。
#
# 用法（iPhone 终端，**建议 root**，包目录归 root）：
#   sudo sh fix-session.sh              修复 + 迁移历史会话（幂等，可重复跑）
#   sh fix-session.sh --status         查看状态
#   sh fix-session.sh --restore-code   仅把代码改回 zstd（排查用，不建议）
#
# ！！！装完必须 Ctrl+C 退出当前 dsh，再重新敲 dsh。
#     刷新网页无效：压缩模式是进程启动时读进 backend 的。
# ============================================================================
set -eu

JB=/var/jb
D="$JB/usr/lib/dsh"
P="$D/node_modules/@deepseek-ai/dsh-session-persistence-jsonl/lib/index.js"
NODE="$D/bin/node"
BIN="$D/node_modules/@deepseek-ai/dsh/lib/bin.js"
ETCD="$JB/etc/dsh"
MARK="$ETCD/.session-fix-applied"
HOME_DSH="${DSH_HOME:-$JB/var/mobile/.dsh}"
SESS="$HOME_DSH/sessions"
BK="$HOME_DSH/sessions-legacy-zstd"
BAK="$P.pre-session-fix.bak"
TMPJS="$HOME_DSH/.fix-session-migrate.cjs"

MODE=install
case "${1:-}" in
    --status)       MODE=status ;;
    --restore-code) MODE=restore ;;
    "")             ;;
    *) echo "用法: sh fix-session.sh [--status|--restore-code]" >&2; exit 2 ;;
esac

# ---- 门禁 ----
if [ ! -L "$JB" ] || [ ! -x "$NODE" ] || [ ! -f "$P" ]; then
    echo "[FAIL] 越狱未激活，或 dsh-ios 的 .deb 没装（找不到 $P）。" >&2
    exit 1
fi

# ---- --status ----
if [ "$MODE" = status ]; then
    if grep -q 'const DEFAULT_COMPRESSION = "none";' "$P" 2>/dev/null; then
        S1='none（已修复）'
    else
        S1='zstd（未修复，重启会丢会话）'
    fi
    NPLAIN=0; NOLD=0; NBK=0
    if [ -d "$SESS" ]; then
        NPLAIN=$(find "$SESS" -type f -name '*.jsonl' 2>/dev/null | wc -l | tr -d ' ')
        NOLD=$(find "$SESS" -type f -name '*.jsonl.zstd' 2>/dev/null | wc -l | tr -d ' ')
    fi
    if [ -d "$BK" ]; then
        NBK=$(find "$BK" -type f -name '*.jsonl.zstd' 2>/dev/null | wc -l | tr -d ' ')
    fi
    echo "会话目录     : $SESS"
    echo "默认压缩模式 : $S1"
    echo "明文会话     : $NPLAIN 个"
    echo "遗留 gzip 会话: $NOLD 个（必须为 0，否则 dsh 启动会失败）"
    echo "已备份原件   : $NBK 个（$BK）"
    exit 0
fi

# ---- --restore-code ----
if [ "$MODE" = restore ]; then
    if [ -f "$BAK" ]; then
        cp "$BAK" "$P"
    elif grep -q 'const DEFAULT_COMPRESSION = "none";' "$P" 2>/dev/null; then
        sed 's/const DEFAULT_COMPRESSION = "none";/const DEFAULT_COMPRESSION = "zstd";/' "$P" > "$P.tmp" && mv "$P.tmp" "$P"
    fi
    rm -f "$MARK"
    echo "[ ok ] 已把代码改回 zstd。注意：这会让会话再次不可读，且明文会话"
    echo "       在 zstd 模式下也可能被 backend 拒绝。仅用于排查，用完请重新"
    echo "       跑一次 sh fix-session.sh。"
    exit 0
fi

# ---- install ----
echo "==> +ios8 修复「重启后对话丢失」（无需重传 deb）"
echo

# 1) 写权限（包目录通常归 root，mobile 身份改不了）
if [ ! -w "$P" ]; then
    echo "[FAIL] 对 $P 没有写权限。" >&2
    echo "       请用 root 运行：sudo sh fix-session.sh" >&2
    exit 1
fi
mkdir -p "$HOME_DSH" "$ETCD" 2>/dev/null || true

# 2) 改默认压缩模式（幂等）
if grep -q 'const DEFAULT_COMPRESSION = "none";' "$P" 2>/dev/null; then
    echo "[skip] 默认压缩已是 none（可能已装 +ios8 或跑过本脚本）"
else
    if ! grep -q 'const DEFAULT_COMPRESSION = "zstd";' "$P" 2>/dev/null; then
        echo "[FAIL] 找不到预期的 DEFAULT_COMPRESSION 定义，依赖树版本可能变了。" >&2
        echo "       为安全起见不做任何改动，请把这句报错发回来。" >&2
        exit 1
    fi
    if [ ! -f "$BAK" ]; then cp "$P" "$BAK" 2>/dev/null || true; fi
    # 不用 sed -i（iOS 是 BSD sed，语法与 GNU 不同），重定向到临时文件再 mv
    sed 's/const DEFAULT_COMPRESSION = "zstd";/const DEFAULT_COMPRESSION = "none";/' "$P" > "$P.tmp"
    mv "$P.tmp" "$P"
    chmod 644 "$P" 2>/dev/null || true
    echo "[ ok ] 默认压缩已改为 none（会话日志改用明文 JSONL）"
fi

# 3) 迁移历史 gzip 会话（用包内 node，不依赖系统 gunzip / python3）
if [ ! -d "$SESS" ]; then
    echo "[skip] 还没有 sessions 目录（尚无历史会话），无需迁移"
else
    NOLD=$(find "$SESS" -type f -name '*.jsonl.zstd' 2>/dev/null | wc -l | tr -d ' ')
    if [ "$NOLD" -eq 0 ]; then
        echo "[skip] 没有遗留的 .jsonl.zstd，无需迁移"
    else
        echo "[ .. ] 发现 $NOLD 个旧 gzip 会话，开始迁移..."
        cat > "$TMPJS" <<'DSH_SESSION_MIGRATE_EOF'
// 一次性迁移脚本：gzip 帧 -> 明文 JSONL，并把原件移出 sessions。
// 两阶段：先全部解压+校验，全部通过才写入/移走；任一失败则一个文件都不动。
const fs = require('node:fs');
const path = require('node:path');
const zlib = require('node:zlib');

const [sess, bk] = process.argv.slice(2);

function walk(dir, out) {
    for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
        const p = path.join(dir, e.name);
        if (e.isDirectory()) walk(p, out);
        else if (e.isFile() && p.endsWith('.jsonl.zstd')) out.push(p);
        else if (e.isSymbolicLink() && p.endsWith('.jsonl.zstd')) out.push(p);
    }
}

const files = [];
walk(sess, files);

// --- 阶段 1：只读，全部解压并校验 ---
const jobs = [];
const errors = [];
for (const p of files) {
    try {
        const raw = fs.readFileSync(p);
        const plain = zlib.gunzipSync(raw);
        const text = plain.toString('utf8').trim();
        if (!text) throw new Error('解压后为空');
        const lines = text.split('\n');
        let head;
        for (let i = 0; i < lines.length; i++) {
            const obj = JSON.parse(lines[i]);
            if (i === 0) head = obj;
        }
        if (!head || head.type !== 'session') throw new Error('首行不是 session 头');
        jobs.push({ p, plain, lines: lines.length, bytes: plain.length });
    } catch (err) {
        errors.push(`${p}: ${err.message}`);
    }
}
if (errors.length) {
    console.error('[FAIL] 以下文件无法安全转换，本次不改动任何文件：');
    for (const e of errors) console.error('  ' + e);
    console.error('       可能是真正的 zstd 文件或已损坏。请把这些路径发回来。');
    process.exit(1);
}

// --- 阶段 2：全部通过，写入明文 + 移走原件 ---
let written = 0, kept = 0;
for (const j of jobs) {
    const target = j.p.slice(0, -'.zstd'.length); // *.jsonl
    if (!fs.existsSync(target)) {
        fs.writeFileSync(target, j.plain, { flag: 'wx' });
        written++;
    } else {
        kept++; // 已有明文（例如上次跑过一半），保留不覆盖
    }
    const rel = path.relative(sess, j.p);
    const dst = path.join(bk, rel);
    fs.mkdirSync(path.dirname(dst), { recursive: true });
    fs.rmSync(dst, { force: true });
    fs.renameSync(j.p, dst);
}
console.log(`[ ok ] 迁移完成: 共 ${files.length} 个, 新写出明文 ${written} 个, `
    + `已有明文保留 ${kept} 个, 每行 JSON 均校验通过`);
DSH_SESSION_MIGRATE_EOF
        if "$NODE" "$TMPJS" "$SESS" "$BK"; then
            rm -f "$TMPJS"
        else
            RC=$?
            rm -f "$TMPJS"
            echo "[FAIL] 迁移失败（旧文件未被改动）。代码已修好，但遗留的 .jsonl.zstd" >&2
            echo "       会让 dsh 启动失败 —— 请把上面的报错发回来，别直接重启 dsh。" >&2
            exit "$RC"
        fi
    fi
fi

# 4) 强校验：这两项任一不满足，dsh 一定起不来或用起来还是丢会话
if ! grep -q 'const DEFAULT_COMPRESSION = "none";' "$P" 2>/dev/null; then
    echo "[FAIL] 默认压缩模式没改成 none，修复未完成。" >&2
    exit 1
fi
NOLD=0
if [ -d "$SESS" ]; then
    NOLD=$(find "$SESS" -type f -name '*.jsonl.zstd' 2>/dev/null | wc -l | tr -d ' ')
fi
if [ "$NOLD" -ne 0 ]; then
    echo "[FAIL] sessions 里仍有 $NOLD 个 .jsonl.zstd，none 模式下 dsh 会启动失败。" >&2
    exit 1
fi
echo "[ ok ] 校验通过：默认压缩 none、无遗留 gzip 会话"

# 5) 轻量动态校验：让 dsh 自己把配置树 dump 出来，确认模块没被改坏。
#    用零 JIT 档参数，避免 A11 上加载内置 undici 的 WASM 触发 SIGBUS；
#    失败只给提示，不阻塞安装。
# +ios10：Node 22.12 的 node:sqlite 需显式开关，否则 dsh-im 整包 import 失败
TIERFLAGS="--experimental-sqlite --disable-warning=ExperimentalWarning"
if [ -f "$D/fetch-shim.cjs" ]; then
    TIERFLAGS="$TIERFLAGS --jitless --no-expose-wasm --require $D/fetch-shim.cjs"
fi
# shellcheck disable=SC2086
if HOME="${HOME:-/var/mobile}" DSH_HOME="$HOME_DSH" "$NODE" $TIERFLAGS \
        --expose-internals "$BIN" --profile web --dump-config >/dev/null 2>&1; then
    echo "[ ok ] dsh 配置树可正常组合（模块语法/加载无误）"
else
    echo "[warn] 动态校验未完成（不影响修复）；可手动跑 dsh --dump-config 看看"
fi

printf '%s\n' "+ios8" > "$MARK" 2>/dev/null || true
echo
echo "==> 完成。接下来必须做："
echo "  1) Ctrl+C 退出当前 dsh，重新敲 dsh（刷新网页无效，压缩模式是启动时读的）"
echo "  2) 之前的历史会话已转成明文，重开工作台后应该能在历史列表里看到"
echo "  3) 旧 gzip 原件备份在 $BK，确认对话都在之后可自行删除"
echo
echo "  查看状态：sh fix-session.sh --status"
echo "  说明：修复后会话以明文存储，体积略大，但仍与桌面端 dsh 不互通。"
exit 0
