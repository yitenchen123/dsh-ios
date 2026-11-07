#!/bin/sh
# ============================================================================
# dsh-tier.sh —— V8 启动档位自动探测（被 dsh / dsh-doctor 共同 source）
#
# 背景（+ios3）：
#   iPhone X / A11 / iOS 16.7.15 / Dopamine rootless 上，dsh 一进入真 boot
#   就会调用全局 fetch，进而加载 Node 内置 undici 的 llhttp WebAssembly。
#   V8 默认在后台线程编译 WASM / 优化代码，而 iOS 的
#   pthread_jit_write_protect_np 是「按线程」生效的，后台线程没有可写权限，
#   写可执行代码页即 SIGBUS —— 表现就是截图里的 `zsh: bus error  dsh`。
#   轻量命令（--version / --dump-default-config）不碰 WASM，所以全 OK；
#   doctor 原来那个 2e5 次循环的 JIT 探针只测了 JS 优化编译，给了假绿灯。
#
# 解法不是猜一个 flag，而是让设备自己试：
#   每档启动前跑 smoke.js（不联网，但真触发 WASM 编译 + HTTP 往返），
#   选第一个能过的档位，缓存到 $DSH_HOME/.dsh-tier，之后零开销。
#   最后一档 nowasm 用 --jitless + fetch-shim，完全不分配可执行内存，
#   从原理上杜绝 SIGBUS，功能是实测过的（web 监听 / headless 到 401）。
#
# 档位从优到保守（性能 -> 确定性）：
#   native   : 无额外参数（设备本来正常时用满性能）
#   single   : --single-threaded（编译收回主线程，保 WASM 与全部功能）
#   balanced : + 禁并发编译 / WASM 编译单线程
#   safe     : + 禁并发 GC / 限优化层
#   nowasm   : --jitless + fetch-shim，完全不生成可执行代码（终极兜底）
#
# +ios4 补充：nowasm 档加 --no-expose-wasm。V8 在 --jitless 下会自动禁用
#   --expose_wasm 并每次启动打印一行
#     Warning: disabling flag --expose_wasm due to conflicting flags
#   功能无害但会污染终端输出（截图里可见）。显式声明后警告消失，实测
#   smoke / --version / headless(401) / web 监听结果完全一致。
# ============================================================================

D=/var/jb/usr/lib/dsh
TIER_NODE=${DSH_NODE:-$D/bin/node}
TIER_SMOKE=$D/smoke.js
TIER_CACHE=${DSH_HOME:-/var/jb/var/mobile/.dsh}/.dsh-tier

# +ios10 —— node:sqlite 的启动开关（dsh / dsh-doctor 共用）
# ---------------------------------------------------------------------------
# 包内 Node 22.12.0 已把 SQLite 编译进二进制（strings 可见
# node::sqlite::DatabaseSync / sqlite3_open），但 22.12 仍把 node:sqlite 标为
# 实验性：只有显式传 --experimental-sqlite 才注册这个 builtin。22.13+ 才默认
# 打开，构建机是 22.13.1 所以离线验证全是绿灯，真机 22.12.0 一跑就露出来。
#
# @xmanrui/dsh-im 5.10.0 的 lib/index.js 顶层是静态 ESM：
#     import { DatabaseSync as sLe } from "node:sqlite";
# 静态 import 没法 try/catch，缺 flag 时 Node 直接抛
#     ERR_UNKNOWN_BUILTIN_MODULE: No such built-in module: node:sqlite
# 整包 import 失败 -> Cordis 报 "1 extraneous did not activate"。
# 这是 +ios9 在 A11 真机上唯一剩下的 FAIL。加 flag 即可零降级修好
# （dsh-im 的 SQLite 缓存完整可用，不必打任何降级补丁）。
#
# --disable-warning=ExperimentalWarning 只压掉那行 "SQLite is an
# experimental feature" 提示，不改变功能；22.12 二进制里确认有该开关。
TIER_SQLITE_ARGS="--experimental-sqlite --disable-warning=ExperimentalWarning"

# 每行一段：档位名|node 参数（参数为空表示不加）
TIERS='native|
single|--single-threaded
balanced|--single-threaded --no-concurrent-recompilation --no-concurrent-sparkplug --no-wasm-async-compilation --wasm-num-compilation-tasks=1 --no-wasm-tier-up
safe|--single-threaded --no-concurrent-recompilation --no-concurrent-sparkplug --no-concurrent-sweeping --no-concurrent-marking --no-wasm-async-compilation --wasm-num-compilation-tasks=1 --no-wasm-tier-up --no-wasm-dynamic-tiering --max-opt=1
nowasm|--jitless --no-expose-wasm --require /var/jb/usr/lib/dsh/fetch-shim.cjs'

# 由档位名取参数串。here-doc 的 while 在当前 shell 执行，变量能带出来。
tier_args_for() {
    _t_want=$1
    _t_out=""
    while IFS='|' read -r _t_n _t_a; do
        if [ "$_t_n" = "$_t_want" ]; then _t_out=$_t_a; break; fi
    done <<EOF
$TIERS
EOF
    printf '%s' "$_t_out"
}

# 单档冒烟。故意不加引号：参数串需要拆成多个 argv。
tier_probe() {
    _t_name=$1
    # shellcheck disable=SC2086
    "$TIER_NODE" $2 "$TIER_SMOKE" >/dev/null 2>&1
    return $?
}

# 选出可用档位，设置 TIER_NAME / TIER_ARGS / TIER_SOURCE。返回 1 = 全崩。
tier_select() {
    TIER_NAME=""; TIER_ARGS=""; TIER_SOURCE=""

    # 1) 手动指定（dsh.env 或命令行 DSH_TIER=...）
    if [ -n "${DSH_TIER:-}" ]; then
        TIER_NAME=$DSH_TIER
        TIER_ARGS=$(tier_args_for "$TIER_NAME")
        if [ -z "$TIER_NAME" ] || { [ "$TIER_NAME" != native ] && [ -z "$TIER_ARGS" ]; }; then
            return 1
        fi
        TIER_SOURCE=manual
        return 0
    fi

    # 2) 缓存命中（doctor 会设 DSH_REPROBE=1 强制重探）
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
        if tier_probe "$_t_n" "$_t_a"; then
            TIER_NAME=$_t_n
            TIER_ARGS=$_t_a
            TIER_SOURCE=probed
            printf '%s\n' "$_t_n" > "$TIER_CACHE" 2>/dev/null || true
            return 0
        fi
    done <<EOF
$TIERS
EOF
    return 1
}
