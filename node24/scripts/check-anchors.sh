#!/bin/sh
# ---------------------------------------------------------------------------
# check-anchors.sh —— 编译前校验 Node 源码补丁锚点是否命中
#
# 为什么需要：ios-source-fixups*.sh 里的补丁全是「精确字符串替换」，任一
# 锚点在目标 Node 版本里改了写法，脚本就会 raise SystemExit 让编译中止。
# OpenClaw 的锚点是按 v24.18.0 验证的，而本项目按用户要求用更新的
# v24.22.3。与其等到 macOS CI 跑 100 分钟才炸，不如先把源码对应文件
# 逐条 grep —— 这是确定性检查。
#
# 两种输入源（优先 SRC_DIR）：
#   1) SRC_DIR=/path/to/node-src  —— CI 用。直接读刚 clone 下来的本地源码树，
#      零联网、零平台依赖，且校验的正是随后要打补丁的那一份源码。
#      用法: SRC_DIR=node-src NODE_REF=v24.22.3 sh check-anchors.sh
#   2) 不设 SRC_DIR              —— 本地 Linux 沙箱用。从 GitHub 拉 13 个
#      文件到 /tmp 缓存再查；带 .ok 完整性标记、原子 mv、失败重试。
#      用法: sh check-anchors.sh                 # 默认 v24.22.3
#            NODE_REF=v24.18.0 sh check-anchors.sh
#            sh check-anchors.sh --offline      # 用 /tmp 已缓存文件，不联网
#
# 跨平台注意（2026-11-13 修 CI 失败）：
#   * macOS GitHub-hosted runner 没有 GNU `timeout`；curl 用自带 --max-time，
#     gh api 不加 timeout（CI 有 job 级 timeout-minutes 兜底）。
#   * macOS BSD `base64` 解码是 -D，不是 GNU -d；统一改用 python3 解码。
#   * macOS BSD `stat` 是 -f%z，不是 GNU -c%s；统一改用 wc -c。
#
# 退出码: 0=全部锚点命中；1=任一失配（禁止继续编译，除非人工确认回退）。
# ---------------------------------------------------------------------------
set -eu

NODE_REF="${NODE_REF:-v24.22.3}"
FALLBACK_REF="${FALLBACK_REF:-v24.18.0}"
SRC_DIR="${SRC_DIR:-}"
RAW="https://raw.githubusercontent.com/nodejs/node/${NODE_REF}"
CACHE="/tmp/dsh-node24-anchors-${NODE_REF}"
OFFLINE=0
[ "${1:-}" = "--offline" ] && OFFLINE=1

mkdir -p "$CACHE" 2>/dev/null || true

# 把一个仓库相对路径解析成实际可读文件：
#   SRC_DIR 模式 -> $SRC_DIR/<原路径>（clone 出来的目录结构与上游一致）
#   缓存模式     -> $CACHE/<把 / 换成 _ 的扁平文件名>
resolve() {
    if [ -n "$SRC_DIR" ]; then
        printf '%s/%s\n' "$SRC_DIR" "$1"
    else
        printf '%s/%s\n' "$CACHE" "$(echo "$1" | tr '/' '_')"
    fi
}

# 跨平台取文件字节数（macOS BSD stat 没有 -c%s）
fsize() { wc -c < "$1" 2>/dev/null | tr -d '[:space:]'; }

echo "=== Node 24 iOS 补丁锚点自检 ==="
echo "    NODE_REF = $NODE_REF"
echo "    FALLBACK = ${FALLBACK_REF}（仅人工确认后使用）"
if [ -n "$SRC_DIR" ]; then
    echo "    SRC_DIR  = ${SRC_DIR}（本地源码树，零联网）"
else
    echo "    RAW      = $RAW"
    echo "    CACHE    = $CACHE"
fi
echo

# 需要检查的源码文件（与两份 fixups 里 patch()/replace() 的路径一一对应）
FILES="tools/gyp/pylib/gyp/generator/make.py
src/crypto/crypto_context.cc
common.gypi
deps/v8/src/base/platform/platform-posix.cc
deps/v8/src/base/build_config.h
deps/v8/src/base/platform/platform.h
deps/v8/src/base/platform/platform-darwin.cc
deps/v8/src/heap/code-range.cc
deps/v8/src/wasm/wasm-code-manager.cc
deps/v8/src/objects/backing-store.cc
tools/v8_gypfiles/features.gypi
tools/v8_gypfiles/v8.gyp
deps/cares/config/darwin/ares_config.h"

if [ -n "$SRC_DIR" ]; then
    echo "--- [1/3] 定位本地源码文件（SRC_DIR 模式，不联网）---"
else
    echo "--- [1/3] 拉取源码文件 ---"
fi
FAIL_FETCH=0
for f in $FILES; do
    # SRC_DIR 模式：只读本地 clone 出来的源码树；缺文件立即报错，
    # 绝不偷偷退化到联网（那样就失去了「校验真实编译源」的意义）。
    if [ -n "$SRC_DIR" ]; then
        p="$SRC_DIR/$f"
        if [ -s "$p" ]; then
            printf '  [local] %-62s %s B\n' "$f" "$(fsize "$p")"
        else
            echo "  [FAIL ] 本地源码树缺文件: $f  ($p)" >&2; FAIL_FETCH=1
        fi
        continue
    fi

    out="$(resolve "$f")"
    # 只有带 .ok 标记的缓存才算完整（curl 超时可能留下半截文件，早期版本
    # 曾把 4197B 的 v8.gyp 残片当成有效缓存，导致锚点假失配）。
    if [ -s "$out" ] && [ -f "$out.ok" ]; then
        printf '  [cache] %-62s %s B\n' "$f" "$(fsize "$out")"
        continue
    fi
    if [ "$OFFLINE" -eq 1 ]; then
        echo "  [FAIL ] 离线模式但缺缓存: $f" >&2; FAIL_FETCH=1; continue
    fi
    # 主通道用 GitHub contents API（base64），比 raw.githubusercontent.com
    # 的 curl 在本沙箱里稳定得多；raw 仅作兜底。先写 .part 再原子 mv，
    # 避免半截文件污染缓存。全部命令在 macOS / Linux 上行为一致。
    ok=0
    for try in 1 2 3; do
        # 不用 GNU timeout（macOS 无）；用 python3 跨平台 base64 解码
        # （macOS BSD base64 要 -D，GNU 要 -d，python3 两边一致）。
        if gh api "repos/nodejs/node/contents/$f?ref=$NODE_REF" \
                --jq '.content' 2>/dev/null \
                | tr -d '\n' \
                | python3 -c 'import sys,base64; sys.stdout.buffer.write(base64.b64decode(sys.stdin.read()))' \
                > "$out.part" 2>/dev/null \
                && [ -s "$out.part" ]; then
            mv "$out.part" "$out"; : > "$out.ok"
            printf '  [ ok  ] %-62s %s B  (api, try %s)\n' "$f" "$(fsize "$out")" "$try"
            ok=1; break
        fi
        # 兜底：curl 自带 --max-time，不依赖外部 timeout 命令。
        if curl -fsSL --retry 2 --retry-delay 1 --max-time 60 \
                "$RAW/$f" -o "$out.part" 2>/dev/null && [ -s "$out.part" ]; then
            mv "$out.part" "$out"; : > "$out.ok"
            printf '  [ ok  ] %-62s %s B  (raw, try %s)\n' "$f" "$(fsize "$out")" "$try"
            ok=1; break
        fi
        rm -f "$out.part"
    done
    if [ "$ok" -ne 1 ]; then
        echo "  [FAIL ] 3 次重试后仍取不到: $f" >&2; FAIL_FETCH=1
    fi
done
[ "$FAIL_FETCH" -eq 0 ] || { echo "取源阶段失败，无法自检" >&2; exit 1; }
echo

# 锚点表：文件 | 锚点文本 | 用途说明
# 用 TAB 分隔，锚点里不含 TAB。grep -F 精确字面匹配，避免正则转义问题。
ANCHORS_FILE="$CACHE/anchors.tsv"
cat > "$ANCHORS_FILE" <<'ANCHORS'
tools/gyp/pylib/gyp/generator/make.py	 -Wl,--start-group	gyp make 链接模板剥离（通用 iOS 适配）
src/crypto/crypto_context.cc	#ifdef __APPLE__	keychain CA reader 收窄为 TARGET_OS_OSX
common.gypi	['OS=="mac"', {	framework 注入锚点
deps/v8/src/base/platform/platform-posix.cc	#if V8_OS_DARWIN	MAP_JIT 段（A11 APRR 跳过，仍校验存在）
deps/v8/src/base/build_config.h	V8_HAS_PTHREAD_JIT_WRITE_PROTECT	pre-APRR 补丁（A11 跳过）
deps/v8/src/base/platform/platform.h	V8_BASE_EXPORT void SetJitWriteProtected(int enable);	platform.h 声明
deps/v8/src/heap/code-range.cc	#include "src/utils/allocation.h"	code-range 头文件注入
deps/v8/src/objects/backing-store.cc	guard	WASM guard-region 锚点（两版补丁各自变体）
deps/cares/config/darwin/ares_config.h	#define HAVE_SYS_RANDOM_H 1	c-ares iOS SDK 缺失头
tools/v8_gypfiles/features.gypi	    # Sets -dV8_ENABLE_WEBASSEMBLY.	features.gypi 变量声明锚点
tools/v8_gypfiles/features.gypi	      ['v8_enable_webassembly==1', {	features.gypi defines 锚点
tools/v8_gypfiles/v8.gyp	v8_base_without_compiler	DrumBrake .cc 注入位置
tools/v8_gypfiles/v8.gyp	v8_internal_headers	DrumBrake 7 个 header 注入位置
tools/v8_gypfiles/v8.gyp	v8_initializers_slow	arm64 interpreter builtin 注入位置
ANCHORS

echo "--- [2/3] 逐条锚点命中 ---"
HIT=0; MISS=0
while IFS="$(printf '\t')" read -r f a note; do
    [ -n "$f" ] || continue
    case "$f" in \#*) continue;; esac
    out="$(resolve "$f")"
    if grep -Fq -- "$a" "$out" 2>/dev/null; then
        printf '  [HIT ] %-58s | %s\n' "$f" "$note"
        HIT=$((HIT+1))
    else
        printf '  [MISS] %-58s | %s\n' "$f" "$note" >&2
        printf '         锚点: %s\n' "$a" >&2
        MISS=$((MISS+1))
    fi
done < "$ANCHORS_FILE"
echo

# backing-store.cc 的两版补丁锚点（JIT 版用 bool guards，DrumBrake 版用 has_guard_regions）
echo "--- [3/3] 版本敏感锚点（两版补丁各自的精确替换目标）---"
BS="$(resolve deps/v8/src/objects/backing-store.cc)"
V24_GUARD='bool has_guard_regions ='
V22_GUARD='bool guards = trap_handler::IsTrapHandlerEnabled()'
if grep -Fq -- "$V24_GUARD" "$BS" 2>/dev/null; then
    echo "  [HIT ] backing-store.cc 用 V8 13.6 变量名 has_guard_regions（DrumBrake 版锚点匹配）"
    HIT=$((HIT+1))
elif grep -Fq -- "$V22_GUARD" "$BS" 2>/dev/null; then
    echo "  [HIT ] backing-store.cc 用旧变量名 guards（JIT 版锚点匹配）"
    HIT=$((HIT+1))
else
    echo "  [MISS] backing-store.cc 守卫变量名既非 has_guard_regions 也非 guards" >&2
    MISS=$((MISS+1))
fi

# wasm-code-manager.cc 的 E1 锚点：上游 JIT 版补丁里写的
#   `PageAllocator::Permission permission = PageAllocator::kReadWriteExecute;`
# 在 V8 13.6（v24.18.0 与 v24.22.3 皆是）已改成直接把 kReadWriteExecute
# 传给 SetPermissions，变量声明消失 —— 该锚点在上游验证版本就已失配。
# 但这段补丁属于「pre-APRR (A9/A10) mprotect W^X」整套，本仓库用
# DSH_APRR=1 守卫整段跳过；主推的 DrumBrake jitless 版更完全不含它。
# 因此这里只记录、不作为阻断条件，但必须打印出来供人复核（不能静默）。
echo
echo "--- [补充] APRR 跳过段的锚点（不参与 A11 编译，仅记录）---"
WCM="$(resolve deps/v8/src/wasm/wasm-code-manager.cc)"
E1='PageAllocator::Permission permission = PageAllocator::kReadWriteExecute;'
if grep -Fq -- "$E1" "$WCM" 2>/dev/null; then
    echo "  [SKIP] wasm-code-manager.cc E1 锚点存在，但整段补丁被 DSH_APRR=1 跳过"
elif grep -Fq 'PageAllocator::kReadWriteExecute' "$WCM" 2>/dev/null; then
    echo "  [SKIP] wasm-code-manager.cc E1 锚点已漂移（V8 13.6 改为直接传参），"
    echo "         但整段 pre-APRR 补丁被 DSH_APRR=1 跳过，不影响 A11 编译。"
    echo "         实测 v24.18.0 同样漂移，即上游 JIT 版该补丁本身已不适用 V8 13.6。"
else
    echo "  [WARN] wasm-code-manager.cc 里连 kReadWriteExecute 都找不到，V8 结构变化较大，"
    echo "         CI 编译前建议人工复核 JIT 版补丁（主推 jitless 版不受影响）。"
fi

echo
echo "=== 结果: HIT=$HIT  MISS=$MISS  (NODE_REF=$NODE_REF) ==="
if [ "$MISS" -gt 0 ]; then
    echo "=== 结论：锚点失配 ✘  禁止直接用 $NODE_REF 编译 ===" >&2
    echo "    处理：逐条核对上游 diff；确属版本漂移则改 fixups 锚点，或在人工确认后" >&2
    echo "          用 NODE_REF=$FALLBACK_REF sh check-anchors.sh 复核已验证版本。" >&2
    exit 1
fi
echo "=== 结论：全部锚点命中 ✔  可进入 macOS CI 编译 ==="
echo "    注意：锚点命中只证明『补丁能打上』，不证明编译通过、更不证明 A11 真机能跑。"
exit 0
