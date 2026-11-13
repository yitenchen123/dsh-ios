#!/bin/sh
# ---------------------------------------------------------------------------
# verify-no-data-loss.sh —— 沙箱实测「启用/升级 Node24 实验包不丢插件、不丢会话」
#
# 跑的是仓库里原封不动的 node24/payload/dsh24-switch，只在隔离环境里构造
# 模拟的 rootless 目录结构。流程：
#   构造插件+会话 -> on -> 模拟实验包产生新会话 -> off -> 再 on -> restore
# 每一步都用 sha256 指纹断言：旧插件/旧会话逐字节不变、稳定包 .dsh-tier
# 不被覆盖、回滚后与基线一致、升级后新会话可从 .pre-restore.* 找回。
#
# !! 仅限隔离沙箱 / CI 运行，严禁在真机上运行 !!
# 真机上 /var/jb 一定是真实目录（rootless bootstrap），本脚本会直接拒绝；
# 若 /var/jb 是构建 stage 留下的符号链接，脚本临时移开并在退出时恢复。
# 真机验证仍须按 node24/README.md 的逐级清单人工完成。
#
# 用法: sh node24/tests/verify-no-data-loss.sh
# 退出码: 0=全部断言通过；2=环境不允许（真机/目录已存在）
# ---------------------------------------------------------------------------
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
J=/var/jb
H="$J/var/mobile/.dsh"
BAK="${H}.bak-node24"
SW="$ROOT/node24/payload/dsh24-switch"
FAIL=0
ok()  { printf '  [ ok  ] %s\n' "$1"; }
bad() { printf '  [FAIL ] %s\n' "$1" >&2; FAIL=$((FAIL+1)); }

if [ ! -f "$SW" ]; then echo "找不到 $SW" >&2; exit 2; fi

# --- 安全护栏 ---
if [ -L "$J" ]; then
    # 隔离沙箱常见：build.sh 的 stage 留下的符号链接。临时移开，退出恢复。
    echo "检测到 $J 是符号链接 -> $(readlink "$J")，临时移开并在退出时恢复"
    mv "$J" "${J}.sim-backup"
    trap 'rm -rf "$J"; mv "${J}.sim-backup" "$J"; echo "已恢复 $J 符号链接"' EXIT
elif [ -e "$J" ]; then
    echo "拒绝运行：$J 是真实目录，可能是真机 / 真实 rootless 环境" >&2
    echo "本脚本只应在隔离沙箱或 CI 里跑；真机验证请看 node24/README.md" >&2
    exit 2
fi

echo "=== 构造模拟 rootless 环境 ==="
mkdir -p "$J/usr/lib/dsh-node24/bin" "$J/usr/bin" "$H/plugins" "$H/sessions/2026-11"
printf '#!/bin/sh\necho v24.22.3\n' > "$J/usr/lib/dsh-node24/bin/node"
printf '#!/bin/sh\necho dsh24\n'       > "$J/usr/bin/dsh24"
printf '#!/bin/sh\necho dsh-stable\n'  > "$J/usr/bin/dsh"
chmod 755 "$J/usr/lib/dsh-node24/bin/node" "$J/usr/bin/dsh24" "$J/usr/bin/dsh"

# 3 个插件，每个含 manifest + 数据文件
for p in alpha beta gamma; do
    mkdir -p "$H/plugins/$p"
    printf '{"name":"%s","version":"1.0.0"}\n' "$p" > "$H/plugins/$p/manifest.json"
    printf 'plugin-%s-payload\n' "$p"                 > "$H/plugins/$p/data.txt"
done
# 3 个会话（含嵌套目录）
printf 'session A content\n' > "$H/sessions/sess-a.jsonl"
printf 'session B content\n' > "$H/sessions/sess-b.jsonl"
printf 'session C content\n' > "$H/sessions/2026-11/sess-c.jsonl"
# 稳定包档位缓存（实验包绝不能碰）
printf 'nowasm\n' > "$H/.dsh-tier"

# 用户数据指纹：排除实验档位缓存（那是实验包自己的，不算用户数据）
fingerprint() {
    (cd "$H" && find . -type f \
        ! -name '.dsh-node24-tier' ! -name '.dsh-node24-flags' \
        -print0 | sort -z | xargs -0 sha256sum)
}
BASE=$(fingerprint)
BASE_N=$(printf '%s\n' "$BASE" | wc -l)
echo "  基线用户数据文件数 = $BASE_N"

echo
echo "=== [1] status（初始）==="
sh "$SW" status | sed 's/^/    /'

echo
echo "=== [2] on：启用实验包 ==="
sh "$SW" on | sed 's/^/    /'
[ -d "$BAK" ] && ok "生成回滚备份 $BAK" || bad "未生成回滚备份"
if [ "$(cd "$BAK" && find . -type f -print0 | sort -z | xargs -0 sha256sum)" = "$BASE" ]; then
    ok "备份内容与基线逐字节一致"; else bad "备份内容与基线不一致"; fi
[ -x "$J/usr/bin/dsh24" ] && ok "实验入口 dsh24 已启用" || bad "实验入口未启用"
[ -x "$J/usr/bin/dsh" ]   && ok "稳定入口 dsh 仍在"     || bad "稳定入口 dsh 被破坏"

echo
echo "=== [3] 模拟实验包运行：产生新会话 + 实验档位缓存 ==="
printf 'new session after upgrade\n' > "$H/sessions/sess-new.jsonl"
printf 'drumbrake\n' > "$H/.dsh-node24-tier"
printf -- '--jitless --wasm-jitless\n' > "$H/.dsh-node24-flags"
AFTER_RUN=$(fingerprint)
[ "$(printf '%s\n' "$AFTER_RUN" | wc -l)" -eq $((BASE_N+1)) ] \
    && ok "新会话已写入（用户数据 +1）" || bad "新会话未写入"
# 旧的插件/会话必须一字节不变
OLD_NOW=$(printf '%s\n' "$AFTER_RUN" | grep -v 'sess-new.jsonl')
[ "$OLD_NOW" = "$BASE" ] && ok "升级后旧插件/旧会话 SHA 全部不变" || bad "升级改动了旧插件/会话"

echo
echo "=== [4] off：关闭实验包、回退稳定包 ==="
sh "$SW" off | sed 's/^/    /'
[ -f "$J/usr/bin/dsh24.disabled" ] && ok "实验入口已停用（改名保留，可再 on）" || bad "实验入口未停用"
[ -x "$J/usr/bin/dsh" ] && ok "稳定入口 dsh 仍在" || bad "稳定入口丢失"
[ -f "$H/.dsh-tier" ] && [ "$(cat "$H/.dsh-tier")" = "nowasm" ] \
    && ok "稳定包 .dsh-tier 未被实验包覆盖" || bad "稳定包档位缓存被破坏"
[ ! -e "$H/.dsh-node24-tier" ] && [ ! -e "$H/.dsh-node24-flags" ] \
    && ok "实验档位缓存已清理" || bad "实验档位缓存残留"
AFTER_OFF=$(fingerprint)
[ "$AFTER_OFF" = "$AFTER_RUN" ] \
    && ok "off 未删除任何插件/会话（含升级后新会话）" || bad "off 丢了用户数据"

echo
echo "=== [5] 再次 on（幂等，不覆盖首次备份）==="
sh "$SW" on | sed 's/^/    /'
[ -x "$J/usr/bin/dsh24" ] && ok "可再次启用" || bad "再次启用失败"
[ -f "$BAK/sessions/sess-a.jsonl" ] && ok "首次备份仍完好" || bad "首次备份被覆盖"

echo
echo "=== [6] restore：从备份回滚 ==="
sh "$SW" restore | sed 's/^/    /'
RESTORED=$(fingerprint)
[ "$RESTORED" = "$BASE" ] \
    && ok "回滚后用户数据与基线逐字节一致（插件/旧会话全在）" || bad "回滚后数据与基线不符"
[ -f "$H/.dsh-tier" ] && ok "回滚后稳定包 .dsh-tier 仍在" || bad "回滚后稳定档位缓存丢失"
[ -f "$J/usr/bin/dsh24.disabled" ] && ok "回滚后实验入口已停用" || bad "回滚后实验入口仍启用"
PRE=$(find "$J/var/mobile" -maxdepth 1 -name '.dsh.pre-restore.*' -type d | head -1)
[ -n "$PRE" ] && ok "回滚前的目录被保留未误删: $PRE" || bad "回滚前目录未保留"
if [ -n "$PRE" ] && [ -f "$PRE/sessions/sess-new.jsonl" ]; then
    ok "升级后产生的新会话保留在 ${PRE}，可人工找回"; else bad "新会话未被保留"; fi

echo
echo "=== 汇总: FAIL=$FAIL ==="
[ "$FAIL" -eq 0 ] && echo "结论：升级/切换/回滚全程插件与会话零丢失 ✔" || echo "结论：存在数据丢失 ✘"
echo "注意：这是隔离沙箱的脚本逻辑实测，不等于 A11 真机 dsh 0.2.2-rc.2 会话格式兼容验证。"
exit "$FAIL"
