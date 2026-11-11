# dsh-ios-phone-control

把设备本机的 **iOS MCP** 服务接到 DSH，让 AI 真的能操作这台 iPhone：看屏幕、点击、滑动、输入文字、打开/切换 App、OCR 识别中文、读系统日志与崩溃日志。

> 这是**用户手动安装的生态插件**，不是包里自带的。它不进 `.deb`、不预装、不修改包内任何文件，只往当前 profile 的 cordis 配置里插入一行 MCP 客户端。

## 前置条件（缺一不可）

1. iPhone 已越狱，**rootless**（Dopamine / `/var/jb`），iOS 15–18，`iphoneos-arm64`。
   本项目目标机 iPhone X / A11 / iOS 16.7.15 / Dopamine 3.0 正好符合。
2. 已安装第三方越狱插件 **iOS MCP**（`witchan/ios-mcp`，MIT）：
   - Sileo / Zebra 里添加作者源后搜 `iOS MCP`，或
   - 从该项目 GitHub Releases 下载 **rootless / `iphoneos-arm64`** 的 `.deb` 手动装。
   - 依赖 `ElleKit`（或 mobilesubstrate）与 `preferenceloader`，Dopamine 环境一般已具备。
3. 装完 **respring 一次**，进「设置 → iOS MCP」**启动服务**，并保持**屏幕解锁 + 常亮**。
   锁屏/熄屏时服务端会拦截点击、滑动、输入、启动 App、Shell 等交互类工具。
4. 确认 `http://127.0.0.1:8090/health` 返回 `{"status":"ok",...}`。
   可用本仓库的 `shims/probe_ios_mcp.sh` 一键探测（它还会试出 MCP 端点路径）。

## 安装本插件

在 DSH Web UI：**插件 → 添加插件**，填以下任意一种（+ios15 已把手动安装全方式修好）：

- 本地目录绝对路径：`/var/mobile/dsh-ios-phone-control`
- 本地 tarball：`/var/mobile/dsh-ios-phone-control-0.1.0.tgz`
- GitHub / git 地址（会自动转成 pnpm hosted-git 简写，不依赖设备上的 git）

装好后**重启 DSH**（`dsh` 退出再进），让 cordis 重新加载配置。

## 验证

新开一个会话，直接让 AI：

> 调用 `mcp__ios__get_device_info`，告诉我机型和 iOS 版本。

能返回就通了。之后可用的工具（共 46 个，命名 `mcp__ios__<工具名>`）：

| 类别 | 工具 |
|---|---|
| 触控 | `tap_screen` `swipe_screen` `long_press` `double_tap` `drag_and_drop` |
| 硬件键 | `press_home` `press_power` `press_volume_up/down` `toggle_mute` `wake_and_home` |
| 文字 | `input_text` `type_text` `press_key` |
| 屏幕 | `screenshot`（Base64 JPEG）`get_screen_info` |
| App | `launch_app` `kill_app` `list_apps` `list_running_apps` `get_frontmost_app` `get_app_info` `install_app` `uninstall_app` |
| 元素/OCR | `get_ui_elements` `get_element_at_point` `tap_element` `wait_for_element` `wait_for_disappear` `ocr_screen` `describe_screen` |
| 其它 | `get/set_clipboard` `list_dir` `read_file` `write_file` `get_syslog` `get_crash_logs` `read_crash_log` `get/set_brightness` `get/set_volume` `get_device_info` `open_url` `run_command` |

`ocr_screen` / `describe_screen(include_ocr=true)` 默认用离线 PaddleOCR（支持中文），也可传 `engine: "vision"` 用 Apple Vision。

## 配置说明

`cordis.patch.yml` 里可改的项：

| 字段 | 当前值 | 说明 |
|---|---|---|
| `serverName` | `ios` | 决定工具前缀 `mcp__ios__*`，多个 MCP 服务时不得重复 |
| `url` | `http://127.0.0.1:8090/mcp` | 端点路径以设备「设置 → iOS MCP」里「复制并分享 MCP 提示词片段」给的为准；用 `probe_ios_mcp.sh` 可自动探测 |
| `failOnStartupError` | `false` | iOS MCP 没开时 DSH 照常启动，不要改成 `true` |
| `reconnect.maxAttempts` | `30` | 服务常需手动开，给足自动重连窗口 |
| `toolCallTimeoutMs` | `120000` | 装 deb / 长操作留足超时 |

改完用 DSH 的插件重载（或重启 DSH）生效；用户的 patch 层在升级后保留。

## 安全（务必看）

- iOS MCP **无内置认证**，`run_command` 可执行任意 shell，`read_file`/`write_file` 能读写服务进程权限内的路径，`get_syslog` 能读全 App 日志。**只在可信环境用，用完在「设置 → iOS MCP」里关掉服务。**
- 本插件把 URL 固定为 `127.0.0.1` 回环，避免服务暴露到局域网。不要改成 `0.0.0.0` 或设备局域网 IP 去对外提供。
- 截图、OCR 结果、日志会随会话发给模型提供方，含个人信息，注意账号与隐私。
- 这是第三方越狱插件（MIT / AS IS），装在自己的备用机上，别装在存有支付与主账号的主力机。

## 卸载

插件页卸载本 bundle 即可；iOS MCP 服务与 deb 需单独在 Sileo / 设置里关闭或卸载。

## 许可

本 bundle 自身配置沿用本仓库许可。iOS MCP 为第三方项目（MIT + NOTICE + 第三方组件各自许可），本仓库不分发、不打包、不修改它，仅提供接入配置。
