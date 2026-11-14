#!/bin/sh
# 单包 extras：APP 签名 / 图标注册 / **全屏 Web Clip** / launchd 保活。
#
# 硬约束：绝不写 $DSH_HOME。旧版在这里 mkdir/chown -R $DSHHOME、跑
# `dsh-phone-bridge-ctl config-on`（改写 cordis.patch.yml）、写
# profiles/web/.npmrc 与 .dsh-market/state.json —— 全部已移除。
# 用户已有的对话、工作区、插件、npm 源、插件市场区域设置一律保留。
#
# +ios24.1 升级修复（真机 401 黑屏根因）：
#   旧版只跑 `dsh-app-ctl enable`，其 do_bootstrap 里的 kickstart 不带 -k。
#   launchd 认为服务「已在运行」，于是升级后 3080 上仍是那个旧进程 —— 它内存里
#   是旧引擎树（processLaunchToken 随机生成），固定 token 的 Web Clip 必然
#   收到 401「dsh web authentication required; reopen the URL printed by dsh web.」。
#   同时旧 Web Clip 目录里可能还是无 token / 旧 token 的 URL，SpringBoard 有缓存。
#   本版：bootout 全部旧 label -> 清掉占端口的孤儿进程 -> 清理所有指向
#   127.0.0.1:${PORT} 的旧 DSH Web Clip -> 写全新 Web Clip -> bootstrap
#   + kickstart -k 强制换进程 -> 用固定 token 真探 303/200。
set -e
JB=/var/jb
APP="$JB/Applications/DSH.app"
ENT="$APP/entitlements.plist"
HELPER="$JB/usr/bin/dsh-app-helper"
DYLDIR="$JB/Library/MobileSubstrate/DynamicLibraries"
DYL="$DYLDIR/dsh-ios-control.dylib"
CTL="$JB/usr/bin/dsh-app-ctl"
BRCTL="$JB/usr/bin/dsh-phone-bridge-ctl"
LOGDIR="$JB/var/log/dsh-app"
D="$JB/usr/lib/dsh"
WCSRC="$D/webclip"
PORT="${DSH_WEB_PORT:-3080}"
# 单一真相源：构建期从 one-package/dsh-web-token 复制进包，与 Web Clip URL /
# launchd plist / apply_fixed_token_patch.cjs 缺省值逐字一致。
TOKEN=$(tr -d '\r\n' < "$WCSRC/token" 2>/dev/null || true)
[ -n "$TOKEN" ] || TOKEN=dshios-fixed-token-8f3a2c
# 设备端为 SpringBoard 读取的真实路径；DSH_WEBCLIP_DIR 仅供沙箱实测隔离。
WCDIR="${DSH_WEBCLIP_DIR:-/var/mobile/Library/WebClips/133239ba-d3d0-422d-ba40-7945156fd8ea.webclip}"
WCLIB=$(dirname "$WCDIR")

# 包内系统文件权限（不涉及用户数据目录）。
chmod 755 "$APP/DSHLauncher" "$JB/usr/bin/dsh-app-ctl" "$JB/usr/bin/dsh-daemon" \
  "$JB/usr/bin/dsh-app-ui" "$JB/usr/bin/dsh-phone-bridge-daemon" \
  "$JB/usr/bin/dsh-phone-bridge-ctl" "$JB/usr/bin/mcp-logreader" \
  "$D/node-safe" 2>/dev/null || true
chmod 644 "$APP/Info.plist" "$APP/entitlements.plist" "$APP"/*.png 2>/dev/null || true
for f in "$JB/Library/LaunchDaemons/dev.airdevs.dsh.plist" \
         "$JB/Library/LaunchDaemons/dev.airdevs.dsh.phone-bridge.plist" \
         "$DYL" "$DYLDIR/dsh-ios-control.plist" "$HELPER" "$JB/usr/bin/mcp-logreader"; do
  [ -f "$f" ] && chown 0:0 "$f" 2>/dev/null || true
done
[ -f "$HELPER" ] && chmod 4755 "$HELPER" 2>/dev/null || true
LDID=""; for c in "$JB/usr/bin/ldid" "$JB/bin/ldid" /usr/bin/ldid; do [ -x "$c" ] && { LDID="$c"; break; }; done
if [ -n "$LDID" ]; then
  [ -f "$ENT" ] && "$LDID" -S"$ENT" "$APP/DSHLauncher" 2>/dev/null || true
  [ -f "$DYL" ] && "$LDID" -S "$DYL" 2>/dev/null || true
fi

# 日志在 jbroot 系统区，绝不 mkdir/chown $DSH_HOME/logs。
mkdir -p "$LOGDIR" 2>/dev/null || true

# 手机操控 bridge：只启动服务，绝不 config-on（那会改写用户插件配置）。
if [ -x "$BRCTL" ]; then "$BRCTL" enable >/dev/null 2>&1 || true; fi

# 真探活：只认 303（固定 token 换 cookie）或 200（已有会话），401 一律失败。
# 用 node-safe 零 JIT 启动器，不依赖 curl/nc，也不会在 A11 上 SIGBUS。
probe_ok() {
    [ -x "$D/node-safe" ] || return 1
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

# --- 1) 强制换掉「已经在跑」的旧 DSH 进程 --------------------------------
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
# 清掉仍占着 3080 的孤儿 DSH（别的 label、终端手工启动、旧包残留）。
# 只匹配本包 CLI 形态，绝不误杀用户其它 node 进程。
for p in $(ps -eo pid,args 2>/dev/null | grep '[d]sh.*web --no-open --port' | \
           sed -n 's/^[[:space:]]*\([0-9][0-9]*\).*/\1/p'); do
    kill "$p" 2>/dev/null || true
done
# 等端口真正释放（仍有人应答就再等一轮，最多 3s）。
i=0; while [ "$i" -lt 10 ]; do
    probe_ok || break
    i=$((i+1)); sleep 0.3 2>/dev/null || true
done

# --- 2) 清理所有指向本端口的旧 Web Clip，写全新的一份 ----------------------
# 旧版 Web Clip 可能是无 token / 旧随机 token / 缺 Title 的 "Untitled"，
# SpringBoard 还会缓存它。全部删掉再写，保证桌面只留一个正确入口。
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
if [ -f "$WCSRC/Info.plist" ]; then
    mkdir -p "$WCDIR" 2>/dev/null || true
    cp "$WCSRC/Info.plist" "$WCDIR/Info.plist" 2>/dev/null || true
    cp "$WCSRC/icon.png"   "$WCDIR/icon.png"   2>/dev/null || true
    cp "$WCSRC/icon.png"   "$WCDIR/Icon.png"   2>/dev/null || true
    # 只 chown 本包新建的这一个目录，不碰用户其它 Web Clip，更不碰 $DSH_HOME。
    chown -R 501:501 "$WCDIR" 2>/dev/null || true
    grep -q "?token=$TOKEN" "$WCDIR/Info.plist" 2>/dev/null || \
        echo "dsh: [warn] Web Clip URL 的 token 与常量文件不一致，请重装 deb" >&2
else
    echo "dsh: [ERROR] 缺 $WCSRC/Info.plist，全屏 Web Clip 未安装；此 deb 构建不完整！" >&2
fi

# --- 3) 重新加载并强制 kickstart -k ---------------------------------------
if [ -n "$LC" ]; then
    PL="$JB/Library/LaunchDaemons/dev.airdevs.dsh.plist"
    "$LC" bootstrap system "$PL" >/dev/null 2>&1 || true
    "$LC" load -w "$PL" >/dev/null 2>&1 || true
    "$LC" kickstart -k "system/dev.airdevs.dsh" >/dev/null 2>&1 || true
fi
[ -x "$CTL" ] && "$CTL" ensure >/dev/null 2>&1 || true

# --- 4) 自检：等最多 ~15s，确认新引擎树用固定 token 放行 -------------------
READY=0
i=0; while [ "$i" -lt 30 ]; do
    if probe_ok; then READY=1; break; fi
    i=$((i+1)); sleep 0.5 2>/dev/null || true
done
if [ "$READY" -eq 1 ]; then
    echo "dsh: Web UI 已用固定 token 放行（303/Cookie 或 200），端口 $PORT。"
else
    echo "dsh: [warn] Web UI 尚未就绪；看日志 $LOGDIR/dsh-daemon.err.log 或跑 dsh-doctor。" >&2
    [ -x "$CTL" ] && "$CTL" restart >/dev/null 2>&1 || true
fi

# 只刷新 SpringBoard 让它读取新建的 Web Clip 图标。绝不调用
# `dsh-app-ctl register` —— 那会 uicache -p 把半屏 SFSafariViewController
# 的 native DSH.app 图标显式刷到桌面。单包内该 APP 已带 SBAppTags=hidden。
for U in "$JB/usr/bin/uicache" "$JB/bin/uicache" /usr/bin/uicache; do
    if [ -x "$U" ]; then "$U" -a >/dev/null 2>&1 || true; break; fi
done

echo "DeepSeek Harness 单包：DSH 0.2.2-rc.3 + 全屏 Web Clip 入口 已就绪。"
echo "  桌面点「DeepSeek Harness」图标即全屏使用；工作区 / 会话 / 插件全部保留。"
echo "  若桌面仍是旧图标或仍显示 401，请 respring 一次（SpringBoard 会缓存旧 Web Clip）。"
exit 0
