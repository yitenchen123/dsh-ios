#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""把 stage 内的 +ios15 运行时就地改造成「Node 24 / rc.3」感知版本。

只改 dpkg stage 里的副本，绝不碰仓库 payload/ 与 shims/ —— 那些文件同时
被稳定底座 build.sh 和 make_fix_ios15.py 使用，动一个字节就会改变已发布的
+ios15 deb SHA（用户要求稳定底座逐字节不动）。

真机截图（+ios24 / iPhone X / A11）暴露的三个文件级根因：

1) tier.sh 的 nowasm 档带 --no-expose-wasm。这个 V8 flag 在 Node 24.19.0
   已被删除，`node --jitless --no-expose-wasm ...` 直接 `bad option` 退出 9。
   A11 上 native/single/balanced/safe 四档全部 SIGBUS(138)，唯一能活的零 JIT
   档就是 nowasm —— 它被这一个废参数挡死，于是 `dsh` 报
   「所有 V8 启动档位都在 WASM 冒烟探针里失败了」并 Bus error: 10。
2) dsh-doctor 硬编码 +ios15 / Node 22.12.0 的 101,297,040 字节 / 0.2.1-rc.5
   版本号，并且大量短命检查裸跑 `$NODE`（不带零 JIT 参数），在 A11 上
   每一条都 SIGBUS -> 12 个 FAIL 大部分是误报 + 连锁失败。
3) usr/bin/pnpm 的 PFLAGS 也带 --no-expose-wasm，pnpm 必然退出 9；
   dsh-compat、dsh-app-ctl ping、dsh-home-heal、各 apply_*.cjs 同样裸跑 node。

修法：
  * 去掉所有 --no-expose-wasm；
  * 新增 node-safe 启动器（--jitless + fetch-shim.cjs），所有短命 node 调用
    统一走它；dsh 主进程仍由 tier.sh 逐档探测（A14+ 可用原生 JIT，A11 自动
    落到 nowasm）；
  * doctor 的版本/大小断言改成 Node 24 / rc.3 感知，会话压缩一项按 Node
    主版本分流（Node 24 原生支持 zstd，不需要 +ios8 降级）；
  * dsh wrapper 与 doctor 在全部档位都失败时兜底到 nowasm，而不是直接放弃。

每一次文本替换都带「锚点命中次数」断言，锚点漂移立即中止构建，
绝不产出「补丁没打上但看起来像打过」的包。
"""
import os
import sys

STAGE = sys.argv[1]
D = os.path.join(STAGE, "var/jb/usr/lib/dsh")
B = os.path.join(STAGE, "var/jb/usr/bin")


def path(*parts):
    return os.path.join(*parts)


def read(p):
    with open(p, "r", encoding="utf-8", newline="") as f:
        return f.read()


def write(p, s, mode=None):
    with open(p, "w", encoding="utf-8", newline="") as f:
        f.write(s)
    if mode is not None:
        os.chmod(p, mode)


def sub(s, old, new, count=1, label=""):
    n = s.count(old)
    assert n == count, "锚点 %s 命中 %d 次（应为 %d）: %r" % (label, n, count, old[:90])
    return s.replace(old, new)


# ---------------------------------------------------------------- 0) node-safe
NODE_SAFE = path(D, "node-safe")
write(NODE_SAFE, '''#!/bin/sh
# +ios24 零 JIT 通用启动器（短命工具用；dsh 主进程由 tier.sh 逐档探测）
# A11 / iOS 16.7 rootless 上 Node 24 的原生 JIT 会 SIGBUS(10)。--jitless 让
# V8 完全不生成可执行代码；fetch-shim.cjs 补上 jitless 下被移除的
# WebAssembly 全局，并用 node:http 原生 llhttp 顶替内置 undici 的 WASM 解析器。
# 注意：绝不能加 --no-expose-wasm —— Node 24 / V8 13.x 已删除该 flag，
# 传了就是 `bad option` 退出 9（真机截图 nowasm rc=9 的根因）。
D=/var/jb/usr/lib/dsh
exec "$D/bin/node" --jitless --require "$D/fetch-shim.cjs" "$@"
''', 0o755)

# ---------------------------------------------------------------- 1) tier.sh
p = path(D, "tier.sh")
s = read(p)
s = sub(s, """# +ios4 补充：nowasm 档加 --no-expose-wasm。V8 在 --jitless 下会自动禁用
#   --expose_wasm 并每次启动打印一行
#     Warning: disabling flag --expose_wasm due to conflicting flags
#   功能无害但会污染终端输出（截图里可见）。显式声明后警告消失，实测
#   smoke / --version / headless(401) / web 监听结果完全一致。""",
"""# +ios24 修正：Node 24 / V8 13.x 已删除 --expose-wasm，再传
#   --no-expose-wasm 会被判 `bad option` 退出 9，令 A11 上唯一可用的零 JIT
#   档也起不来（真机截图：native/single/balanced/safe 全 SIGBUS 138，
#   nowasm rc=9，随后 dsh Bus error: 10）。该参数在 Node 22 时代只为压掉
#     Warning: disabling flag --expose_wasm due to conflicting flags
#   一行无害提示，现在必须去掉。""", label="tier.sh 注释")
s = sub(s, "--jitless --no-expose-wasm --require ", "--jitless --require ",
        label="tier.sh nowasm 参数")
assert not any(("no-expose-wasm" in ln and not ln.lstrip().startswith("#"))
               for ln in s.splitlines()), "tier.sh 生效行仍残留 --no-expose-wasm"
# 注释里保留该字符串是刻意的历史说明（说明为什么被删），不算残留。
s = sub(s, """    done <<EOF
$TIERS
EOF
    return 1
}""",
"""    done <<EOF
$TIERS
EOF
    # +ios24：A11 上若连 nowasm 也失败（例如文件缺失），仍把参数交给
    # 零 JIT 档，让上层的「信号杀死 -> 自动降级」逻辑有机会重试，
    # 不要在这里直接判死。
    TIER_NAME=nowasm
    TIER_ARGS=$(tier_args_for nowasm)
    TIER_SOURCE=fallback
    return 0
}""", label="tier.sh 兜底")
write(p, s)

# ---------------------------------------------------------------- 2) dsh wrapper
p = path(B, "dsh")
s = read(p)
s = sub(s, '    "$NODE" "$D/dsh-home-heal.cjs" "$DSH_HOME" "$D" || true',
        '    "$D/node-safe" "$D/dsh-home-heal.cjs" "$DSH_HOME" "$D" || true',
        label="dsh heal 零 JIT")
s = sub(s, '    echo "     跑 dsh-doctor 看逐档结果；确认 node 二进制完整（101,297,040 字节）。" >&2',
        '    echo "     跑 dsh-doctor 看逐档结果；确认 node 二进制完整（当前 $(wc -c < "$NODE") 字节）。" >&2',
        label="dsh 大小提示")
# 主进程探测彻底失败时也走零 JIT 档，不再直接 exit 74。
s = sub(s, """if ! tier_select; then
    echo "dsh: 所有 V8 启动档位都在 WASM 冒烟探针里失败了。" >&2
    echo "     node = $NODE" >&2
    echo "     跑 dsh-doctor 看逐档结果；确认 node 二进制完整（当前 $(wc -c < "$NODE") 字节）。" >&2
    echo "     可用 DSH_TIER=nowasm dsh 强制走「零 JIT」档。" >&2
    exit 74
fi""",
"""if ! tier_select; then
    echo "dsh: [warn] 档位探测未选出结果，强制走零 JIT 档（+ios24 / A11）。" >&2
    TIER_NAME=nowasm
    TIER_ARGS=$(tier_args_for nowasm)
    TIER_SOURCE=fallback
fi""", label="dsh 兜底")
write(p, s)

# ---------------------------------------------------------------- 3) dsh-doctor
p = path(B, "dsh-doctor")
s = read(p)
s = sub(s, 'SMOKE="$D/smoke.js"',
        'SMOKE="$D/smoke.js"\nNODE_SAFE="$D/node-safe"   # +ios24：短命检查统一零 JIT',
        label="doctor NODE_SAFE")
s = sub(s, "=== dsh-doctor / iPhone X (A11, arm64) / iOS 16.7.15 / Dopamine 3.0 rootless / +ios15 ===",
        "=== dsh-doctor / iPhone X (A11, arm64) / iOS 16.7.x / Dopamine rootless / +ios24 (DSH 0.2.2-rc.3 / Node 24) ===",
        label="doctor 抬头")
s = sub(s, "# 2 Node 可执行且版本 >=22.0（兼容补丁已打，不要求 22.14+）",
        "# 2 Node 可执行且版本 >=24.9.0（rc.3 engines.node 硬要求）",
        label="doctor 版本注释")
s = sub(s, 'if [ -n "$MAJ" ] && [ "$MAJ" -ge 22 ] 2>/dev/null; then',
        'if [ -n "$MAJ" ] && [ "$MAJ" -ge 24 ] 2>/dev/null; then',
        label="doctor 版本判断")
s = sub(s, 'ok "Node 运行时 $V（>=22.0，兼容补丁已应用）"',
        'ok "Node 运行时 $V（rc.3 要求 >=24.9.0，满足）"', label="doctor 版本 OK")
s = sub(s, 'bad "Node 版本过低或无法解析：$V" "需 >=22.0（util.parseEnv）；本包内置 22.12.0"',
        'bad "Node 版本过低或无法解析：$V" "rc.3 需 >=24.9.0；本包内置 24.19.0"',
        label="doctor 版本 FAIL")
s = sub(s, """if [ "$NS" -ge 101297000 ] && [ "$NS" -le 101297080 ]; then
    ok "node 大小 $NS 字节（精确匹配 101,297,040，未截断）"
else
    bad "node 大小 $NS 字节异常（应为 101,297,040）" "重传 deb 并重装；SHA 见 dist/SHA256SUMS.txt"
fi""",
"""# +ios24：内置的是 GitHub Actions 成功构建的 Node v24.19.0 iOS arm64
#   82,539,696 字节（SHA 8bebb2a2…），不是稳定底座的 22.12.0 / 101,297,040。
#   这里只做通用完整性下限，具体哈希以 dist/SHA256SUMS.txt 为准。
if [ "$NS" -gt 20000000 ] 2>/dev/null; then
    ok "node 大小 $NS 字节（>20MB arm64 Mach-O，未截断；+ios24 应为 82,539,696）"
else
    bad "node 大小 $NS 字节异常或不可读" "重传 deb 并重装；SHA 见 dist/SHA256SUMS.txt"
fi""", label="doctor 大小断言")
# 所有短命 node 调用改走 node-safe（保留 -x / wc / ldid / strings / -v 的路径用法）
s = sub(s, '"$NODE" "$D/', '"$NODE_SAFE" "$D/', count=10, label="doctor 脚本调用")
s = sub(s, '"$NODE" --expose-internals -e ', '"$NODE_SAFE" --expose-internals -e ',
        label="doctor 内部模块检查")
s = sub(s, '"$NODE" --check ', '"$NODE_SAFE" --check ', count=3, label="doctor --check")
s = sub(s, '"$NODE" -e ', '"$NODE_SAFE" -e ', count=2, label="doctor patch 解析")
s = sub(s, 'SQ=$("$NODE" $TIER_SQLITE_ARGS -e ', 'SQ=$("$NODE_SAFE" $TIER_SQLITE_ARGS -e ',
        label="doctor sqlite")
s = sub(s, 'ok "node:sqlite 可加载（--experimental-sqlite 生效）"',
        'ok "node:sqlite 可加载（Node 24 原生 + sqlite 开关）"', label="doctor sqlite OK")
s = sub(s, '"$NODE" $TIER_ARGS $TIER_SQLITE_ARGS --expose-internals "$BIN" \\',
        '"$NODE_SAFE" $TIER_SQLITE_ARGS --expose-internals "$BIN" \\',
        label="doctor plugin list")
# 主启动链（--version / headless / web）保留 tier 探测出的 TIER_ARGS；
# 全部档位失败时兜底到 nowasm，避免继续裸跑 node。
s = sub(s, """        bad "所有 V8 档位的 WASM 冒烟探针都失败" "node 二进制或签名异常；确认大小/SHA 后重装"
        TIER_ARGS=""
        export TIER_ARGS""",
"""        bad "所有 V8 档位的 WASM 冒烟探针都失败" "node 二进制或签名异常；确认大小/SHA 后重装"
        TIER_ARGS=$(tier_args_for nowasm)
        export TIER_ARGS""", label="doctor 档位兜底")
s = sub(s, """else
    bad "缺少冒烟探针 $SMOKE" "重装 +ios3 包（+ios2 没有这个文件）"
    TIER_ARGS=""
    export TIER_ARGS
fi""",
"""else
    bad "缺少冒烟探针 $SMOKE" "重装 +ios24 deb"
    TIER_ARGS=$(tier_args_for nowasm)
    export TIER_ARGS
fi""", label="doctor smoke 兜底")
s = sub(s, "# 7 dsh CLI 入口（补丁后 bin.js 无条件调用 runCli，不依赖 import.meta.main）",
        "# 7 dsh CLI 入口（rc.3 bin.js 用 import.meta.main，Node >=24.9 才支持）",
        label="doctor 第 7 项注释")
s = sub(s, 'if [ "$DV" = "0.2.1-rc.5" ]; then', 'if [ "$DV" = "0.2.2-rc.3" ]; then',
        label="doctor 版本号")
s = sub(s, '"确认 bin.js 的 import.meta.main 补丁已应用"',
        '"确认内置 Node >=24.9 且 bin.js / 引擎树完整"', label="doctor 第 7 项提示")
s = sub(s, """    if grep -q 'const DEFAULT_COMPRESSION = "none";' "$PJ"; then
        ok "会话默认压缩 none（+ios8，重启后历史对话可恢复）"
    else
        bad "会话默认压缩仍是 zstd，重启会丢对话 / corrupt Zstandard" \\
            "跑 sh fix-session.sh；它会改这一行并迁移已有 gzip 会话"
    fi""",
"""    if grep -q 'const DEFAULT_COMPRESSION = "none";' "$PJ"; then
        ok "会话默认压缩 none（重启后历史对话可恢复）"
    elif [ "${MAJ:-0}" -ge 24 ] 2>/dev/null; then
        # +ios8 把 zstd 改成 none 是因为 Node 22.12 缺 zstd；Node 24 原生
        # 支持 zstd，rc.3 保持 zstd 默认不会丢对话，这里不能误报 FAIL。
        ok "会话默认压缩 zstd（Node 24 原生 zstd，+ios8 降级不需要）"
    else
        bad "会话默认压缩仍是 zstd，重启会丢对话 / corrupt Zstandard" \\
            "跑 sh fix-session.sh；它会改这一行并迁移已有 gzip 会话"
    fi""", label="doctor 会话压缩")
s = sub(s, 'echo "结论：全部关键项通过。终端输入 dsh 即可启动 web 工作台。"',
        'echo "结论：全部关键项通过。点桌面「DeepSeek Harness」全屏图标即用；终端输入 dsh 亦可。"',
        label="doctor 结论")
write(p, s)

# ---------------------------------------------------------------- 4) pnpm wrapper
p = path(B, "pnpm")
s = read(p)
s = sub(s, 'PFLAGS="--jitless --no-expose-wasm"', 'PFLAGS="--jitless"',
        label="pnpm PFLAGS")
s = sub(s, """# +ios14：与 tier.sh nowasm 档一致，彻底不生成可执行代码。""",
"""# +ios14：与 tier.sh nowasm 档一致，彻底不生成可执行代码。
# +ios24：去掉 --no-expose-wasm（Node 24 已删除该 flag，传了就是 rc=9）。""",
        label="pnpm 注释")
write(p, s)

# ---------------------------------------------------------------- 5) dsh-compat
p = path(B, "dsh-compat")
s = read(p)
s = sub(s, 'exec "$NODE" "$D/dsh-plugin-compat.cjs" "$@"',
        'exec "$D/node-safe" "$D/dsh-plugin-compat.cjs" "$@"', label="dsh-compat")
write(p, s)

# ---------------------------------------------------------------- 6) dsh-app-ctl ping
p = path(B, "dsh-app-ctl")
s = read(p)
s = sub(s, 'NODE="$JB/usr/lib/dsh/bin/node"',
        'NODE="$JB/usr/lib/dsh/bin/node"\nSAFE_NODE="$JB/usr/lib/dsh/node-safe"   # +ios24：探活也要零 JIT',
        label="ctl SAFE_NODE")
s = sub(s, """ping() {
    [ -x "$NODE" ] || return 1
    "$NODE" -e '""",
"""ping() {
    [ -x "$NODE" ] || return 1
    PN="$NODE"; [ -x "$SAFE_NODE" ] && PN="$SAFE_NODE"
    "$PN" -e '""", label="ctl ping")
write(p, s)

# ---------------------------------------------------------------- 7) 构建期断言
for f in (path(D, "tier.sh"), path(B, "dsh"), path(B, "dsh-doctor"),
          path(B, "pnpm"), path(B, "dsh-compat"), path(B, "dsh-app-ctl")):
    t = read(f)
    assert not any(("no-expose-wasm" in ln and not ln.lstrip().startswith("#"))
                   for ln in t.splitlines()), "%s 生效行仍残留 --no-expose-wasm" % f
    sh_rc = os.system("sh -n %s >/dev/null 2>&1" % ("'" + f.replace("'", "'\\''") + "'"))
    assert sh_rc == 0, "%s shell 语法错误" % f
assert os.access(NODE_SAFE, os.X_OK), "node-safe 不可执行"
assert "NODE_SAFE" in read(path(B, "dsh-doctor")), "doctor 未接上 node-safe"
print("    Node 24 运行时补丁：tier.sh / dsh / dsh-doctor / pnpm / "
      "dsh-compat / dsh-app-ctl / node-safe 全部落地（+ios15 源文件未动）")
