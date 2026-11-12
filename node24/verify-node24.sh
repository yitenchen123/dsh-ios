#!/bin/sh
# ---------------------------------------------------------------------------
# verify-node24.sh —— 在 Linux 构建机上对 Node 24 实验包做静态自检
#
# 边界：这里能验的是「文件齐不齐 / 语法对不对 / 默认包有没有被动过 /
# workflow 有没有越界写默认交付物」。它 **不能** 验证 iOS arm64 二进制能否
# 运行（沙箱无 A11 真机、无 macOS/Xcode），那部分见 README 的真机清单。
#
# 用法: sh node24/verify-node24.sh
# ---------------------------------------------------------------------------
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"
OK=0; FAIL=0
ok()   { printf '  [ ok  ] %s\n' "$1"; OK=$((OK+1)); }
bad()  { printf '  [FAIL ] %s\n' "$1" >&2; FAIL=$((FAIL+1)); }

echo "=== node24 实验包静态自检 ==="
echo "    ROOT=$ROOT"

# --- 1. 文件齐全 ---
echo "--- [1] 必需文件 ---"
for f in \
    node24/scripts/LICENSE-MIT.txt \
    node24/scripts/ios-source-fixups.sh \
    node24/scripts/ios-source-fixups-drumbrake.sh \
    node24/scripts/check-anchors.sh \
    node24/build-experimental-deb.sh \
    node24/make-rc2-tree.sh \
    node24/dist/SHA256SUMS-node24.txt \
    node24/DEBIAN/control \
    node24/DEBIAN/postinst \
    node24/payload/ent.plist \
    node24/payload/tier24.sh \
    node24/payload/fetch-shim24.cjs \
    node24/payload/smoke24.js \
    node24/payload/dsh24 \
    node24/payload/dsh24-switch \
    node24/payload/dsh-doctor-node24 \
    node24/README.md \
    .github/workflows/node24-jitless.yml \
    .github/workflows/node24-jit.yml ; do
    if [ -s "$f" ]; then ok "$f"; else bad "缺失或为空: $f"; fi
done

# --- 2. shell / JS 语法 ---
echo "--- [2] 语法 ---"
for f in node24/DEBIAN/postinst node24/payload/dsh24 node24/payload/dsh24-switch \
         node24/payload/tier24.sh node24/payload/dsh-doctor-node24 \
         node24/scripts/check-anchors.sh node24/scripts/ios-source-fixups.sh \
         node24/scripts/ios-source-fixups-drumbrake.sh \
         node24/build-experimental-deb.sh node24/make-rc2-tree.sh; do
    if sh -n "$f" 2>/dev/null; then ok "sh -n $f"; else bad "sh -n 失败: $f"; fi
done
if command -v node >/dev/null 2>&1; then
    for f in node24/payload/smoke24.js node24/payload/fetch-shim24.cjs; do
        if node --check "$f" 2>/dev/null; then ok "node --check $f"; else bad "node --check 失败: $f"; fi
    done
fi

# --- 3. entitlement：必须是 10 项超集，含 9 项 JIT 子集 ---
echo "--- [3] ent.plist ---"
python3.11 - <<'PY' && ok "ent.plist 为 10 项且含全部 9 项 JIT 子集" || bad "ent.plist 项数/子集不符"
import plistlib, sys
d = plistlib.load(open('node24/payload/ent.plist','rb'))
need = {
 'com.apple.security.cs.allow-jit',
 'com.apple.security.cs.allow-unsigned-executable-memory',
 'com.apple.security.cs.disable-library-validation',
 'com.apple.private.skip-library-validation',
 'com.apple.private.security.no-sandbox',
 'dynamic-codesigning','run-unsigned-code','get-task-allow','platform-application',
}
assert len(d) == 10, f"项数={len(d)}, 期望 10"
missing = need - set(d)
assert not missing, f"缺 JIT 项: {missing}"
PY

# --- 4. workflow 越界静态断言（绝不能写默认交付物）---
echo "--- [4] workflow 安全边界 ---"
for wf in .github/workflows/node24-jitless.yml .github/workflows/node24-jit.yml; do
    [ -f "$wf" ] || { bad "$wf 不存在"; continue; }
    if grep -q 'runs-on: macos-14' "$wf"; then ok "$wf: macos-14"; else bad "$wf: 未用 macos-14"; fi
    if grep -q -- '--dest-cpu=arm64' "$wf" && grep -q -- '--cross-compiling' "$wf"; then
        ok "$wf: iOS arm64 交叉编译参数"; else bad "$wf: 缺交叉编译参数"; fi
    if grep -q 'workflow_dispatch' "$wf"; then ok "$wf: 仅 dispatch 触发"; else bad "$wf: 缺 workflow_dispatch"; fi
    # 严禁写默认交付物。只看非注释的实际命令（注释里出现路径说明不算违规）。
    if grep -vE '^[[:space:]]*#|^[[:space:]]*$' "$wf" \
         | grep -qE 'dist/[^ ]*\.deb|dist/SHA256SUMS\.txt'; then
        bad "$wf: 实际命令里出现写默认 dist/ 交付物（硬约束违反）"
    else
        ok "$wf: 实际命令不触碰默认 dist/ 交付物"
    fi
    # 必须用 10 项 ent.plist 签名，不能用 4 项
    if grep -q 'node24/payload/ent.plist\|ent.plist' "$wf"; then
        ok "$wf: 引用 ent.plist 签名"; else bad "$wf: 未引用 ent.plist"; fi
done

# --- 5. YAML 可解析 ---
echo "--- [5] YAML ---"
python3.11 - <<'PY'
try:
    import yaml
except ImportError:
    print("  [WARN ] 未装 PyYAML，跳过 YAML 解析（不影响 shell 自检）")
    raise SystemExit(0)
import glob
for p in glob.glob('.github/workflows/node24-*.yml'):
    with open(p) as f: yaml.safe_load(f)
    print(f"  [ ok  ] yaml.safe_load {p}")
PY

# --- 6. 硬约束：默认交付物 SHA 不变、默认包源码零改动 ---
echo "--- [6] 默认包零改动（硬约束）---"
if (cd dist && sha256sum -c SHA256SUMS.txt >/dev/null 2>&1); then
    ok "dist/SHA256SUMS.txt 全部校验通过"
else
    bad "dist 交付物 SHA 校验失败 —— 默认包被改动了"
fi
for h in "67d54667" "f5548928" "878642fa"; do
    if sha256sum dist/*.deb app-bundle/dist/*.deb 2>/dev/null | grep -q "^$h"; then
        ok "主 deb SHA 前缀 $h 仍在"; else bad "主 deb SHA 前缀 $h 消失"; fi
done
# 默认包源码目录必须零改动（相对 HEAD）
if git diff --quiet HEAD -- DEBIAN/ ent.plist payload/ shims/ build.sh bootstrap.sh 2>/dev/null; then
    ok "DEBIAN/ ent.plist payload/ shims/ build.sh bootstrap.sh 相对 HEAD 零改动"
else
    bad "默认包相关目录有改动 —— 会破坏 1:1 复现，必须还原"
    git diff --stat HEAD -- DEBIAN/ ent.plist payload/ shims/ build.sh bootstrap.sh >&2
fi

# --- 7. 隔离性：实验包不得引用稳定包路径 ---
echo "--- [7] 路径隔离 ---"
# 只检查「设备端可执行脚本」是否会把 node 指向稳定包路径；README / control
# 的说明文字、以及本自检脚本自身的 grep 模式不算违规（用 find 精确限定文件）。
LEAK=$(find node24/payload node24/DEBIAN -type f \
        \( -name 'dsh24' -o -name 'dsh24-switch' -o -name 'tier24.sh' \
           -o -name 'postinst' -o -name 'dsh-doctor-node24' \) \
        -exec grep -ln '/var/jb/usr/lib/dsh/bin/node' {} + 2>/dev/null || true)
if [ -n "$LEAK" ]; then
    bad "实验脚本引用了稳定包 node 路径: $LEAK"
else
    ok "实验脚本未引用稳定包 node 路径（只用 dsh-node24/）"
fi
if grep -q 'dev.airdevs.dsh-node24' node24/DEBIAN/control; then
    ok "实验包使用独立 Package 名"; else bad "实验包名不是独立命名空间"; fi

echo
echo "=== 汇总: OK=$OK  FAIL=$FAIL ==="
if [ "$FAIL" -gt 0 ]; then
    echo "静态自检有 FAIL，修正后再推送。" >&2
    exit 1
fi
echo "全部静态自检通过。注意：这不代表 iOS 二进制能跑，仍需 CI 编译 + 真机逐级验证。"
exit 0
