# iOS 手机操控（真·点屏幕 / 跨 App 自动化）接入方案

> 目标：让 DSH 的 AI 能像 B 站上安卓 DSH-Go 演示的那样——滑出 App、找到 B 站、搜索、刷视频、读屏幕、总结；以及「AI 写完代码 → 自动在 iPhone 上装、打开、点 UI、看日志」的开发闭环。
>
> 结论：**可以做到，而且不用写原生代码、不用改浏览器前端、不用重打包 125MB 的 deb。**

---

## 0. `+ios16` 更新：不再需要手动装插件，启动 DSH 即可调用工具链

上面第 6 节的「落地步骤」是 **+ios15 时代的方案**：用户要先装第三方 `witchan/ios-mcp`、再手动装 `dsh-ios-phone-control` 配置插件。用户后来明确要求「**启动 DSH 让 DSH 操作手机，它能够直接调用相关工具链操作**」，所以 `dev.airdevs.dsh-app` 包现在**内置**了一整套工具链：

| 层 | 实现 | 开箱即用 |
|---|---|---|
| **A 层**（本机能力） | 包内纯 Node MCP 服务 `phone-bridge/server.cjs`，监听 `127.0.0.1:8091/mcp` | ✅ 设备信息、shell、读写文件、目录、App 列表/启动、URL scheme、进程、syslog、DSH 状态、bridge 状态 |
| **B 层**（看屏幕 / 点屏幕 / UI 树 / OCR / 剪贴板 / 亮度音量） | 自动转发到设备上 `witchan/ios-mcp` 的 `127.0.0.1:8090/mcp`；在线时工具合并进 `tools/list`，`tools/call` 原样转发 | ⚠️ 需自行装第三方原生 deb（真 HID 注入无法用纯 JS 实现） |
| **注册** | `ensure-config.cjs` 由 bridge daemon 以 **mobile 身份**幂等把 `@deepseek-ai/dsh-mcp-client` 写进 `$DSH_HOME` 的 `cordis.patch.yml`，顶层保持合法数组 | ✅ 装完 APP 包即生效，无需手动改配置 |

关键点：

- bridge 是**独立 LaunchDaemon**（`dev.airdevs.dsh.phone-bridge`，`RunAtLoad + KeepAlive`），与 DSH 本体解耦：终端被杀、DSH 重启、点 APP 图标，工具链都还在。
- 固定 `8091` 是为了**不抢占** ios-mcp 默认的 `8090`；旧的 `dsh-ios-phone-control` 插件（直连 8090）仍可独立使用，但不要和内置注册同时启用（两者 `serverName` 都是 `ios`）。
- 配置注册用 mobile 身份写，避免 +ios12 真机踩过的 root 属主 → EACCES；自愈脚本 `dsh-home-heal.cjs` 只删两个旧 IM 插件块，不会误删本工具链。
- **主 deb 完全没动**：工具链全部在 `app-bundle/` 里，`+ios15` 交付 deb 与热修 SHA 保持不变。

设备端命令：

```sh
dsh-phone-bridge-ctl status          # daemon / health / patch 注册状态
dsh-phone-bridge-ctl tools           # 列出当前可用工具（含上游合并的）
dsh-phone-bridge-ctl health          # /health 探活
dsh-phone-bridge-ctl config-off      # 关闭自动注册（保留用户其它 patch 块）
dsh-phone-bridge-ctl disable         # 停用 daemon
dsh-phone-bridge-ctl log             # 看日志
```

验证：`sh phone-bridge/verify-phone-bridge.sh` **28 项 0 失败** —— 包内 `@modelcontextprotocol/client` 真完成 `initialize` + `tools/list`，`tools/call` 真执行 shell / 读写文件往返，假上游 ios-mcp 的 `tap_screen` / `screenshot` 合并并原样转发返回，`dsh-mcp-client` 的 `Config` schema 校验通过，注册幂等且 `off` 后回落 `[]`，零 JIT 档（`--jitless` + `fetch-shim`）下同样可启动。`sh app-bundle/verify-app.sh` 另有 16 项工具链断言，合计 **73 项 0 失败**。

> 仍然存在的边界：真·触控注入、截图、OCR 必须由 `witchan/ios-mcp` 的原生实现提供（纯 JS 拿不到 IOHIDEvent / SpringBoard XPC）；本项目不分发、不修改它。A 层工具已能让 AI 完成「装 → 打开 → 跑命令 → 读日志」的自动测试闭环。

---

## 1. 先纠正上一轮的两个判断

在查到 `witchan/ios-mcp` 之前，我基于「iOS 没有 Android 无障碍服务」给出的判断偏保守，这里更正：

| 上一轮说法 | 更正 |
|---|---|
| 「iOS 没有无障碍读屏树，只能靠截图 + 视觉坐标定位」 | **错**。越狱下可通过私有 Accessibility API 拿到 UI 节点树；`ios-mcp` 提供 `get_ui_elements` / `tap_element` / `wait_for_element`，能按文本/标签点元素，PaddleOCR 还支持中文识别。稳定性比我原先说的好。 |
| 「必须新增原生组件，约等于做半个 tweak，要重打包 deb」 | **不必从零写**。越狱社区已有 MIT 开源、带预编译 deb 的现成服务，正好支持 rootless `iphoneos-arm64`；我们包里也**已经内置** `@deepseek-ai/dsh-mcp-client`。工作量从「原生开发」降到「装一个 deb + 装一个纯配置插件」。 |

---

## 2. 为什么「浏览器中打开」不挡事

这是本方案的关键，也直接回答「我们的是浏览器中打开的，可以做到吗」。

> **2026-11 补充更正**：DeepSeek 已于 **2026-09-29 发布官方桌面 APP**（macOS Apple Silicon / Windows x64，官网 `download.deepseek.com` 直接下载），电脑端日常使用**不再需要手动开浏览器、也不用跑 `npx @deepseek-ai/dsh web`** [^6]。所以「电脑上 DSH 是在浏览器里开的」这个说法在**使用方式**上已经过时，之前的表述在此更正。
>
> 但**架构结论不变，反而被官方实现直接证实**：官方桌面 APP 是 `apps/desktop`，用 **Electron 把完整的 dsh Web 应用 + Node/Python 运行时一起封装进原生壳**，界面层依旧是 Web UI，本地仍起一个 Harness 后端进程，工具依旧注册在 **Host 侧 `ctx.tools`** [^6][^7]。`dsh-desktop-use` 在官方 APP 上仍需独立的 PowerShell 原生助手去调 `user32.dll`。也就是说，官方自己就是「**原生壳 + Web UI 前端 + 内置 Node 宿主 + 原生助手**」的结构 —— 这正是「前端形态与系统能力无关」的实证。

以「AI 操作电脑」为例，无论前端是哪个形态，结构都是三段式 [^1]：

| 部分 | 位置 | 职责 |
|---|---|---|
| 宿主半边 `lib/index.js` | **Node 后端** | 把 `computer_click` / `computer_screenshot` 等注册进 `ctx.tools` |
| 原生助手 `helper.ps1` | 原生进程 | P/Invoke 调 `user32.dll` 发鼠标键盘、`System.Drawing` 截图 |
| 前端半边 `lib/client.js` | Web UI（浏览器标签 / PWA / Electron 壳都一样） | 只是输入框旁的一个开关，读写回环路由 |

也就是说，**电脑端从「浏览器开 Web UI」变成「官方 APP 开 Web UI」，只是把浏览器打包进了壳里**；真正干活的仍是后端宿主 + 原生助手。前端是浏览器标签、PWA 还是原生 App，与「能不能操控系统」无关。

### 2.1 官方桌面 APP 与我们的包

| | 官方桌面 APP | 我们的 `+ios15` 包 |
|---|---|---|
| Node / Harness 运行时 | 随安装包自带（0.2.2-rc.1 需 Node ≥24.9） | 随 deb 自带（锁 **Node 22.12.0**，A11 唯一 100% 可用） |
| 界面层 | 内置 Electron/Chromium 里的 **Web UI** | Safari 16.6 里的 **Web UI** |
| 进程宿主 | APP 自动管理本地 Harness 进程 | 终端 `dsh` 起 Host，跑在 `/var/jb` |
| 系统级操控能力 | 仍需 `dsh-desktop-use` + PowerShell 原生助手 | 仍需 `ios-mcp` 越狱 tweak |
| 平台 | macOS arm64 / Windows x64（Linux 官方不支持） | iPhone X / iOS 16.7.15 / Dopamine rootless |

两点值得注意：

1. **官方能升 0.2.2-rc.1，靠的正是「自带新版 Node」**；我们升不了，是因为 A11 上不存在 Node ≥24.9 的 iOS arm64 二进制（详见 [`DSH-NODE-UPGRADE-EVALUATION.md`](DSH-NODE-UPGRADE-EVALUATION.md)）。这从侧面解释了版本差异的根因，跟前端是不是 APP 毫无关系。
2. **官方目前没有 iOS / Android 手机 APP**，移动端部署仍列在路线图里 [^6][^7]；市面所谓「DeepSeek App」是聊天助手，不是 Harness。iOS 上的第三方原生客户端（DSH Go 适配中、`dsh-mobile` / `ds-harness-remote` 的 TestFlight beta）都是**连电脑 Host 的远程壳**，引擎仍跑在电脑或安卓本机。因此**我们这个包依然是 iPhone X 上「DSH 引擎跑在本机」的唯一可行路径**，地位不变。

> 顺带回答「要不要也做个 iOS 原生壳」：不划算也没必要。我们已经自带 Node + Harness + 完整 Web UI + Safari 16 垫片，做 `WKWebView` 套壳只能省掉「打开 Safari」这一步，用的还是同一个 WebKit，对「操作手机」零帮助；而越狱环境下 Safari 免签名、免描述文件、免处理后台保活。真正缺的从来不是界面壳，是原生能力通道。

我们的情况同理：

```
iPhone 本机
├── DSH Host（Node 22.12.0，跑在 /var/jb，已在手机里）
│   └── ctx.tools ← dsh-mcp-client 把外部 MCP 工具注册到这里
│        ↑ HTTP 127.0.0.1:8090（Streamable HTTP / MCP）
├── iOS MCP（第三方越狱 tweak + 常驻服务）
│   └── 私有 API：截图 / UI 树 / OCR / IOHID 触控注入 / App 管理 / syslog
└── Safari 16.6 里的 DSH Web UI
    └── 只显示工具调用、结果、审批开关 —— 不需要改
```

**能力来自 Host 侧 + 原生服务，浏览器前端一行都不用动。**

---

## 3. 和安卓 DSH-Go 的对比

| | 安卓（DSH-Go / DSHBox / dsh-preset-mobile-use） | 我们（dsh-ios + ios-mcp） |
|---|---|---|
| DSH 引擎在哪 | 手机本机（App 内置 Ubuntu + Node），或 SSH 远程连电脑 | **手机本机**（越狱 rootless `/var/jb`），本来就是本机 |
| 界面形态 | 原生 Flutter App（为了打包 Linux 环境 + 拿系统权限） | Web UI（Safari），后端本来就在手机里，**不需要重写成原生 App** |
| GUI 自动化靠什么 | Android **无障碍服务** / Shizuku / root；headless 虚拟显示逐帧 swipe [^2][^3] | 越狱 tweak：IOHID 触控注入 + 私有截图/AX API + `LSApplicationWorkspace` |
| 读屏能力 | 系统 Accessibility 节点树 | 私有 AX API 节点树 + 离线 OCR（PaddleOCR 中文） |
| 已知坑 | 小米 HyperOS 秒撤无障碍权限、部分国产 ROM 屏幕自动化失效、Android 17 SIGSYS [^2] | 锁屏时交互工具被拦、需 respring、私有 entitlement 依赖越狱态 |
| 权限底子 | 免 root 也能用，但受厂商限制 | 越狱 rootless，权限更硬，但**每次重启需重新激活越狱** |

用户说的「安卓那边是软件适配」——准确说是**原生 App 拿到了系统级读屏 + 代点权限**，不是「网页适配变强了」。我们缺的从来就不是前端形态，而是这一层原生能力通道；现在这个通道由第三方 deb 补上。

---

## 4. 「操作手机」分三层，别混

| 层 | 内容 | 我们当前状态 |
|---|---|---|
| **A. 操作本机文件 / shell / 进程 / 网络 / 装插件** | `bash` `fs` `terminal` 工具 | **早就能做**。包内 `dsh-bash-local` 通过 `ctx.subprocess` 在 iPhone 本机 spawn `bash -c`，`dsh-fs-local` 读写本机文件，都注册在 Host 侧 `ctx.tools`。范围受 rootless 沙箱限制。 |
| **B. 粗粒度系统动作** | 打开 App、跳 URL scheme、跑快捷指令 | 从 `bash` 调 `uiopen` / `open` / `shortcuts run` 即可，无需截屏点击 |
| **C. 真·GUI 自动化** | 看屏幕、点屏幕、滑动、跨 App、UI 元素定位、OCR | **本方案补齐**：装 `iOS MCP` deb + 装 `dsh-ios-phone-control` 配置插件 |

用户要的是 **C**。顺带说：他提到的「AI 写完自动测试」，如果只是在终端跑测试脚本，A 就够；但要测**自己写的 iOS App 的真实界面**，就得靠 C——这也是这个方案对开发最值钱的地方（见第 8 节）。

---

## 5. 前置条件（缺一不可）

1. **设备**：iPhone X / A11 / iOS 16.7.15 / Dopamine 3.0 rootless / `/var/jb`。
   `ios-mcp` 支持 `rootless` + **iOS 15–18** + **`iphoneos-arm64`**，正好覆盖 [^4]。
2. **已装 `iOS MCP`**：Sileo/Zebra 搜 `iOS MCP`，或从 GitHub Releases 取 **rootless / `iphoneos-arm64`** 的 deb。依赖 `ElleKit`（或 mobilesubstrate）与 `preferenceloader`。
3. **respring 一次**，进「设置 → iOS MCP」**启动服务**。
4. **屏幕解锁 + 常亮**。锁屏/熄屏时服务端会拦截点击、滑动、输入、启动 App、Shell 等交互类工具，只放行状态查询、截图、唤醒。
5. 确认 `http://127.0.0.1:8090/health` 返回 `{"status":"ok","server":"ios-mcp",...}`。

> `iOS MCP` 是第三方项目（MIT + NOTICE，AS IS），**本仓库不分发、不打包、不修改它**，只提供接入配置。它也不进我们的 deb，不预装。

---

## 6. 落地步骤

### 步骤 1：设备上装并启动服务

```sh
# Sileo 里搜 "iOS MCP" 安装，或手动 dpkg -i <rootless iphoneos-arm64>.deb
# 然后 respring
```

### 步骤 2：探测服务与端点

把 `shims/probe_ios_mcp.sh` 传到手机，在终端跑：

```sh
sh probe_ios_mcp.sh
```

它会检查越狱态、`/health`、并逐个 POST `initialize` 试探 `/mcp`、`/`、`/sse` 等候选路径，最后打印**应该填进配置的完整 URL**。

> README 只公开了 `/health`，MCP 端点路径以设备「设置 → iOS MCP → 复制并分享 MCP 提示词片段」给出的为准。插件默认按 MCP Streamable HTTP 惯例填 `http://127.0.0.1:8090/mcp`，若探测结果不同就改 `cordis.patch.yml` 的 `url`。

### 步骤 3：装这个纯配置插件

`plugins/dsh-ios-phone-control/` 是一个**配置型 DSH bundle**（无 host/client 代码），格式取自官方模板 [^5]：

```yaml
# cordis.patch.yml
- insert:
    - id: dsh-ios-phone-control-mcp
      name: '@deepseek-ai/dsh-mcp-client'
      config:
        serverName: ios
        transport: streamable-http
        url: http://127.0.0.1:8090/mcp
        failOnStartupError: false      # 服务没开时 DSH 仍要能启动
        toolCallTimeoutMs: 120000
        reconnect: { enabled: true, initialDelayMs: 500, maxDelayMs: 30000, maxAttempts: 30 }
```

打包并传到手机：

```sh
sh shims/make_phone_control_bundle.sh     # 产出 dist/dsh-ios-phone-control-0.1.0.tgz
```

DSH Web UI → **插件 → 添加插件**，填本地目录绝对路径或 tgz 路径（+ios15 已把手动安装全方式修好，含本地路径 / tarball / GitHub）。装完**重启 DSH**。

### 步骤 4：验证

新会话里让 AI 调用 `mcp__ios__get_device_info`，能返回机型与 iOS 版本即通。

工具命名规则：`mcp__<serverName>__<tool>`，本配置下即 `mcp__ios__*`。

---

## 7. 可用的 46 个工具

| 类别 | 工具 |
|---|---|
| 触控手势 | `tap_screen` `swipe_screen` `long_press` `double_tap` `drag_and_drop` |
| 硬件按键 | `press_home` `press_power` `press_volume_up` `press_volume_down` `toggle_mute` `wake_and_home` |
| 文字输入 | `input_text`（剪贴板快粘贴）`type_text`（HID 逐字）`press_key` |
| 屏幕 | `screenshot`（Base64 JPEG）`get_screen_info` |
| App 管理 | `launch_app` `kill_app` `list_apps` `list_running_apps` `get_frontmost_app` `get_app_info` `install_app` `uninstall_app` |
| 元素 / OCR | `get_ui_elements` `get_element_at_point` `tap_element` `wait_for_element` `wait_for_disappear` `ocr_screen` `describe_screen` |
| 剪贴板 | `get_clipboard` `set_clipboard` |
| 文件 | `list_dir` `read_file` `write_file` |
| 日志 | `get_syslog` `get_crash_logs` `read_crash_log` |
| 设备 | `get/set_brightness` `get/set_volume` `get_device_info` |
| 其它 | `open_url` `run_command` |

`ocr_screen` / `describe_screen(include_ocr=true)` 默认离线 PaddleOCR（中文/英文/数字），可传 `engine: "vision"` 用 Apple Vision。`install_app` 支持 `.ipa` / `.tipa` / `.deb`。

---

## 8. 「AI 写完自动测试」的完整闭环

这正是用户说的「更利于开发」。有了 C 层能力，AI 可以真的在 iPhone 上跑一遍：

```
写代码/改插件（A 层：bash + fs，本来就有）
   ↓
install_app 把自己产出的 .deb / .ipa 装到设备
   ↓
launch_app 启动 → get_ui_elements / tap_element 走一遍界面
   ↓
screenshot / ocr_screen 核对显示结果
   ↓
get_syslog / get_crash_logs 看有没有崩
   ↓
有问题 → 回到第一步改，没问题 → 交付
```

以及用户原本举的例子：「给它十分钟刷 B 站总结」——`launch_app`(B站) → `tap_element`(搜索框) → `input_text` → `swipe_screen` 逐条刷 → `screenshot` + `ocr_screen` 读标题/评论 → 汇总。这条链路里的每一环都有对应工具。

---

## 9. 协议与版本兼容性（已本地核实）

| 项 | 值 | 结论 |
|---|---|---|
| 我们包内 `@deepseek-ai/dsh-mcp-client` | `0.2.1-rc.5` | 内置，无需安装 |
| 支持 transport | `stdio` / **`streamable-http`** | ✅ 正好匹配 |
| `@modelcontextprotocol/client` | `2.2.0` | 包内已有 |
| SDK 支持的协议版本 | `2024-10-07` … `2025-03-26` / `2025-06-18` / **`2025-11-25`** | ✅ |
| `ios-mcp` 默认协议 | `2025-11-25`（兼容 `2025-06-18` / `2025-03-26`） | ✅ 完全对齐 |
| 官方 MCP bundle 模板 | `templates/mcp/cordis.patch.yml` | ✅ 格式依据 |

`verify-phone-control.sh` 会在本地起一个假 MCP server，用包内 SDK 真跑 `initialize` + `tools/list`，并额外在 `nowasm` 零 JIT 档（`--require fetch-shim.cjs`）下再跑一遍。

---

## 10. 安全（务必看）

- **`iOS MCP` 无内置认证**，`run_command` 可执行任意 shell，`read_file`/`write_file` 能读写服务进程权限内路径，`get_syslog` 能读全 App 实时日志 [^4]。**只在可信环境用，用完在「设置 → iOS MCP」里关掉服务。**
- 本插件把 URL 固定为 **`127.0.0.1` 回环**，避免把无认证服务暴露到局域网。**不要改成 `0.0.0.0` 或局域网 IP 对外提供。**
- 截图、OCR 结果、日志会随会话发给模型提供方，可能含个人信息与账号内容。
- `mcp-root` 是受限提权（只允许包内工具、受限 `chmod`/`launchctl`、`dpkg` 安装卸载），**不是通用 sudo**，但仍应谨慎。
- 这是第三方越狱插件（MIT / AS IS），建议装在备用机，别装在存有支付与主账号的主力机。
- 等于把整块屏幕控制权交给 AI：保留 DSH 的工具审批，别开「完全权限」跑长任务。

---

## 11. 已知限制 / 尚未验证（诚实清单）

| 项 | 状态 |
|---|---|
| 配置合法性、MCP SDK 握手、零 JIT 档兼容 | ✅ 本地实测（`verify-phone-control.sh`） |
| `iOS MCP` deb 在 **A11 / iOS 16.7.15 / Dopamine 3.0 rootless** 上的实装、respring、私有 entitlement、HID 注入是否真跑通 | ❌ **必须在真机验证**。x86 沙箱无 iOS arm64 设备与私有框架，无法代跑 |
| MCP 端点确切路径 | ⚠️ 项目只公开 `/health`；以设备设置里「复制 MCP 提示词片段」为准，`probe_ios_mcp.sh` 会自动探测 |
| 长时间任务（10 分钟刷 B 站）稳定性 | ⚠️ 未测。A11 上零 JIT Node + Base64 截图传输有性能压力，截图进会话也吃 token；建议先跑短链路 |
| 锁屏 / 熄屏 | ⚠️ 交互类工具被服务端拦截，长任务必须保持解锁 + 常亮 |
| 越狱态丢失 | ⚠️ Dopamine 是 semi-untethered，重启后需重新激活越狱并重启服务 |
| 每次 iOS 版本升级 | ⚠️ 私有 API / entitlement 可能失效，需等 `ios-mcp` 适配 |

**因此本方案的定位是：接入层已经做好且本地验证过；真机侧的安装与硬件能力确认需要你在设备上跑一遍 `probe_ios_mcp.sh` 并反馈结果。**

---

## 12. 不预装声明

用户此前明确要求「所有插件是 DSH 的生态插件，不是包里自带的」「不要整默认自带两个插件」。这里把**插件**和**工具链**分开，两条约束都成立：

**生态插件（仍然零预装）**

- `plugins/dsh-ios-phone-control/` **不在**主包 `payload/` 里，不进主 deb，不预装；
- `iOS MCP` 是用户自行安装的第三方 deb，本仓库不分发、不修改；
- 不改 `tools.js` / `operations.js`，AI 帮你装与 CLI 路径不受影响；
- 旧方案走的是 +ios15 修好的**手动安装**链路。

**工具链（`+ios16` 新增，用户明确要求「启动 DSH 就能直接调用」）**

- `dev.airdevs.dsh-app` 内置的是**本机 MCP 服务 + 一条 MCP 客户端配置**，不是第三方生态插件：`@deepseek-ai/dsh-mcp-client` 本来就在依赖树里，配置写进用户自己的 `cordis.patch.yml` patch 层（可 `config-off` 移除）。
- 它和「默认自带 `dsh-im` / `dsh-qqbot` 两个插件」不是一回事：那两个是 IM 机器人插件，会占会话、要凭据、会「未运行」；工具链是纯能力注册，不产生任何会话或后台插件进程。
- 全部新增文件都在 `app-bundle/` 与 `phone-bridge/`，**主包 `payload/` 一行未动**，`+ios15` 交付 deb 与热修 SHA 保持不变。
- 不需要时可完全关闭：`dsh-phone-bridge-ctl config-off && dsh-phone-bridge-ctl disable`，卸载 APP 包时 `prerm` 自动执行。

---

## 13. 故障排查

| 现象 | 处理 |
|---|---|
| `/health` 不通 | 没 respring，或「设置 → iOS MCP」里服务没启动；重开一次越狱态 |
| 插件装了但工具没出现 | 重启 DSH；看 `url` 是否与探测结果一致；`serverName` 不要和其他 MCP 重复 |
| 工具调用报「锁屏」 | 解锁 + 关闭自动锁屏 / 插着电源保持常亮 |
| `failOnStartupError` 被改成 `true` | 改回 `false`，否则服务没开时 DSH 起不来 |
| 端点 404 | 跑 `probe_ios_mcp.sh`，用设置页复制的片段里的 URL |
| 点击没反应 | 确认越狱态仍激活、tweak 已注入 SpringBoard、屏幕未锁 |
| 想彻底关掉 | 插件页卸载 bundle + 「设置 → iOS MCP」关服务（必要时 Sileo 卸载 deb） |

---

## 参考

[^1]: [Desktop Use 插件工作原理（宿主/助手/浏览器三段式，仅 Windows）](https://dshpluginhub.ai/zh/plugins/dsh-desktop-use)
[^2]: [DSH-Go 安卓社区版实测（Flutter + Kotlin + 内置 Ubuntu/Node）](https://aiorang.com/article/aJmOhTl.html)
[^3]: [dsh-preset-mobile-use（要求 root，headless 虚拟显示 105 步绘图）](https://github.com/AcidGr/dsh-preset-mobile-use/blob/main/README.md)
[^4]: [witchan/ios-mcp（46 工具 / rootless iphoneos-arm64 / MIT / 安全说明）](https://github.com/witchan/ios-mcp)
[^5]: 官方模板 `@deepseek-ai/dsh-agent-preset/skills/cordis-plugin-development/templates/mcp/cordis.patch.yml`（包内）
[^6]: [官方桌面版下载与实测：apps/desktop 基于 Electron 封装完整 dsh Web 应用，自带 Node/Python 运行时，macOS arm64 / Windows x64，默认端口 19387](https://cloud.tencent.com/developer/article/2779419)；发布时间与平台见 [DeepSeek Harness 桌面版](https://baike.baidu.com/item/DeepSeek%20Harness桌面版/69202199)
[^7]: [官方仓库 `deepseek-ai/deepseek-harness`（README 仍以 `npx ... web` / `pnpm dsh web` 为主，desktop 为 `apps/desktop`，MIT）](https://github.com/deepseek-ai/deepseek-harness)；「无官方手机 App / 移动端仍在路线图」见 [DSH 手机端访问路径](https://dsh-plugin.org/zh/tutorials/dsh-mobile-access-paths) 与 [DeepSeek Harness in VS Code / from your phone](https://www.productcompass.pm/p/deepseek-harness-in-vs-code)
