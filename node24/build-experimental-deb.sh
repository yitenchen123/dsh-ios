#!/bin/sh
# ---------------------------------------------------------------------------
# build-experimental-deb.sh —— 把「CI 编出的 node24 二进制 + dsh 0.2.2-rc.2
# 依赖树 + node24/payload」组装成旁路实验 deb。
#
# 输入（都可选环境变量覆盖）：
#   NODE24_BIN   CI 产出的 iOS arm64 node（默认 node24/dist/node-v24.22.3-iphoneos-arm64）
#   NM_TREE      rc.2 依赖树目录（默认 node24/.build/node_modules）
#   NM_BUNDLE    rc.2 依赖树 tar.gz（若 NM_TREE 不存在则从此解包）
#
# 输出：node24/dist/dev.airdevs.dsh-node24_0.2.2-rc.2+ios24exp1_iphoneos-arm64.deb
#
# 硬约束：
#   * 绝不写 dist/*.deb 或 dist/SHA256SUMS.txt（默认交付物字节不变）
#   * 实验 deb 内只出现 /var/jb/usr/lib/dsh-node24/ 与 /var/jb/usr/bin/dsh24*
#   * 打包段完整复用 build.sh 的 mode 归一化 + SOURCE_DATE_EPOCH + dpkg-deb -Zgzip -z9
#
# 用法: sh node24/build-experimental-deb.sh
#       NODE24_BIN=/path/to/node sh node24/build-experimental-deb.sh
# ---------------------------------------------------------------------------
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
N="$ROOT/node24"
DSH_VER="${DSH_VER:-0.2.2-rc.2}"
VER="${DSH_VER}+ios24exp1"
STAGE="$N/.build/stage"
OUT="$N/dist/dev.airdevs.dsh-node24_${VER}_iphoneos-arm64.deb"
NODE24_BIN="${NODE24_BIN:-$N/dist/node-v24.22.3-iphoneos-arm64}"
NM_TREE="${NM_TREE:-$N/.build/node_modules}"
NM_BUNDLE="${NM_BUNDLE:-$ROOT/bundles/dsh-nodemodules-${DSH_VER}+ios1.tar.gz}"
SDE="${SOURCE_DATE_EPOCH:-1700000000}"

echo "=== 组装 Node 24 实验 deb（旁路）==="
echo "    包: dev.airdevs.dsh-node24  $VER"
echo "    依赖树: $NM_TREE"

# --- 0a. 自动发现 CI 产物 ---
# gh run download 解出的 artifact 文件名取决于 upload-artifact 的公共根计算
# （可能是 node，也可能是 out/Release/node）；Release draft 里则叫
# node-v24.22.3-iphoneos-arm64-jitless。与其依赖文件名约定，不如在
# node24/dist 下找「>20MB 且 arm64 Mach-O」的那个文件，避免组装卡住。
if [ ! -s "$NODE24_BIN" ]; then
    echo "    默认路径无 node，尝试在 $N/dist 下自动发现 CI 产物 ..."
    CAND=""
    # 本仓库路径不含空格，for $(find) 安全；magic 与大小双重校验防误选
    for p in $(find "$N/dist" -type f \( -name node -o -name 'node-v*' \) -size +20M 2>/dev/null); do
        M=$(od -An -tx1 -N4 "$p" 2>/dev/null | tr -d ' \n')
        if [ "$M" = "cffaedfe" ]; then CAND="$p"; break; fi
    done
    [ -n "$CAND" ] || {
        echo "在 $N/dist 下未找到 arm64 Mach-O node 产物。" >&2
        echo "  先下载 CI artifact，或显式指定 NODE24_BIN=/path/to/node" >&2
        exit 1
    }
    NODE24_BIN="$CAND"
    echo "    自动发现: $NODE24_BIN"
fi
echo "    node: $NODE24_BIN"

# --- 0. 前置校验 ---
[ -s "$NODE24_BIN" ] || { echo "缺 node24 二进制: $NODE24_BIN" >&2; echo "  先跑 GitHub Actions 编译并下载产物。" >&2; exit 1; }
# Mach-O 头必须是 iOS arm64 (cf fa ed fe)，防止误把 x86 node 打进包
MAGIC=$(od -An -tx1 -N4 "$NODE24_BIN" 2>/dev/null | tr -d ' \n')
[ "$MAGIC" = "cffaedfe" ] || { echo "node24 不是 arm64 Mach-O (magic=$MAGIC)" >&2; exit 1; }
echo "    Mach-O magic OK ($MAGIC)"
# 占位/截断防护：真实 node 可执行文件至少 20MB，冒烟测试用的 4KB 头必须拒绝
NSIZE=$(wc -c < "$NODE24_BIN" | tr -d '[:space:]')
[ "$NSIZE" -gt 20000000 ] || {
    echo "node24 只有 $NSIZE 字节 —— 疑似占位/截断文件，拒绝组装（真实 node >= 20MB）" >&2
    exit 1
}
echo "    node 大小 OK ($NSIZE 字节)"

if [ ! -d "$NM_TREE" ]; then
    [ -s "$NM_BUNDLE" ] || { echo "缺 rc.2 依赖树 bundle: $NM_BUNDLE" >&2; exit 1; }
    mkdir -p "$N/.build"
    echo "    解包依赖树 ..."
    tar xzf "$NM_BUNDLE" -C "$N/.build"
fi
[ -f "$NM_TREE/@deepseek-ai/dsh/package.json" ] || { echo "依赖树缺 dsh 主包" >&2; exit 1; }
# 版本核对
GOT=$(sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$NM_TREE/@deepseek-ai/dsh/package.json" | head -1)
[ "$GOT" = "$DSH_VER" ] || { echo "依赖树 dsh 版本是 ${GOT}，期望 $DSH_VER" >&2; exit 1; }
echo "    dsh 版本 OK ($GOT)"
# 依赖树不得含原生 addon
NADDON=$(find "$NM_TREE" -name '*.node' | wc -l)
[ "$NADDON" -eq 0 ] || { echo "依赖树含 $NADDON 个 .node 原生模块，中止" >&2; exit 1; }

# --- 1. 清理并搭建 stage ---
rm -rf "$STAGE"; mkdir -p "$STAGE"
DST="$STAGE/var/jb/usr/lib/dsh-node24"
mkdir -p "$DST/bin" "$STAGE/var/jb/usr/bin" "$STAGE/DEBIAN" "$N/dist"

cp "$NODE24_BIN" "$DST/bin/node"; chmod 755 "$DST/bin/node"
cp -a "$NM_TREE" "$DST/node_modules"
cp -a "$N/DEBIAN/control" "$STAGE/DEBIAN/control"
cp -a "$N/DEBIAN/postinst" "$STAGE/DEBIAN/postinst"; chmod 755 "$STAGE/DEBIAN/postinst"
# prerm：卸载时清实验档位缓存，绝不动 DSH_HOME 里的插件/会话
cat > "$STAGE/DEBIAN/prerm" <<'EOF'
#!/bin/sh
set -e
JB=/var/jb
H="${DSH_HOME:-$JB/var/mobile/.dsh}"
rm -f "$H/.dsh-node24-tier" "$H/.dsh-node24-flags" 2>/dev/null || true
rm -f "$JB/usr/bin/dsh24" "$JB/usr/bin/dsh24.disabled" 2>/dev/null || true
echo "dsh-node24: 已移除实验入口；稳定包 dsh 与 DSH_HOME 中的插件/对话未动。"
exit 0
EOF
chmod 755 "$STAGE/DEBIAN/prerm"

# payload 全部落实验目录
for f in ent.plist tier24.sh fetch-shim24.cjs smoke24.js; do
    cp -a "$N/payload/$f" "$DST/$f"
done
# 启动器 / 切换器 / doctor 落 /var/jb/usr/bin，名字带 24 前缀
cp -a "$N/payload/dsh24" "$STAGE/var/jb/usr/bin/dsh24"; chmod 755 "$STAGE/var/jb/usr/bin/dsh24"
cp -a "$N/payload/dsh24-switch" "$STAGE/var/jb/usr/bin/dsh24-switch"; chmod 755 "$STAGE/var/jb/usr/bin/dsh24-switch"
cp -a "$N/payload/dsh-doctor-node24" "$STAGE/var/jb/usr/bin/dsh-doctor-node24"; chmod 755 "$STAGE/var/jb/usr/bin/dsh-doctor-node24"
# README 放进包内供设备上查阅
cp -a "$N/README.md" "$DST/README.md"

echo "==> 固定 stage mode / 时间戳 / 属主（与 build.sh 同一套可复现规则）"
find "$STAGE" -type d -exec chmod 755 {} +
find "$STAGE" -type f -perm /100 -exec chmod 755 {} +
find "$STAGE" -type f '!' -perm /100 -exec chmod 644 {} +
chown -R 0:0 "$STAGE" 2>/dev/null || true
find "$STAGE" -depth -exec touch -h -d "@$SDE" {} + 2>/dev/null || \
    find "$STAGE" -depth -exec touch -h -t "$(date -u -r "$SDE" +%Y%m%d%H%M.%S 2>/dev/null || echo 202311142013.20)" {} + 2>/dev/null || true

echo "==> dpkg-deb 组装"
SOURCE_DATE_EPOCH="$SDE" dpkg-deb -b -Zgzip -z9 "$STAGE" "$OUT"

echo
echo "完成: $OUT"
echo "大小: $(du -sh "$OUT" | cut -f1)"
SHA=$(sha256sum "$OUT" | cut -d' ' -f1)
echo "SHA-256: $SHA"
{
    echo "# Node 24 实验包（旁路，A11 真机未验证）—— 独立于 dist/SHA256SUMS.txt"
    echo "# 构建: CI 产出 node + dsh $DSH_VER 依赖树 + node24/payload"
    echo "# 默认 +ios15 / +ios16 / APP 三个 deb 的 SHA 见 dist/SHA256SUMS.txt，未改动。"
    echo "$SHA  dev.airdevs.dsh-node24_${VER}_iphoneos-arm64.deb"
} > "$N/dist/SHA256SUMS-node24.txt"

# --- 2. 包内路径隔离断言 ---
echo "==> 包内路径隔离校验"
LIST=$(dpkg-deb -c "$OUT" 2>/dev/null)
echo "$LIST" | grep -q 'var/jb/usr/lib/dsh/bin/node' && \
    { echo "实验包内含稳定包 node 路径 —— 中止" >&2; exit 1; }
echo "$LIST" | grep -q 'var/jb/usr/lib/dsh-node24/bin/node' || \
    { echo "实验包内缺实验 node —— 中止" >&2; exit 1; }
echo "    隔离 OK（只写 dsh-node24/ 与 dsh24*）"
echo "    校验清单: $N/dist/SHA256SUMS-node24.txt"
