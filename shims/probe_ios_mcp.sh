#!/bin/sh
# dsh-ios +ios15 — 真机端 iOS MCP 服务探测
#
# 在 iPhone 的终端里跑：  sh probe_ios_mcp.sh
# 作用：确认 iOS MCP 服务是否在跑、探出 MCP 端点路径、给出 cordis.patch.yml 该填的 url。
# 只读探测，不点击屏幕、不写任何文件。

BASE="${IOS_MCP_BASE:-http://127.0.0.1:8090}"
PORT_OK=0
ENDPOINT=""
HEALTH=""

say() { printf '%s\n' "$*"; }
hr()  { printf '%s\n' '------------------------------------------------------------'; }

hr
say 'dsh-ios  iOS MCP 探测'
hr

# --- 1) 越狱态 ---
if [ -d /var/jb ]; then
  say '[ OK ] /var/jb 存在（rootless 越狱态已激活）'
else
  say '[FAIL] /var/jb 不存在：越狱未激活，先重新越狱'
  exit 1
fi

# --- 2) 找 curl ---
CURL=""
for c in curl /var/jb/usr/bin/curl /usr/bin/curl /opt/procursus/bin/curl /var/jb/bin/curl; do
  if [ -x "$c" ]; then CURL="$c"; break; fi
  if command -v "$c" >/dev/null 2>&1; then CURL="$c"; break; fi
done
if [ -z "$CURL" ]; then
  say '[WARN] 找不到 curl，跳过 HTTP 探测（可在 Sileo 安装 curl）'
else
  say "[ OK ] curl: $CURL"

  # --- 3) /health ---
  # --noproxy：设备上若配了全局代理，仍要能连到本机回环服务
  HEALTH=$("$CURL" -sS -m 6 --noproxy '127.0.0.1,localhost' "$BASE/health" 2>/dev/null)
  case "$HEALTH" in
    *'"status":"ok"'*|*'"status": "ok"'*)
      say "[ OK ] /health 正常: $HEALTH"
      PORT_OK=1
      ;;
    *)
      say "[FAIL] $BASE/health 无响应或格式不对"
      say '       -> 进「设置 → iOS MCP」启动服务，并确认已 respring 一次'
      ;;
  esac

  # --- 4) 探 MCP 端点 ---
  if [ "$PORT_OK" -eq 1 ]; then
    INIT='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"dsh-ios-probe","version":"0.1.0"}}}'
    say '探测 MCP 端点（POST initialize）...'
    for p in /mcp / /sse /message /api/mcp; do
      RESP=$("$CURL" -sS -m 6 --noproxy '127.0.0.1,localhost' -X POST \
        -H 'Content-Type: application/json' \
        -H 'Accept: application/json, text/event-stream' \
        -d "$INIT" -D - "$BASE$p" 2>/dev/null)
      case "$RESP" in
        *jsonrpc*|*protocolVersion*|*MCP-Protocol-Version*|*Mcp-Session-Id*)
          ENDPOINT="$BASE$p"
          say "[ OK ] 端点命中: $ENDPOINT"
          break
          ;;
        *)
          say "       $p -> 无 MCP 响应"
          ;;
      esac
    done
  fi
fi

# --- 5) iOS MCP 包是否安装 ---
say ''
if command -v dpkg >/dev/null 2>&1 || [ -x /var/jb/usr/bin/dpkg ]; then
  DPKG=dpkg
  [ -x /var/jb/usr/bin/dpkg ] && DPKG=/var/jb/usr/bin/dpkg
  if "$DPKG" -s ios-mcp >/dev/null 2>&1 || "$DPKG" -l 2>/dev/null | grep -qi 'ios.*mcp'; then
    say '[ OK ] 检测到 iOS MCP 包'
  else
    say '[WARN] 未在 dpkg 里查到 ios-mcp（包名可能不同，以 Sileo 为准）'
  fi
fi

# --- 6) 结论 ---
hr
if [ -n "$ENDPOINT" ]; then
  say '结论：服务可用。'
  say ''
  say '把 plugins/dsh-ios-phone-control/cordis.patch.yml 的 url 设为：'
  say "    $ENDPOINT"
  say ''
  if [ "$ENDPOINT" = 'http://127.0.0.1:8090/mcp' ]; then
    say '（与插件默认值一致，无需改动）'
  else
    say '（与默认值不同，请改完再安装插件）'
  fi
  say ''
  say '下一步：'
  say '  1) 保持屏幕解锁 + 常亮（锁屏时交互类工具会被服务端拦截）'
  say '  2) DSH Web UI → 插件 → 添加插件 → 填本地目录或 tgz 路径'
  say '  3) 重启 DSH，让 AI 调用 mcp__ios__get_device_info 验证'
  say ''
  say '安全提醒：iOS MCP 无认证且 run_command 可执行任意 shell，'
  say '          只在可信环境用，用完在「设置 → iOS MCP」里关掉服务。'
  exit 0
elif [ "$PORT_OK" -eq 1 ]; then
  say '结论：/health 通了，但没探到 MCP 端点。'
  say '  请打开「设置 → iOS MCP」→「复制并分享 MCP 提示词片段」，'
  say '  把里面的完整 URL 填进 cordis.patch.yml 的 url。'
  exit 2
else
  say '结论：服务未就绪。按上面 [FAIL] 提示处理后再跑一次。'
  exit 1
fi
