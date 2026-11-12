#!/bin/sh
# ============================================================================
# tier24.sh —— Node 24 (V8 13.6) 启动档位自动探测，专供 dsh24 实验包
#
# 与稳定包 tier.sh 的区别（重要）：
#   稳定包那五档的参数全是 V8 12.4 (Node 22.12) 的 flag。V8 13.6 里
#   --no-concurrent-sparkplug / --no-wasm-dynamic-tiering / --max-opt=1 /
#   --wasm-num-compilation-tasks 等已改名或移除。给 Node 传一个不认识的
#   flag 会直接 FATAL（不是忽略），所有档位会一起 probe 失败 -> dsh 退 74。
#
#   因此这里不硬编码「哪个 flag 属于哪个版本」，而是在运行时用
#   `"$TIER_NODE" --v8-options` 取出该二进制真正认识的 flag 集合，
#   逐项过滤档位参数：不认识的丢弃，认识的保留。这样上游再升小版本
#   也不用改脚本，且绝不会因未知 flag 崩掉。
#
#   另外 Node 24 的 node:sqlite 已稳定，不再需要 --experimental-sqlite；
#   DrumBrake jitless 档保留 WebAssembly（用解释器），故不用 --no-expose-wasm，
#   也不用 fetch-shim 顶替 WASM。nowasm 档仍保留 shim 作最后兜底。
#
# 档位从优到保守：
#   native    : 无额外参数
#   single    : --single-threaded
#   balanced  : + 禁并发编译 / WASM 单线程（不认识的自动丢）
#   safe      : + 禁并发 GC / 限优化层
#   drumbrake : --jitless --wasm-jitless（DrumBrake WASM 解释器，零 JIT）
#   nowasm    : --jitless --no-expose-wasm --require fetch-shim24.cjs（终极兜底）
# ============================================================================

D=/var/jb/usr/lib/dsh-node24
TIER_NODE=${DSH_NODE:-$D/bin/node}
TIER_SMOKE=$D/smoke24.js
# 独立缓存，绝不读写稳定包的 .dsh-tier
TIER_CACHE=${DSH_HOME:-/var/jb/var/mobile/.dsh}/.dsh-node24-tier

# Node 24 已稳定提供 node:sqlite，不需要任何启动开关
TIER_SQLITE_ARGS=""

TIERS='native|
single|--single-threaded
balanced|--single-threaded --no-concurrent-recompilation --no-concurrent-sparkplug --no-wasm-async-compilation --wasm-num-compilation-tasks=1 --no-wasm-tier-up
safe|--single-threaded --no-concurrent-recompilation --no-concurrent-sparkplug --no-concurrent-sweeping --no-concurrent-marking --no-wasm-async-compilation --wasm-num-compilation-tasks=1 --no-wasm-tier-up --no-wasm-dynamic-tiering --max-opt=1
drumbrake|--jitless --wasm-jitless
nowasm|--jitless --no-expose-wasm --require /var/jb/usr/lib/dsh-node24/fetch-shim24.cjs'

# 生成 v24 认识的 flag 白名单（只取 --xxx 形式的选项名，一次生成缓存到文件）
FLAGLIST="${DSH_HOME:-/var/jb/var/mobile/.dsh}/.dsh-node24-flags"
flag_known() {
    _f_name=$1
    # 去掉 =value 部分，只比对选项名
    _f_opt=${_f_name%%=*}
    case "$_f_opt" in
        --require) return 0 ;;   # Node CLI 参数，不在 --v8-options 里
    esac
    [ -f "$FLAGLIST" ] || return 1
    grep -Fxq -- "$_f_opt" "$FLAGLIST" 2>/dev/null
}

# 过滤掉这个 node 不认识的 flag，保留参数值（如 --require 后面的路径）
filter_args() {
    _f_out=""
    _f_need_value=0
    for _f_a in $1; do
        if [ "$_f_need_value" -eq 1 ]; then
            _f_out="$_f_out $_f_a"; _f_need_value=0; continue
        fi
        case "$_f_a" in
            --require)
                if flag_known "$_f_a"; then _f_out="$_f_out $_f_a"; _f_need_value=1; fi ;;
            --*)
                if flag_known "$_f_a"; then _f_out="$_f_out $_f_a"; fi ;;
            *) _f_out="$_f_out $_f_a" ;;
        esac
    done
    printf '%s' "$_f_out"
}

# CI/首次启动时生成白名单。--v8-options 在 iOS 二进制上也能跑（不执行 JS）。
ensure_flaglist() {
    if [ -f "$FLAGLIST" ]; then return 0; fi
    if [ -x "$TIER_NODE" ] || [ -f "$TIER_NODE" ]; then
        "$TIER_NODE" --v8-options 2>/dev/null \
            | sed -n 's/^[[:space:]]*\(--[A-Za-z0-9_-]*\).*/\1/p' \
            | sort -u > "$FLAGLIST" 2>/dev/null || true
    fi
    [ -s "$FLAGLIST" ] || printf '%s\n' --jitless --wasm-jitless \
        --no-expose-wasm --single-threaded --no-concurrent-recompilation \
        --no-concurrent-sweeping --no-concurrent-marking \
        --no-wasm-async-compilation --no-wasm-tier-up > "$FLAGLIST"
}

# 由档位名取（已过滤的）参数串
tier_args_for() {
    _t_want=$1
    _t_out=""
    while IFS='|' read -r _t_n _t_a; do
        if [ "$_t_n" = "$_t_want" ]; then
            if [ -z "$_t_a" ]; then _t_out=""; else _t_out=$(filter_args "$_t_a"); fi
            break
        fi
    done <<EOF
$TIERS
EOF
    printf '%s' "$_t_out"
}

# 单档冒烟。故意不加引号：参数串需要拆成多个 argv。
tier_probe() {
    # shellcheck disable=SC2086
    "$TIER_NODE" $2 "$TIER_SMOKE" >/dev/null 2>&1
    return $?
}

# 选出可用档位，设置 TIER_NAME / TIER_ARGS / TIER_SOURCE。返回 1 = 全崩。
tier_select() {
    TIER_NAME=""; TIER_ARGS=""; TIER_SOURCE=""
    ensure_flaglist

    # 1) 手动指定
    if [ -n "${DSH_TIER:-}" ]; then
        TIER_NAME=$DSH_TIER
        TIER_ARGS=$(tier_args_for "$TIER_NAME")
        if [ -z "$TIER_NAME" ] || { [ "$TIER_NAME" != native ] && [ -z "$TIER_ARGS" ]; }; then
            return 1
        fi
        TIER_SOURCE=manual
        return 0
    fi

    # 2) 缓存命中
    if [ -f "$TIER_CACHE" ] && [ "${DSH_REPROBE:-0}" != "1" ]; then
        _t_c=$(cat "$TIER_CACHE" 2>/dev/null)
        if [ -n "$_t_c" ]; then
            TIER_NAME=$_t_c
            TIER_ARGS=$(tier_args_for "$TIER_NAME")
            TIER_SOURCE=cached
            return 0
        fi
    fi

    # 3) 逐档真探测。SIGBUS 时 $? 为 138（128+10），继续下一档。
    if [ ! -f "$TIER_SMOKE" ]; then return 1; fi
    while IFS='|' read -r _t_n _t_a; do
        [ -z "$_t_n" ] && continue
        _t_args=""
        [ -n "$_t_a" ] && _t_args=$(filter_args "$_t_a")
        if tier_probe "$_t_n" "$_t_args"; then
            TIER_NAME=$_t_n
            TIER_ARGS=$_t_args
            TIER_SOURCE=probed
            printf '%s\n' "$_t_n" > "$TIER_CACHE" 2>/dev/null || true
            return 0
        fi
    done <<EOF
$TIERS
EOF
    return 1
}
