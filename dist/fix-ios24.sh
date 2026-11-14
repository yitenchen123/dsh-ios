#!/bin/sh
# ============================================================================
# fix-ios24.sh —— 已装 +ios24 旧包的「就地热修」，不用重装 deb
# ----------------------------------------------------------------------------
# 适用：iPhone X / A11 / iOS 16.7.x / Dopamine rootless 上，装了
#       v0.2.2-rc.3+ios24（2026-11-14 首版）后出现的三个症状：
#   ① 终端敲 dsh → Bus error: 10 /「所有 V8 启动档位都在 WASM 冒烟探针里失败了」
#   ② dsh-doctor → +ios15 抬头、12 个 FAIL（node 大小 82,539,696 被说成异常）
#   ③ 桌面全屏图标打开只有一行黑底白字
#      「dsh web authentication required; reopen the URL printed by dsh web.」
#
# 根因（逐条对应）：
#   ① tier.sh / usr/bin/pnpm 带 --no-expose-wasm。Node 24 / V8 13.x 已删除该
#      flag，传了就是 `bad option` 退出 9；A11 上 native/single/balanced/safe
#      四档全 SIGBUS(138)，唯一能活的零 JIT 档 nowasm 被它挡死。
#   ② dsh-doctor 是从 +ios15 稳定底座原样复制的：硬编码 Node 22.12.0 的
#      101,297,040 字节、DSH 0.2.1-rc.5、+ios15 抬头；且大量检查裸跑 node
#      （不带零 JIT 参数），在 A11 上连锁 SIGBUS。多数 FAIL 是误报。
#   ③ 安装脚本只跑 dsh-app-ctl enable（kickstart 不带 -k），launchd 认为服务
#      「已在运行」，旧 DSH 进程继续占着 3080 —— 它内存里是随机 launchToken
#      的旧引擎树，Web Clip 的固定 token 必然 401。旧 Web Clip 还可能被
#      SpringBoard 缓存。
#
# 本脚本做的事（全部幂等，可重复跑）：
#   0) 【+ios24.2 新增】修「工作区/对话加载不出」：把会话默认压缩 zstd
#      改回 none（兼容用户从 +ios15/+ios18 带来的明文 .jsonl 会话），并让
#      iOS/darwin 的目录选择器走 browse（Web Clip 无原生选择器）。
#      这两处不修，host 装配期 checkRootEncoding() 会因 zstd 撞 .jsonl
#      全局 fatal，所有 controller pending，前端报 directoryPickerController
#      is unavailable、工作区/对话全空。
#   1) 去掉所有生效行里的 --no-expose-wasm；
#   2) 部署 /var/jb/usr/lib/dsh/node-safe（--jitless + fetch-shim.cjs）；
#   3) 在 /var/jb/etc/dsh/dsh.env 注入 NODE_OPTIONS 零 JIT 参数，并让
#      dsh-app-ctl / dsh-compat 的短命 node 调用走 node-safe；
#   4) bootout 旧 label + 清掉占 3080 的孤儿进程 + 删旧 DSH Web Clip +
#      重写带固定 token 的 Web Clip + kickstart -k 强制换进程；
#   5) 用固定 token 真探 303 / Cookie / 200，打印结果。
#
# 硬约束：不写 $DSH_HOME 里的对话 / 工作区 / 插件 / 配置；不改属主；
#         不删任何用户数据。只动 /var/jb 下的系统文件与 DSH 自己的 Web Clip。
# 用法：  在手机终端（root 或 sudo）执行  sh fix-ios24.sh
#         跑完若桌面图标仍是旧的，respring 一次（SpringBoard 缓存 Web Clip）。
#         更彻底的做法是重装 v0.2.2-rc.3+ios24.2 新 deb（含同样修复）。
# ============================================================================
set -e
JB=/var/jb
D="$JB/usr/lib/dsh"
B="$JB/usr/bin"
ENVF="$JB/etc/dsh/dsh.env"
WCSRC="$D/webclip"
PORT="${DSH_WEB_PORT:-3080}"
WCDIR="${DSH_WEBCLIP_DIR:-/var/mobile/Library/WebClips/133239ba-d3d0-422d-ba40-7945156fd8ea.webclip}"
WCLIB=$(dirname "$WCDIR")
LOGDIR="$JB/var/log/dsh-app"

[ -L "$JB" ] || { echo "fix-ios24: /var/jb 不存在，越狱未激活。" >&2; exit 1; }
[ -x "$D/bin/node" ] || { echo "fix-ios24: 缺 $D/bin/node，请先装 +ios24 deb。" >&2; exit 1; }
[ -f "$WCSRC/Info.plist" ] || { echo "fix-ios24: 缺 Web Clip 资产，无法重写图标。" >&2; exit 1; }

# token 从包内 Web Clip URL 反解（首版 deb 没有 webclip/token 文件），
# 与 dsh-daemon / plist / apply_fixed_token_patch.cjs 缺省值一致。
TOKEN=$(sed -n 's/.*?token=\([^<]*\)<.*/\1/p' "$WCSRC/Info.plist" 2>/dev/null | head -1)
[ -n "$TOKEN" ] || TOKEN=dshios-fixed-token-8f3a2c
echo "fix-ios24: 固定 token = $TOKEN"

# --- 0) 数据兼容：会话压缩 none + 目录选择器 browse -------------------------
# 与构建期 make_ios_data_compat.py 逐字一致（sed 版，设备端无 python3）。
NM="$D/node_modules"
SP="$NM/@deepseek-ai/dsh-session-persistence-jsonl/lib/index.js"
DP="$NM/@deepseek-ai/dsh-host-directory-picker-auto/lib/index.js"
# iOS 自带的是 BSD sed，对替换串里的 \n / \t 不做转义；这里只做「同长度
# 单行值替换」，不插入注释行（JS 的 // 注释必须独占到行尾，塞进同一行会
# 把后面的语句一起注释掉）。幂等判定基于替换后的值，不依赖 marker 文本。
if [ -f "$SP" ]; then
    if grep -q 'const DEFAULT_COMPRESSION = "zstd";' "$SP" 2>/dev/null; then
        sed 's@const DEFAULT_COMPRESSION = "zstd";@const DEFAULT_COMPRESSION = "none";@' \
            "$SP" > "$SP.dshfix.$$" 2>/dev/null || true
        [ -s "$SP.dshfix.$$" ] && cat "$SP.dshfix.$$" > "$SP" 2>/dev/null || true
        rm -f "$SP.dshfix.$$" 2>/dev/null || true
        echo "    会话默认压缩已改 none（明文 .jsonl，兼容既有对话）"
    else
        echo "    会话默认压缩已是 none（跳过）"
    fi
fi
if [ -f "$DP" ]; then
    if grep -q 'facts.platform === "darwin" || facts.platform === "win32") return "native";' "$DP" 2>/dev/null; then
        sed 's@if (facts.platform === "darwin" || facts.platform === "win32") return "native";@if (facts.platform === "darwin" || facts.platform === "win32") return "browse";@' \
            "$DP" > "$DP.dshfix.$$" 2>/dev/null || true
        [ -s "$DP.dshfix.$$" ] && cat "$DP.dshfix.$$" > "$DP" 2>/dev/null || true
        rm -f "$DP.dshfix.$$" 2>/dev/null || true
        echo "    iOS 目录选择器已改 browse（Web Clip 可用）"
    else
        echo "    iOS 目录选择器已是 browse（跳过）"
    fi
fi

# --- 1) 去掉 Node 24 已删除的 --no-expose-wasm -------------------------------
strip_flag() {
    f=$1
    [ -f "$f" ] || return 0
    if grep -q -- '--no-expose-wasm' "$f" 2>/dev/null; then
        sed 's/--no-expose-wasm //g; s/ --no-expose-wasm//g' "$f" > "$f.dshfix.$$" 2>/dev/null || return 0
        cat "$f.dshfix.$$" > "$f" 2>/dev/null || true
        rm -f "$f.dshfix.$$" 2>/dev/null || true
        echo "    已清理 $(basename "$f") 的 --no-expose-wasm"
    fi
}
strip_flag "$D/tier.sh"
strip_flag "$B/pnpm"
grep -q 'nowasm|--jitless --require ' "$D/tier.sh" || {
    echo "fix-ios24: [ERROR] tier.sh 的 nowasm 档仍不可用" >&2; exit 1; }

# --- 2) 部署零 JIT 通用启动器 -------------------------------------------------
cat > "$D/node-safe" <<'EOF'
#!/bin/sh
# +ios24 零 JIT 通用启动器（短命工具用）
D=/var/jb/usr/lib/dsh
exec "$D/bin/node" --jitless --require "$D/fetch-shim.cjs" "$@"
EOF
chmod 755 "$D/node-safe"
echo "    已部署 $D/node-safe"

# --- 3) 让所有短命 node 调用都零 JIT -----------------------------------------
# dsh.env 被 dsh / dsh-doctor 共同 source，注入 NODE_OPTIONS 后，heal、
# patch 解析、--check、node:sqlite 等裸跑 node 的检查全部自动继承零 JIT。
if [ -f "$ENVF" ]; then
    if ! grep -q 'DSH_IOS24_JITLESS' "$ENVF" 2>/dev/null; then
        cat >> "$ENVF" <<'EOF'

# --- DSH_IOS24_JITLESS（fix-ios24.sh 注入，幂等）---
# A11 上 Node 24 原生 JIT 会 SIGBUS；所有 node 子进程统一走零 JIT。
case "$NODE_OPTIONS" in
    *--jitless*) ;;
    *) NODE_OPTIONS="${NODE_OPTIONS:---max-old-space-size=384} --jitless --require /var/jb/usr/lib/dsh/fetch-shim.cjs" ;;
esac
export NODE_OPTIONS
EOF
        echo "    dsh.env 已注入零 JIT NODE_OPTIONS"
    else
        echo "    dsh.env 已含零 JIT 配置（跳过）"
    fi
fi
# dsh-app-ctl 由 SpringBoard 调起，不 source dsh.env；在脚本头部注入同样的
# NODE_OPTIONS，让它的 `node -e` 探活也零 JIT（避免 A11 上 SIGBUS 误判不可连）。
if [ -f "$B/dsh-app-ctl" ] && ! grep -q 'DSH_IOS24_SAFE_PING' "$B/dsh-app-ctl" 2>/dev/null; then
    {
        printf '%s\n' '#!/bin/sh'
        printf '%s\n' '# DSH_IOS24_SAFE_PING（fix-ios24.sh 注入，幂等）'
        printf '%s\n' 'case "$NODE_OPTIONS" in'
        printf '%s\n' '    *--jitless*) ;;'
        printf '%s\n' '    *) NODE_OPTIONS="${NODE_OPTIONS:---max-old-space-size=384} --jitless --require /var/jb/usr/lib/dsh/fetch-shim.cjs" ;;'
        printf '%s\n' 'esac'
        printf '%s\n' 'export NODE_OPTIONS'
        tail -n +2 "$B/dsh-app-ctl" 2>/dev/null || true
    } > "$B/dsh-app-ctl.dshfix.$$" 2>/dev/null || true
    if [ -s "$B/dsh-app-ctl.dshfix.$$" ]; then
        cat "$B/dsh-app-ctl.dshfix.$$" > "$B/dsh-app-ctl" 2>/dev/null || true
        chmod 755 "$B/dsh-app-ctl" 2>/dev/null || true
        echo "    dsh-app-ctl 已注入零 JIT NODE_OPTIONS"
    fi
    rm -f "$B/dsh-app-ctl.dshfix.$$" 2>/dev/null || true
fi
if [ -f "$B/dsh-compat" ] && ! grep -q 'node-safe' "$B/dsh-compat" 2>/dev/null; then
    sed 's|exec "$NODE" "$D/dsh-plugin-compat.cjs"|exec "$D/node-safe" "$D/dsh-plugin-compat.cjs"|' \
        "$B/dsh-compat" > "$B/dsh-compat.dshfix.$$" 2>/dev/null || true
    [ -s "$B/dsh-compat.dshfix.$$" ] && cat "$B/dsh-compat.dshfix.$$" > "$B/dsh-compat" 2>/dev/null || true
    rm -f "$B/dsh-compat.dshfix.$$" 2>/dev/null || true
fi

# --- 4) 强制重启 daemon：清旧进程 + 重写 Web Clip ----------------------------
probe_ok() {
    "$D/node-safe" -e '
      const http=require("http");
      const path="/?token="+encodeURIComponent(process.argv[2]);
      const req=http.get({host:"127.0.0.1",port:Number(process.argv[1]),path,timeout:1500},r=>{
        r.resume(); process.exit((r.statusCode===303||r.statusCode===200)?0:1);
      });
      req.on("error",()=>process.exit(1));
      req.on("timeout",()=>{req.destroy();process.exit(1)});
    ' "$PORT" "$TOKEN" >/dev/null 2>&1
}
LC=""
for c in "$JB/usr/bin/launchctl" "$JB/bin/launchctl" /usr/bin/launchctl /bin/launchctl; do
    [ -x "$c" ] && { LC="$c"; break; }
done
if [ -n "$LC" ]; then
    for L in dev.airdevs.dsh dev.airdevs.dsh-app; do
        "$LC" bootout "system/$L" >/dev/null 2>&1 || true
        "$LC" unload -w "$JB/Library/LaunchDaemons/$L.plist" >/dev/null 2>&1 || true
        "$LC" remove "$L" >/dev/null 2>&1 || true
    done
fi
for p in $(ps -eo pid,args 2>/dev/null | grep '[d]sh.*web --no-open --port' | \
           sed -n 's/^[[:space:]]*\([0-9][0-9]*\).*/\1/p'); do
    kill "$p" 2>/dev/null || true
done
mkdir -p "$LOGDIR" 2>/dev/null || true

# 只删 URL 指向 127.0.0.1:${PORT} 的 DSH Web Clip，用户其它 Web Clip 不碰。
if [ -d "$WCLIB" ]; then
    for d in "$WCLIB"/*.webclip; do
        [ -d "$d" ] || continue
        [ -f "$d/Info.plist" ] || continue
        if grep -q "127.0.0.1:${PORT}" "$d/Info.plist" 2>/dev/null; then
            rm -rf "$d" 2>/dev/null || true
        fi
    done
fi
mkdir -p "$WCDIR" 2>/dev/null || true
cp "$WCSRC/Info.plist" "$WCDIR/Info.plist" 2>/dev/null || true
cp "$WCSRC/icon.png"   "$WCDIR/icon.png"   2>/dev/null || true
cp "$WCSRC/icon.png"   "$WCDIR/Icon.png"   2>/dev/null || true
chown -R 501:501 "$WCDIR" 2>/dev/null || true

if [ -n "$LC" ]; then
    PL="$JB/Library/LaunchDaemons/dev.airdevs.dsh.plist"
    "$LC" bootstrap system "$PL" >/dev/null 2>&1 || true
    "$LC" load -w "$PL" >/dev/null 2>&1 || true
    "$LC" kickstart -k "system/dev.airdevs.dsh" >/dev/null 2>&1 || true
fi
[ -x "$B/dsh-app-ctl" ] && "$B/dsh-app-ctl" ensure >/dev/null 2>&1 || true

# --- 5) 自检 ------------------------------------------------------------------
READY=0
i=0; while [ "$i" -lt 30 ]; do
    if probe_ok; then READY=1; break; fi
    i=$((i+1)); sleep 0.5 2>/dev/null || true
done
echo
if [ "$READY" -eq 1 ]; then
    echo "✔ fix-ios24: Web UI 已用固定 token 放行（303/Cookie 或 200），端口 $PORT。"
    echo "  现在点桌面「DeepSeek Harness」图标即可全屏使用；插件/工作区/对话照旧加载。"
else
    echo "! fix-ios24: Web UI 仍未就绪。看日志 $LOGDIR/dsh-daemon.err.log，"
    echo "  或跑 dsh-doctor；也可直接重装 v0.2.2-rc.3+ios24.2 新 deb。" >&2
fi
echo "  若桌面仍是旧图标或仍显示 401，请 respring 一次（SpringBoard 缓存 Web Clip）。"
echo "  本脚本没有改动 \$DSH_HOME 里的对话 / 工作区 / 插件 / 配置。"
exit 0
