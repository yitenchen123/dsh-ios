# phone-bridge — 内置手机操控工具链

让「启动 DSH，DSH 就能直接调用工具链操作手机」成立。源码目录，由
`app-bundle/build-app.sh` 复制进 `dev.airdevs.dsh-app` 这个 deb；**不进主
deb**，因此 `+ios15` 稳定底座的交付物字节不变。

## 组件

| 文件 | 落到设备上 | 作用 |
|---|---|---|
| `server.cjs` | `/var/jb/usr/lib/dsh-phone-bridge/server.cjs` | 纯 Node MCP Streamable HTTP 服务，`127.0.0.1:8091/mcp` |
| `ensure-config.cjs` | 同目录 | 幂等把 `@deepseek-ai/dsh-mcp-client` 注册进 `$DSH_HOME` 的 patch 层 |
| `dsh-phone-bridge-daemon` | `/var/jb/usr/bin/` | launchd 前台入口：先注册配置，再 exec 进 server（零 JIT 档） |
| `dsh-phone-bridge-ctl` | `/var/jb/usr/bin/` | `status\|health\|tools\|enable\|disable\|config-on\|config-off\|config-status\|log` |
| `dev.airdevs.dsh.phone-bridge.plist` | `/var/jb/Library/LaunchDaemons/` | `RunAtLoad + KeepAlive`，`UserName=mobile` |
| `verify-phone-bridge.sh` | 仅仓库 | 本地 28 项验证（真 MCP 握手 / 工具调用 / 上游转发 / 配置 schema / 零 JIT） |

## 能力分层

**A 层（开箱即用，纯 Node 实现）**

`get_device_info`、`list_dir`、`read_file`、`write_file`、`run_command`、
`list_apps`、`launch_app`、`open_url`、`list_processes`、`get_syslog`、
`dsh_status`、`phone_bridge_status`。

**B 层（转发到原生 `witchan/ios-mcp`）**

设备装了 `ios-mcp`（默认 `127.0.0.1:8090/mcp`）时，`screenshot`、
`tap_screen`、`get_ui_elements`、`ocr_screen` 等工具会在 `tools/list` 里
自动合并，`tools/call` 原样转发。没装时返回明确的安装指引，不影响 A 层。

> 纯 JS 拿不到 IOHIDEvent / SpringBoard XPC，真·触控注入与截图必须靠原生
> 实现。本仓库不分发、不修改 `ios-mcp`。

## 为什么是 8091

`8090` 是第三方 ios-mcp 的默认端口，不能抢占。DSH 侧配置固定连
`http://127.0.0.1:8091/mcp`；旧的 `plugins/dsh-ios-phone-control`（直连
8090）仍可独立使用，但不要与内置注册同时启用（两者 `serverName` 都是
`ios`，工具前缀都会是 `mcp__ios__*`）。

## 安全

- 服务**无任何认证**，只绑定 `127.0.0.1`。`run_command` 可执行任意 shell，
  `read_file` / `write_file` 能读写服务进程权限内的路径。只在可信设备上用。
- 不要改成 `0.0.0.0` 或局域网 IP。
- 关闭：`dsh-phone-bridge-ctl config-off && dsh-phone-bridge-ctl disable`。
  卸载 `dev.airdevs.dsh-app` 时 `prerm` 会自动做这两件事。
- 配置写在用户 patch 层，保持顶层为 YAML 数组（真机曾因顶层非数组直接
  fatal）；`dsh-home-heal.cjs` 只删两个旧 IM 插件块，不会误删本工具链。

## 验证

```sh
sh phone-bridge/verify-phone-bridge.sh   # 28 项
sh app-bundle/verify-app.sh              # 73 项（含 16 项工具链断言）
```

端到端验证用包内 `@modelcontextprotocol/client` 真跑 `initialize` +
`tools/list` + `tools/call`，并用假上游 ios-mcp 验证 B 层合并与转发。
真机侧的 ldid 伪签 / uicache / launchd / HID 注入仍需在设备上确认。
