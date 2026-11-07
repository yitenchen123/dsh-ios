#!/bin/sh
# device-check.sh —— 装 deb 之前，在 iPhone 上跑这个，先确认机器满足全部前提。
# 用法：把本文件拷到手机，NewTerm / SSH 里执行  sh device-check.sh
# 只读，不改任何东西。
JB=/var/jb
PASS=0; FAIL=0
ok(){  printf '  [ OK ] %s\n' "$1"; PASS=$((PASS+1)); }
bad(){ printf '  [FAIL] %s\n' "$1"; FAIL=$((FAIL+1)); }

echo "=== dsh-ios 设备前置检查 ==="
echo

IOS=$(sw_vers -productVersion 2>/dev/null || sysctl -n kern.osproductversion 2>/dev/null || echo "?")
ARCH=$(uname -m 2>/dev/null || echo "?")
MODEL=$(sysctl -n hw.model 2>/dev/null || echo "?")
MEM=$(sysctl -n hw.memsize 2>/dev/null || sysctl -n hw.physmem 2>/dev/null || sysctl -n hw.memsize2 2>/dev/null || echo 0)
case "$MEM" in ''|*[!0-9]*) MEM=0 ;; esac
MB=$((MEM / 1048576))
if [ "$MB" -gt 0 ]; then
    echo "  系统 iOS $IOS | 架构 $ARCH | 机型 $MODEL | 物理内存 ${MB}MB"
else
    echo "  系统 iOS $IOS | 架构 $ARCH | 机型 $MODEL | 物理内存 iOS 上不可读（正常，不影响）"
fi
echo

case "$ARCH" in
    arm64) ok "arm64（A11，非 arm64e），与内置 node-v22.12.0-iphoneos-arm64（iPhone X 实测版）匹配" ;;
    arm64e) bad "这是 arm64e 机型" "内置 node 为纯 arm64 构建；本包针对 iPhone X / A11" ;;
    *) bad "未知架构 $ARCH" "需要 arm64" ;;
esac

case "$IOS" in
    16.7.15) ok "iOS 16.7.15（Dopamine 3.0 对 A11 支持到 16.7.16）" ;;
    16.7.16) ok "iOS 16.7.16（Dopamine 3.0 A11 支持上界）" ;;
    15.*|16.*) ok "iOS $IOS 在 Dopamine 3.0 arm64 支持区间(15.8.7-16.7.16)内" ;;
    *) bad "iOS $IOS 可能不在 Dopamine 3.0 的 A11 支持范围" "确认 Dopamine 已越狱且 /var/jb 可用" ;;
esac

if [ -L "$JB" ] && [ -d "$JB/usr/bin" ]; then
    ok "/var/jb rootless 环境已激活 -> $(readlink "$JB" 2>/dev/null)"
else
    bad "/var/jb 不可用" "打开 Dopamine 点 Jailbreak；半不拴绳越狱每次重启都要重新激活"
fi

for c in dpkg; do
    if command -v "$c" >/dev/null 2>&1 || [ -x "$JB/usr/bin/$c" ]; then ok "$c 可用"; else
        bad "$c 缺失" "bootstrap 不完整，重装 Dopamine 的 Procursus 引导"
    fi
done
if command -v ldid >/dev/null 2>&1 || [ -x "$JB/usr/bin/ldid" ]; then
    ok "ldid 可用（可核验/兜底补签 node 的 JIT entitlement）"
else
    printf '  [WARN] ldid 未安装 —— 内置 node 自带完整签名，postinst 保留原签名\n'
    printf '         -> 若 doctor 第 4 项失败，装 ldid 后手动 ldid -S/var/jb/usr/lib/dsh/ent.plist /var/jb/usr/lib/dsh/bin/node\n'
fi

# iOS 的 df 输出列数因版本而异，取「含数字的行」里最后一行的第 4 列，读不到就只提示不强判失败。
AVAIL=$(df -k "$JB" 2>/dev/null | grep -E '[0-9]' | tail -1 | awk '{print $4}')
case "$AVAIL" in
    ''|*[!0-9]*) printf '  [WARN] 无法自动读取可用空间，请确认至少 900MB 空闲\n' ;;
    *) if [ "$AVAIL" -gt 900000 ]; then ok "可用空间 $((AVAIL/1024))MB，足够（deb 解压约 700MB）"
       else bad "可用空间不足（$((AVAIL/1024))MB）" "至少预留 900MB"; fi ;;
esac

if [ "$MB" -eq 0 ]; then
    ok "内存检查跳过（iOS 不暴露 sysctl）；dsh.env 已限 V8 堆 384MB，不要与 MC 同时跑"
elif [ "$MB" -ge 2500 ]; then
    ok "物理内存 ${MB}MB，配合 NODE_OPTIONS=--max-old-space-size=384 可跑"
else
    bad "物理内存 ${MB}MB 过低" "A11/3GB 已是最低档，且不要与 MC 同时运行"
fi

echo
echo "=== OK=$PASS FAIL=$FAIL ==="
[ "$FAIL" -eq 0 ] && echo "可以安装 dev.airdevs.dsh_*.deb" || echo "先修复 FAIL 项再安装"
exit "$FAIL"
