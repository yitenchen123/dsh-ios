# DSH 第三方生态插件清单与 iOS 手动安装转化说明

> **范围声明**：DSH 官方包内自带的是 **Cordis 组件与 `@deepseek-ai/*` 包**（`@deepseek-ai/dsh`、`@deepseek-ai/dsh-mcp-client`、`@deepseek-ai/dsh-tools`、`@deepseek-ai/dsh-host-plugin-inventory` 等），**不算第三方生态插件**；本文只统计第三方／社区插件。本包（`dsh-ios`）不预装任何第三方插件。
>
> 检索日期：2026-11-10。适用底座：iPhone X（iPhone10,3）／A11 arm64／iOS 16.7.15／Dopamine 3.0 rootless（`/var/jb`）／Safari 16.6 WebKit。

---

## 0. 核实口径与可信度声明（先读）

**「已核实」的严格定义**：本次通过 WebSearch／WebFetch 实际检索到「插件名 + 来源 URL」的页面条目，并在「来源」列附了 URL。它**仅表示**该名称与链接在公开索引站／npm／GitHub 页面上出现过；**不等于**验证过功能真实性、star 数、许可证、安全性，**更不等于**在 iPhone X／A11 真机上跑通过。部分来源页面自带的数据（star 数、版本号、作者）彼此矛盾，本文不做仲裁，按「来源列所附页面」原样保留并标注分歧。

**「部分核实」**：仅见于百科、榜单、二手文章或聚合 README 的转述，未找到独立的一手仓库／npm 页面。

**「未核实」**：仅见于任务线索或无法找到独立来源；**「未知」**：该项找不到任何信息。

**兼容性两列全部是静态形态推断，未在真机验证**。判定依据＝安装形态、依赖清单、平台声明、`engines.node` 要求、是否含原生二进制；凡无明确证据一律写「未知」。「可（推断）」「不可（推断）」中的「推断」二字即表示这一限制，不要当成实测结论。**安装源问题（`github:`／git URL）由 §4 的转化规则处理**，故 iOS A11 列默认「已按规则归一化为 tarball／npm 名」后再判插件本体。

**同名多实现不合并**：`dsh-usage-stats`、`dsh-cost-meter`、`dsh-remote`、`dsh-pocket`、`dsh-qqbot`、`dsh-wechat` 等在多个索引站下挂不同作者的不同仓库，本文并列列出，不替用户选定唯一实现。

---

## 目录站／索引源（4 个任务线索均已核实）

| 站点 | 已核实 URL | 说明 | 备注 |
| --- | --- | --- | --- |
| dshfind | [dshfind.com/en](https://dshfind.com/en) · [索引源](https://api.dshfind.com/market/dsh-index.json) · [dsh-plugin-hub](https://dshfind.com/zh/plugins/dshplugin/dsh-plugin-hub) · [awesome-dsh-plugin](https://dshfind.com/zh/plugins/bruc3van/awesome-dsh-plugin?ref=badge) | 中文站，提供「自定义插件索引源」JSON、编辑推荐与分数 | 页面自称「仅 npm 包与其仓库做了匹配」「每日刷新」；收录数各页不一致（4,597／2 万+） |
| dsh.so | [dsh.so/zh/artifacts?cat=security](https://www.dsh.so/zh/artifacts?cat=security) · [?type=eco](https://www.dsh.so/zh/artifacts?type=eco) | 带 L1–L5 验证等级、静态扫描、沙盒安装实测 | 收录 25,482／25,508 个；明确「自动扫描，非人工审核」 |
| dshhub.dev | [dshhub.dev](https://dshhub.dev/) · [插件目录](https://dshhub.dev/plugins?sort=rising) | 按 9 类工作归档，强调「每条指向公开 GitHub 仓库」 | 自称 721／733 个仓库；[第三方说明](https://thehackstack.com/s/dsh-hub)与[研究索引说明](https://coderlegion.com/24872/a-source-first-way-to-explore-deepseek-harness-plugins)指出其「verified」仅指仓库可达，不含安全审计 |
| dshpluginhub.ai | [dshpluginhub.ai/en/plugins](https://dshpluginhub.ai/en/plugins) · [dsh-wechat-plugin](https://dshpluginhub.ai/zh/plugins/dsh-wechat-plugin) | 逐插件页给出完整安装命令、版本、功能长文 | 列表页自称 23,316 个插件；是使用最频繁的一手详情页来源 |

其余检索中实际出现、可供交叉核对的来源（非任务线索，但均附了真实 URL）：[dshhub.org](https://dshhub.org/zh-CN/plugins/ailawu0409/dsh-usage-stats)、[dsh-plugin.org](https://dsh-plugin.org/plugins/xcisxc29/dsh-wechat)、[dsh.plus](https://dsh.plus/zh/plugins/dsh-cost-meter)、[awesome-dsh-plugin.com](https://awesome-dsh-plugin.com/p/Jockjrop/dsh-usage-stats)、[deepseekharnessplugins.com](https://deepseekharnessplugins.com/learn/remote-access)、[deepseekserver.com](https://deepseekserver.com/resources/dsh-qqbot)、[dshx.io](https://dshx.io/zh/plugins/zaofan-dsh-qqbot)、[dsh.deepseek404.com](https://dsh.deepseek404.com/detail.php?id=bruc3van%2Fawesome-dsh-plugin)、[dsh-ai.com](https://dsh-ai.com/plugins/liyupi/dsh-kun-like-pet)、[deepseek-harness-plugin.com](https://deepseek-harness-plugin.com/plugins/dsh-wechat)、[dsh-plugin.top](https://dsh-plugin.top/plugin/liyupi/dsh-kun-like-pet)、[GitHub topic `dsh-plugin`](https://deepseekai.works/plugins)、[百度百科](https://baike.baidu.com/item/deepseek%20harness/68533699)、[官方站](https://www.deepseek.com/en/harness/)、[官方 harness 页](https://deepseek.com/harness/en)。

> 生态规模口径差异极大（同一时期各站自报 721 到 25,508 不等），且官方[插件说明](https://deepseekai.works/plugins)明确「**没有中央插件注册表**，唯一官方发现机制是 GitHub topic `dsh-plugin`，第三方目录站均非官方且内容未经官方审核」。本文据此把目录站当作「线索来源」而非「权威清单」。

---

## 1. 第三方生态插件总表

字段说明：**安装方式**列给出来源页面上实际出现的命令形态（详见 §3）；**iOS A11**／**Safari 16.6** 列为「可／不可／未知」并统一标注推断；**判定依据**列给出得出该判断的可核查事实；**核实状态**：已核实／部分核实／未核实。

### 1.1 IM ／ 通知机器人

| 插件名／包名 | 来源 | 一句话功能 | 安装方式 | iOS A11 | Safari 16.6 | 判定依据 | 核实状态 |
| --- | --- | --- | --- | --- | --- | --- | --- |
| `@xmanrui/dsh-im` | [npm 4.8.0](https://www.npmjs.com/package/@xmanrui/dsh-im/v/4.8.0) · [兼容性 issue #136](https://github.com/xmanrui/dsh-im/issues/136) · [Hub 页](https://dshpluginhub.ai/en/plugins/xmanrui-dsh-im) · [使用记](https://ystyle.top/2026/10/28/dsh-im-qq-whale-girl) | 微信／飞书／钉钉／企微／QQ／Slack／Telegram／Discord／WhatsApp／Matrix／iMessage 多渠道 IM 桥 | `dsh plugin --profile web add -w @xmanrui/dsh-im@4.8.0`（npm 带版本） | 不可（推断，直装） | 未知 | 官方装法要求 **Node ≥ 22.19**，与包内 v22.12.0 冲突；本项目 README 记载 `+ios9` 曾以「离线固化 114 依赖／0 个 `.node` + `dsh-compat` 零 JIT 补丁」跑通 5.10.0，说明**改造后可运行、直装不行**；零 JIT 档下 WhatsApp 加密历史同步哈希因无 WASM 只能返回占位值 | 已核实 |
| `@tencent-connect/dsh-qqbot` | [npm](https://www.npmjs.com/package/@tencent-connect/dsh-qqbot?activeTab=versions) · [Awesome DSH](https://deepseekserver.com/resources/dsh-qqbot) | 腾讯侧 QQ 官方机器人接入，扫码绑定私聊／群聊 | npm 包名 / 桌面版 GUI / 本地路径 / `--patch` 开发模式 | 不可（推断，直装） | 未知 | 走 `ws` + `node:https` + 全局 fetch 三条链路，本体纯 JS；但 README 记载 `+ios7` 必须把 32 个包／321 个纯文本文件固化进 `/var/jb/usr/lib/dsh/node_modules/` 才能绕开 127；扫码需手机 QQ 与开放平台凭据 | 已核实 |
| `@yuxiaoyu8192/dsh-qqbot` | [npm 0.5.0](https://www.npmjs.com/package/@yuxiaoyu8192/dsh-qqbot/v/0.5.0) | 与上一项 README 几乎一致的同源发布／fork | npm / 本地路径 / `--patch` | 不可（推断，直装） | 未知 | 同上；页面标题写 `@tencent-connect/dsh-qqbot` 但包名是 `@yuxiaoyu8192/...`，属同名多实现 | 已核实 |
| `@zaofan/dsh-qqbot` | [Socket.dev](https://socket.dev/npm/package/%40zaofan%2Fdsh-qqbot) · [dshx.io](https://dshx.io/zh/plugins/zaofan-dsh-qqbot) · [dshhub.org 的 RrOrange fork](https://dshhub.org/zh-TW/plugins/RrOrange/dsh-qqbot) | QQ Bot IM 增强 fork：表情库／富媒体／定时任务／多账号人格／悬浮球控制台 | `dsh plugin --profile web add @zaofan/dsh-qqbot@1.12.2`（npm 带版本） | 未知 | 未知 | 纯 npm 包名、TypeScript／JS、无原生依赖声明，形态上倾向可；dshx.io 明说「本轮只验证了包安装与 Web 侧入口，未登录真实 QQ」，并提示 peer 依赖可能对较新 `@deepseek-ai/dsh` 报警；dshhub.org 另收录 `RrOrange/dsh-qqbot` 同名 fork | 已核实 |
| `dsh-wechat-plugin`（仓库 `xcisxc29/dsh-wechat`） | [dsh-plugin.org](https://dsh-plugin.org/plugins/xcisxc29/dsh-wechat) · [中文页](https://dsh-plugin.org/zh/plugins/xcisxc29/dsh-wechat) · [Hub 页](https://dshpluginhub.ai/zh/plugins/dsh-wechat-plugin) · [目录页](https://deepseek-harness-plugin.com/plugins/dsh-wechat) | 微信遥控电脑上的 DSH：双向文本／图片／文件／语音／视频、手机端审批与多会话切换 | `dsh plugin add dsh-wechat-plugin`（npm 名）／`github:xcisxc29/dsh-wechat`（简写）／GitHub 仓库 URL／本地 `.tgz` 绝对路径 | 不可（推断） | 未知 | 常用 `github:` 简写与 git URL 需 git 二进制（真机无）；语音转 WAV 需可选 `silk-wasm`（WASM，零 JIT 档被 stub）；来源明说「必须跑在一台常开的电脑上」，与本包「手机即宿主」的形态相反；`allowBuilds` 需放行 prepare 脚本 | 已核实（**线索中的 `@xcisxc29/dsh-wechat` 包名形式未在任何来源出现**，见 §2） |
| `dsh-aurabot-qq`（`aureth-labs/...` 与 `accomplish07zrh-eng/...`） | [英文页](https://dsh-plugin.org/plugins/aureth-labs/dsh-aurabot-qq) · [中文页](https://dsh-plugin.org/zh/plugins/accomplish07zrh-eng/dsh-aurabot-qq) | QQ「大肥鱼」人格机器人：OneBot v11、心情／长期记忆／空间日记／主动搭话 | `dsh plugin --profile web add github:aureth-labs/dsh-aurabot-qq`（简写） | 不可（推断） | 未知 | `github:` 需 git；依赖 SnowLuma（Windows）或 NapCat／LLOneBot／Lagrange 网关、RVC 翻唱「Windows-only」、`edge-tts`／本地 CosyVoice／GPT-SoVITS TTS、Windows 自带语音兜底——整条链路是桌面／Windows 生态 | 已核实（两个不同 owner 前缀指向同类插件，见 §2） |
| `dsh-qqbot`（Awesome DSH 收录条目） | [deepseekserver.com](https://deepseekserver.com/resources/dsh-qqbot) | 与 `@tencent-connect/dsh-qqbot` 同源的目录条目 | npm 包名 / 本地路径 | 不可（推断，直装） | 未知 | 同 `@tencent-connect/dsh-qqbot`；此条用于说明「同一插件在不同索引站以不同名字出现」 | 已核实 |

### 1.2 远程协作

| 插件名／包名 | 来源 | 一句话功能 | 安装方式 | iOS A11 | Safari 16.6 | 判定依据 | 核实状态 |
| --- | --- | --- | --- | --- | --- | --- | --- |
| `@restregular/dsh-pocket`（dsh-pocket） | [Hub 页](https://dshpluginhub.ai/en/plugins/restregular-dsh-pocket) · [远程访问指南](https://deepseekharnessplugins.com/learn/remote-access) · [awesome-dsh-plugin](https://github.com/null119/awesome-dsh-plugin) | 电脑跑 `dsh web`、手机扫码同屏；局域网 + 公网隧道 + 访问密码 + 移动端适配 | `dsh plugin --profile web add @restregular/dsh-pocket`（npm）／`install_bundle`／本地目录安装 | 不可（推断，含原生可选依赖） | 可（推断，作者明确适配 iOS Safari） | Windows x64 可选依赖 `agentroam-cloudflared-win32-x64` 是**平台二进制**；`localhost.run` 隧道需 `ssh -R`（真机无 ssh）；但来源明写「iOS 使用 180/192 PNG 图标，避免 SVG 在主屏幕上显示空白」，说明手机页作者已针对 iOS Safari 主屏幕适配 | 已核实 |
| `shaobeichen/dsh-pocket` | [dshhub.dev 目录](https://dshhub.dev/plugins?sort=rising) | dshhub.dev 收录的同名另一实现 | 目录页「Install」按钮（源形式未展开） | 未知 | 未知 | 仅目录条目，未展开安装形态；与上项同名不同作者 | 已核实（仅目录条目） |
| `Autumn984/dsh-remote` | [awesome-dsh-plugin.com](https://awesome-dsh-plugin.com/zh/p/Autumn984/dsh-remote) | 手机零安装远程访问：二维码／Cloudflare 隧道／IPv6／视觉 Key 中转读图 | **tgz 本地绝对路径**（`dsh plugin --profile desktop add "D:\...\dsh-remote-1.2.0.tgz"`）／`git clone` + `pnpm pack` 源码安装 | 不可（推断） | 可（推断，作者声明 iOS Safari 可用） | 安装包内置 **Windows 版 cloudflared（52MB→18MB）**；示例路径是 `D:\`（Windows）；`git clone` 需 git。来源明写「只需浏览器（iOS Safari 即可），无需 App、无需公网 IP、无需升级系统」——前端侧有明确 iOS Safari 声明 | 已核实 |
| `@suj1e/dsh-remote` | [Hub 页](https://dshpluginhub.ai/en/plugins/suj1e-dsh-remote) | 远程设备端点白名单／配对码／Bearer 令牌／设备数据持久化 | `dsh plugin install @suj1e/dsh-remote`（npm）／本地路径 | 可（推断） | 未知 | 纯 host 侧 HTTP 服务 + `devices.json`，无原生依赖声明；默认 `bind 0.0.0.0` 在 iOS 上端口绑定与后台保活需实测 | 已核实 |
| `dsh-remote`（SSH 版，聚合清单描述） | [GitHub null119/awesome-dsh-plugin](https://github.com/null119/awesome-dsh-plugin) · [镜像站](https://dsh.deepseek404.com/detail.php?id=bruc3van%2Fawesome-dsh-plugin) | 多机 SSH（密码／私钥／agent／OTP／跳板机）+ 远程工作区 + 21 个 `rw_*` 工具 + SFTP + 端口转发 | 未在来源给出具体命令 | 不可（推断） | 未知 | 需 ssh 客户端／ssh-agent／私钥文件／跳板机，真机无 ssh 二进制与 `~/.ssh` 常规路径；「不监听 0.0.0.0」的说明也指向桌面宿主 | 部分核实（仅聚合清单转述） |
| `@linxin666/dsh-remote-bridge` | [Hub 页](https://dshpluginhub.ai/en/plugins/linxin666-dsh-remote-bridge) | 一条精确 `/ios/v1` WebSocket 路由的远程桥：会话列表／历史／实时增量／打断／审批 | npm 家族包（同组 `@linxin666/*` 均为 bundle） | 可（推断） | 未知 | 纯 WS 协议桥，无原生依赖描述；路由名带 `ios/v1` 但来源未说明与 iOS 设备的关系，**不要据此推断为 iOS 原生支持** | 已核实 |
| `@linxin666/dsh-remote-web-ui` | [Hub 页](https://dshpluginhub.ai/en/plugins/linxin666-dsh-remote-web-ui) | 扫码配对远程访问，手机竖屏触控适配 + PC 全桌面，一次性令牌 | npm 家族包 | 可（推断） | 可（推断，含手机竖屏适配层） | 来源明写「a portrait-touch adaptation layer for phones」，前端形态适配移动端 WebKit；无原生依赖描述 | 已核实 |
| `@linxin666/dsh-ssh` | [Hub 页](https://dshpluginhub.ai/en/plugins/linxin666-dsh-ssh) | 持久 `ssh2` 连接池 + 跳板机 + exec／PTY Web 终端／SFTP／本地端口转发／集群执行 | npm 家族包 | 可（推断） | 未知 | `ssh2` 是纯 JS 实现（不依赖系统 ssh 二进制），形态上可行；但 `~/.ssh/config` 导入路径与 PTY 在 iOS 上需实测 | 已核实 |
| `liguobao/ds-harness-remote` | [dshhub.dev 目录](https://dshhub.dev/plugins?sort=rising) | 远程访问类条目 | 目录页「Install」按钮 | 未知 | 未知 | 仅目录条目 | 已核实（仅目录条目） |
| `clarklevis1995/dsh-mobile` | [远程访问指南](https://deepseekharnessplugins.com/learn/remote-access) | **原生 iOS 客户端**，通过 `dsh-plugin-mobile-gateway` WebSocket 连桌面 | 独立 App（非 `dsh plugin add`） | 不可（推断，作为本包插件） | 不适用 | 来源明写「手机是客户端，活仍在电脑上干」；它是独立 App，不是能装进本包的 Cordis 插件 | 已核实 |
| `kelai141/dsh-mobile-apk` | [远程访问指南](https://deepseekharnessplugins.com/learn/remote-access) | Android 壳：WebView UI + 内嵌 Termux 运行时快照，解压即跑 | 独立 APK | 不可（推断） | 不适用 | Android／Termux 专属，与 iOS rootless 无关 | 已核实 |
| `zseven-w/dsh-ios` | [远程访问指南](https://deepseekharnessplugins.com/learn/remote-access) | 把**iOS 模拟器或 USB 连接的 iPhone** 塞进桌面聊天，让 agent 驱动它 | 插件（桌面侧） | 不可（推断） | 不适用 | 来源特别提醒「**它不把 DSH 装到你手机上**」；与本项目同名（`dsh-ios`）但完全无关，列出以免混淆 | 已核实 |
| `gdwhisper/dsh-web-startup-auth`、`slywalker2006/dsh-passwords`、`xgone/dsh-remote`、`juanwang-buaa/dsh-full-remote`、`pointer-a/dsh-server-login`、`summer1238/dsh-remote-web-gateway` | [远程访问指南](https://deepseekharnessplugins.com/learn/remote-access) | Web 暴露后的用户名／密码、MFA、角色权限、多租户、设备授权与撤销 | 未在来源给出具体命令 | 未知 | 未知 | 一组同类远程访问控制插件，来源只给出仓库名与 star，未展开安装形态 | 已核实（仅聚合条目） |

### 1.3 用量账单 ／ 成本

| 插件名／包名 | 来源 | 一句话功能 | 安装方式 | iOS A11 | Safari 16.6 | 判定依据 | 核实状态 |
| --- | --- | --- | --- | --- | --- | --- | --- |
| `dsh-usage-stats`（`ailawu0409/...`） | [dshhub.org](https://dshhub.org/zh-CN/plugins/ailawu0409/dsh-usage-stats) · [夜雨飘零](https://blog.yeyupiaoling.cn/article/1793985357412?lang=zh-tw) | GitHub 风格用量热力图、按模型拆解、账户余额；host 扫会话日志 + client 画图表 | **GitHub 仓库 URL**（`dsh plugin --profile desktop add https://github.com/ailawu0409/dsh-usage-stats`）／本地包路径 | 可（推断） | 未知 | 来源明写「**no third-party runtime dependencies**」、`index.js` host + `client.js` client 两半纯 JS、`node --check` 校验；需 DSH ≥ 0.2.2-rc.1 才有自定义导航图标（旧版回退默认齿轮不报错）。git URL 需按 §4 转 tarball | 已核实 |
| `@kindred7/dsh-usage-stats@0.4.7` | [Hub 页](https://dshpluginhub.ai/en/plugins/kindred7-dsh-usage-stats) | 设置页「使用统计」：累计／峰值、连续天数、一年热力图、按天曲线／按月堆叠柱 | `npx -y @deepseek-ai/dsh plugin --profile web add @kindred7/dsh-usage-stats@0.4.7`（带版本 npm） | 可（推断） | 未知 | 纯 npm 带版本、纯设置页渲染；`npx` 在真机不可用（见 §3），需退化为 npm 名 | 已核实 |
| `@sligqoer/dsh-usage-stats`（`Jockjrop/dsh-usage-stats`） | [awesome-dsh-plugin.com](https://awesome-dsh-plugin.com/p/Jockjrop/dsh-usage-stats) | 逐请求 token／成本／速度、按模型对比、余额与配额、LM 指纹采样 | npm 名 `@sligqoer/dsh-usage-stats` ／ **`github:Jockjrop/dsh-usage-stats`** | 可（推断，走 npm 名时） | 未知 | 来源明确给出两条安装路径并说明 GitHub 源首次会因 `allowBuilds` 被拦（`ERR_PNPM_GIT_DEP_PREPARE_NOT_ALLOWED` / `ERR_PNPM_IGNORED_BUILDS`）；`Detection` 采样要跑模型推理，A11 3GB／384MB 堆下需实测 | 已核实 |
| `@linxin666/dsh-usage` | [Hub 页](https://dshpluginhub.ai/en/plugins/linxin666-dsh-usage) | 各 provider 余额 + Coding Plan 配额检测 + 实时 token 账本 + 侧栏价目卡 | npm 家族包 | 可（推断） | 未知 | 纯 Web GUI 家族包，无原生依赖描述；余额查询需外网 + 凭据，属运行时条件而非安装形态 | 已核实 |
| `dsh-cost-meter`（`Han-1413141/...`） | [dsh.plus](https://dsh.plus/zh/plugins/dsh-cost-meter) · [Hub 页](https://dshpluginhub.ai/en/plugins/dsh-cost-meter) · [deepseekharnessplugins](https://deepseekharnessplugins.com/plugins/han-1413141/dsh-cost-meter) | 会话／每日／累计成本、预算、峰谷价提醒、多 provider 余额与 Coding Plan 配额 | npm 名 `dsh-cost-meter` ／ `github:Han-1413141/dsh-cost-meter#v1.9.62`（简写 + tag）／`github:...#68e0930...`（简写 + sha）／PowerShell `irm ... \| iex` 安装器 | 可（推断） | 未知 | 来源明写「**Requires Node.js ≥ 20**」，与包内 22.12.0 不冲突；纯 JS、MIT。Windows PowerShell 安装器会检查 pnpm 与 Git，真机不可用；「系统通知提醒」在 iOS Safari 16.6 需主屏幕 Web Push，能力受限 | 已核实 |
| `dsh-cost-meter`（`codeora-Kayson/...`） | [dshhub.org](https://dshhub.org/zh-CN/plugins/codeora-Kayson/dsh-cost-meter) | 同源同名另一实现：host 注册 loopback-only 余额路由、client 全量渲染、生成 `market.json` 索引 | `github:codeora-Kayson/dsh-cost-meter` ／ npm 名 `dsh-cost-meter`（发布后）／本地目录软链 | 可（推断） | 未知 | 来源明写「**桌面版由 Electron 独占，命令行会被拒绝**」→ 只走 web profile 时可行；`scripts/market.mjs` 生成 format 1 市场索引，是 §3 第 9 类的实例 | 已核实 |
| `dsh-cost-meter`（`maxwell234smith/...`） | [dshhub.org](https://dshhub.org/zh-CN/plugins/maxwell234smith/dsh-cost-meter) | 第三个同名实现：实时 API 费用，`cordis.patch.yml` 可覆盖单价／放假日／账本路径 | `npx -p @deepseek-ai/dsh dsh plugin --profile web add github:maxwell234smith/dsh-cost-meter` | 可（推断，走 npm 名时） | 未知 | 页面自标「兼容性：待验证」；`npx` 与 `github:` 在真机均需转化（§3／§4） | 已核实 |
| `dsh-context`（`bowenliang123/...`） | [Hub 页](https://dshpluginhub.ai/en/plugins/dsh-context) · [dshfind](https://dshfind.com/en) · [今日头条](https://www.toutiao.com/article/7703561217620640290) | 上下文洞察与管理：上下文仪表盘与 `/context` 命令、看上下文如何构成与演化 | npm 名（榜单中按热度列出） | 可（推断） | 未知 | 纯 Web GUI 插件，无原生依赖描述；头条文章把它与 `dsh-cost-meter` 并列为「用量和计费插件」 | 已核实 |
| `dsh-whale-widget`／`MeteorNOX/DeepSeek-Balance-Whale-Widget` | [dsh.plus](https://dsh.plus/zh/plugins/deepseek-balance-whale-widget) · [夜雨聆风](https://www.yeyulingfeng.com/a/1185344.html) · [Hub 页](https://dshpluginhub.ai/en/plugins/dsh-whale-widget) · [dshhub.dev 目录](https://dshhub.dev/plugins?sort=rising) | 右下角可拖拽小鲸鱼：余额、今日已用、每轮消耗气泡、峰谷价、音效 | `dsh plugin --profile web add github:MeteorNOX/DeepSeek-Balance-Whale-Widget`（简写）；npm 名 `dsh-whale-widget` | 可（推断） | 未知 | 文章明写「**纯 JavaScript，没有 peerDependencies**，MIT，0.4.2」，是形态上最干净的一类；但含音效播放（iOS Safari 需用户手势触发）、拖拽吸附，需实测 | 已核实 |
| `TokenLedger` | [GitHub null119/awesome-dsh-plugin](https://github.com/null119/awesome-dsh-plugin) · [镜像站](https://dsh.deepseek404.com/detail.php?id=bruc3van%2Fawesome-dsh-plugin) · [dshfind](https://dshfind.com/zh/plugins/bruc3van/awesome-dsh-plugin?ref=badge) | 令牌用量账本按**中转站归因**：零配置、无需凭据 | 未在来源给出具体命令 | 未知 | 未知 | 只在聚合清单／榜单里以名字出现，未找到独立一手仓库或 npm 页；功能描述（零配置、无需凭据）倾向纯前端，但无证据 | 部分核实 |

### 1.4 模型订阅 ／ 路由

| 插件名／包名 | 来源 | 一句话功能 | 安装方式 | iOS A11 | Safari 16.6 | 判定依据 | 核实状态 |
| --- | --- | --- | --- | --- | --- | --- | --- |
| `dsh-routing-suite` | [GitHub null119/awesome-dsh-plugin](https://github.com/null119/awesome-dsh-plugin) · [镜像站](https://dsh.deepseek404.com/detail.php?id=bruc3van%2Fawesome-dsh-plugin) | 任务感知的推理模式路由套装：先装运行时注入器，再装路由预设（实测覆盖 P1–P23） | 未在来源给出具体命令 | 未知 | 未知 | 来源明写「**注入器会修改运行时行为，安装前先读仓库说明**」——会改写 agent loop，零 JIT 档下需重点复核；无独立一手仓库页 | 部分核实 |
| `dsh-plugin-subscriptions` | [今日头条](https://www.toutiao.com/article/7703561217620640290) · [GitHub null119/awesome-dsh-plugin](https://github.com/null119/awesome-dsh-plugin) | 设置页用 OAuth 把 ChatGPT(Codex)／Claude／Grok／GitHub Copilot 订阅当模型，免 API Key | 未在来源给出具体命令 | 不可（推断） | 未知 | OAuth 登录需拉起系统浏览器回调 + 本地回调端口；iOS Safari 16.6 的 OAuth 回环与「添加到主屏幕」限制需实测，且订阅登录态依赖桌面客户端 | 部分核实 |
| `dsh-connect-workbuddy`（`dingminhua/...`） | [Hub 页](https://dshpluginhub.ai/en/plugins/dsh-connect-workbuddy) · [dshhub.dev 目录](https://dshhub.dev/plugins?sort=rising) | 接入本地已登录的 WorkBuddy 模型，读取点数倍率、多账号轮换、按模型图像输入开关 | npm 名 | 可（推断） | 未知 | 纯配置／API 类，无原生依赖描述；依赖「本地已登录」的 WorkBuddy 会话，真机无该登录态 | 已核实 |
| `superdesigndev/treg`（`treg-dsh`） | [dshfind](https://dshfind.com/en) · [dshhub.dev 目录](https://dshhub.dev/plugins?sort=rising) | 「面向 agent 工具的 OpenRouter」：一个 base URL + 一个 token 接 3,000+ 端点／60+ provider | 未在来源给出具体命令 | 可（推断） | 未知 | 纯 HTTP 代理配置类，无原生依赖描述 | 已核实（仅目录／推荐位） |
| `dsh-plan-execute` | [百度百科](https://baike.baidu.com/item/deepseek%20harness/68533699) | 双模型路由（规划／执行分离） | 未知 | 未知 | 未知 | 仅百科列举的功能增强类案例，无独立一手来源 | 部分核实 |
| `dsh-anchored-standard` | [dshfind](https://dshfind.com/en) | 针对「DSH V4 Pro 强依赖 API 可见工具目录」这一现象的条件化预设 | 未在来源给出具体命令 | 未知 | 未知 | 仅有编辑推荐位的一句话描述 | 已核实（仅推荐位） |
| `Ebony-Vinyl/dsh-our-free-model` | [dshhub.dev 目录](https://dshhub.dev/plugins?sort=rising) | 免费模型接入类条目 | 目录页「Install」按钮 | 未知 | 未知 | 仅目录条目，README 未展开 | 已核实（仅目录条目） |
| `ADWMC/helm-d`（`helmd`） | [dshhub.dev 目录](https://dshhub.dev/plugins?sort=rising) | 工作流／工具编排类条目 | 目录页「Install」按钮 | 未知 | 未知 | 仅目录条目 | 已核实（仅目录条目） |

### 1.5 桌面宠物 ／ UI 挂件

| 插件名／包名 | 来源 | 一句话功能 | 安装方式 | iOS A11 | Safari 16.6 | 判定依据 | 核实状态 |
| --- | --- | --- | --- | --- | --- | --- | --- |
| `liyupi/dsh-kun-like-pet` | [dsh-ai.com](https://dsh-ai.com/plugins/liyupi/dsh-kun-like-pet) · [deepseekharnessplugins](https://deepseekharnessplugins.com/zh/plugins/liyupi/dsh-kun-like-pet) · [dsh-plugin.top](https://dsh-plugin.top/plugin/liyupi/dsh-kun-like-pet) · [Awesome DSH](https://deepseekserver.com/resources/dsh-kun-like-pet) · [目录页](https://deepseek-harness-plugin.com/zh-CN/apps/dsh-kun-like-pet) | 右下角「小坤」桌宠：9 种状态精灵图动画，任务完成播放「你干嘛~哎哟」 | `dsh plugin --profile web add github:liyupi/dsh-kun-like-pet`（简写）／`git clone https://github.com/liyupi/dsh-kun-like-pet.git` + `node scripts/build-kunpet-package.mjs` 生成 JSON 载荷喂给 `cordis_define` | 不可（推断） | 未知 | 来源明写「**适配当前系统的播放命令——macOS 默认用 afplay；Windows／Linux 需要改成对应命令**」，且需宿主进程执行系统命令播音频、`assets/voice.mp3` 本地素材路径；`git clone` 与 `node scripts/*.mjs` 构建链路都超出纯 JS pnpm | 已核实 |
| `PC2005-cloud/dsh-pet` | [dshhub.dev 目录](https://dshhub.dev/plugins?sort=rising) | 桌宠类条目（Play 分类） | 目录页「Install」按钮 | 未知 | 未知 | 仅目录条目 | 已核实（仅目录条目） |
| `dsh-minigames` | [百度百科](https://baike.baidu.com/item/deepseek%20harness/68533699) | 俄罗斯方块／贪吃蛇等 18 款小游戏合集 | 未知 | 未知 | 未知 | 仅百科列举的娱乐类案例 | 部分核实 |
| `dsh-ads` / `dsh-anti-ads` | [百度百科](https://baike.baidu.com/item/deepseek%20harness/68533699) | 模拟 2005 年代中文互联网广告 UI，以及与之攻防的去广告插件 | 未知 | 未知 | 未知 | 仅百科列举，且被用作「插件间攻防」的生态举例 | 部分核实 |
| `dsh-qq2006` | [百度百科](https://baike.baidu.com/item/deepseek%20harness/68533699) | 复古 QQ 皮肤主题 | 未知 | 未知 | 未知 | 仅百科列举的主题类案例 | 部分核实 |
| `dsh-ui-whale` / `dsh-deep-whale`（`Small-tailqwq/...`） | [百度百科](https://baike.baidu.com/item/deepseek%20harness/68533699) · [dshfind](https://dshfind.com/en) | 像素鲸鱼主题 / 鲸鱼娘皮肤仓库（含明暗两套预览） | 未在来源给出具体命令 | 未知 | 未知 | 皮肤类，多为静态资源；dshfind 仅在推荐位出现 | 部分核实 |
| `dsh-gomoku` / `dsh-lazyfish` | [百度百科](https://baike.baidu.com/item/deepseek%20harness/68533699) | 五子棋 / 摸鱼面板 | 未知 | 未知 | 未知 | 仅百科列举的娱乐类案例 | 部分核实 |
| `elysia395/dsh-wallpaper-engine`（`dsh-plugin-wallpaper-engine`） | [dshhub.dev 目录](https://dshhub.dev/plugins?sort=rising) | 动态壁纸类 UI 条目 | 目录页「Install」按钮 | 未知 | 未知 | 仅目录条目；动态壁纸可能依赖视频／WebGL，Safari 16.6 需实测 | 已核实（仅目录条目） |
| `c1overzz/dsh-bili-scroll` | [dshhub.dev 目录](https://dshhub.dev/plugins?sort=rising) | B 站滚动／信息流类 UI 挂件 | 目录页「Install」按钮 | 未知 | 未知 | 仅目录条目 | 已核实（仅目录条目） |
| `dsh-plugin-pomodoro-float` | [官方站 Creator mode 演示](https://www.deepseek.com/en/harness/) | 悬浮番茄钟：官方演示「用对话生成并安装一个插件」的样例 | 由 `plugin_manager · install_bundle` 在会话内生成并安装 | 可（推断） | 未知 | 官方页面给出的完整轨迹显示它是 `package.json` + `client.js` 纯前端 bundle，无原生依赖；属「浏览器插件形态」 | 已核实 |
| `dsh-at-file` | [百度百科](https://baike.baidu.com/item/deepseek%20harness/68533699) · [guibai.dev](https://guibai.dev/a/7679542577553473590) | 输入框里 `@` 模糊引用本地文件／目录 | 未知 | 未知 | 未知 | 前端输入增强，形态上倾向可；host 侧需读本地文件系统（iOS 沙盒路径需实测） | 部分核实 |

### 1.6 开发者工具

| 插件名／包名 | 来源 | 一句话功能 | 安装方式 | iOS A11 | Safari 16.6 | 判定依据 | 核实状态 |
| --- | --- | --- | --- | --- | --- | --- | --- |
| `dshmarket` / `dsh-market`（`dsh-market/dsh-market`） | [Hub 页](https://dshpluginhub.ai/en/plugins/dshmarket) · [guibai.dev](https://guibai.dev/a/7679542577553473590) · [今日头条](https://www.toutiao.com/article/7703561217620640290) · [dshhub.dev 目录](https://dshhub.dev/plugins?sort=rising) | 装进 DSH 内部的可视化插件市场：搜索、一键安装、主题切换、配置备份 | npm 名 / 「在 DSH 官方源里搜索 dshmarket 并安装」 | 可（推断） | 未知 | 本身是纯 JS 市场前端；但它「一键安装」时会递归触发 §3 的全部源形式，其中 `github:`／git 仍需按 §4 转化 | 已核实 |
| `modlens` / `@liustack/modlens` | [Hub 页](https://dshpluginhub.ai/en/plugins/liustack-modlens) · [guibai.dev](https://guibai.dev/a/7679542577553473590) · [dshfind](https://dshfind.com/en) · [dshhub.dev](https://dshhub.dev/) | 给纯文本模型加视觉：粘贴图片 OCR 与版面分析 | npm 名 | 不可（推断） | 未知 | Hub 页明写「**powered by the free Antigravity CLI**」——依赖外部 CLI 二进制；`Autumn984/dsh-remote` 也把「视觉 Key + modlens」当外部依赖 | 已核实 |
| `dsh-vision-toolkit`（`Anionex/...`） | [dshfind](https://dshfind.com/en) · [dshhub.dev](https://dshhub.dev/) | 原生 Profile Bundle：意图感知图像问答、长截图 OCR、原像素取图 | 未在来源给出具体命令 | 未知 | 未知 | 仅推荐位／首页精选；视觉类在零 JIT 无 WASM 档下需实测 | 已核实（仅推荐位） |
| `dsh-web-ui` / `dsh-web`（`zhu1090093659/...`） | [guibai.dev](https://guibai.dev/a/7679542577553473590) · [dshfind](https://dshfind.com/en) · [dshhub.dev 目录](https://dshhub.dev/plugins?sort=rising) | 把聊天窗口升级为全功能控制台：任务看板、Git 图、实时 token 统计、桌宠 | 未在来源给出具体命令 | 未知 | 未知 | 榜单称其为 6.4k star 最高星插件；聚合类，含 Git 图（host 侧 git 操作，真机无 git 二进制） | 部分核实 |
| `dsh-better-sidebar` / `DSH-better-sidebar`（`omdsh-dev/...`） | [Hub 页](https://dshpluginhub.ai/en/plugins/dsh-better-sidebar) · [guibai.dev](https://guibai.dev/a/7679542577553473590) · [百度百科](https://baike.baidu.com/item/deepseek%20harness/68533699) | 每个会话独立的文件树／编辑器／变更／任务／侧栏聊天，并向其他插件暴露注册服务 | npm 名 | 可（推断） | 未知 | 纯 Web GUI，无原生依赖描述；但内嵌「real terminal」需宿主 PTY，iOS 上需实测 | 已核实 |
| `dsh-web-search-pro` / `dsh-free-search` | [guibai.dev](https://guibai.dev/a/7679542577553473590) · [Hub 页](https://dshpluginhub.ai/en/plugins/dsh-free-search) | 多引擎聚合搜索（27 引擎）、小红书／知乎／B 站定向抓取、本地结果缓存 | npm 名（`dsh-free-search`） | 可（推断） | 未知 | 纯 HTTP/fetch 类；零 JIT 档由 `fetch-shim.cjs` 接管 fetch，形态上可行 | 已核实 |
| `OpenViking` / `dsh-memory-evolve` / `dsh-mnemon` | [guibai.dev](https://guibai.dev/a/7679542577553473590) · [百度百科](https://baike.baidu.com/item/deepseek%20harness/68533699) · [Hub 页](https://dshpluginhub.ai/en/plugins/dsh-mnemon) | 跨会话长期记忆／自演化上下文库 | 未知（`dsh-mnemon` 走 npm 名） | 未知 | 未知 | `OpenViking`／`dsh-memory-evolve` 仅榜单与百科提及；`dsh-mnemon` 有 Hub 页但无依赖清单 | 部分核实 |
| `dsh-session-library` / `dsh-okf` | [guibai.dev](https://guibai.dev/a/7679542577553473590) | 把长 PDF 拆成「论点—证据链」做混合本地检索与深读 | 未知 | 未知 | 未知 | 仅榜单提及；本地检索可能依赖嵌入模型／向量库 | 部分核实 |
| `dsh-agent-teams`（`NanmiCoder/...`） | [百度百科](https://baike.baidu.com/item/deepseek%20harness/68533699) · [dshfind](https://dshfind.com/en) | 会话里一句话组建／管理多智能体协作团队 | 未在来源给出具体命令 | 未知 | 未知 | A11 3GB／384MB 堆下多 agent 并发内存压力需实测 | 部分核实 |
| `dsh-ops`（`T-Auto/...`） | [Hub 页](https://dshpluginhub.ai/en/plugins/dsh-ops) · [dshhub.dev 目录](https://dshhub.dev/plugins?sort=rising) | 原生文件与 PTC 工具；Windows-only 可选 Bash payload 与宿主 PowerShell 集成 | npm 名 | **不可（推断）** | 未知 | Hub 页明写平台矩阵「**Windows x64, Linux x64 and macOS arm64/x64**」——不含 iOS arm64；「Native file and PTC tools」+ PowerShell 集成指向平台专属 | 已核实 |
| `dsh-windows-mcp` | [Hub 页](https://dshpluginhub.ai/en/plugins/dsh-windows-mcp) | 把 CursorTouch／Windows-MCP（截图、UI 自动化、输入、剪贴板、进程、注册表）经官方 MCP 桥接进 DSH | npm 名 | **不可（推断）** | 未知 | 明确 Windows 桌面自动化，且 MCP server 是「外部进程、默认不启用、启动命令即可信可执行代码」；真机无 Windows API | 已核实 |
| `@wxg-prc-cpg/browser-skill-dsh-plugin` | [Hub 页](https://dshpluginhub.ai/en/plugins/wxg-prc-cpg-browser-skill-dsh-plugin) | 向模型暴露 `bsk_*` 浏览器自动化工具 | npm 家族包 | **不可（推断）** | 未知 | 浏览器自动化需 Chromium／受控浏览器二进制与外部进程；属 §4 的 Playwright 类 | 已核实 |
| `@linxin666/dsh-client-ui-git-graph` | [Hub 页](https://dshpluginhub.ai/en/plugins/linxin666-dsh-client-ui-git-graph) | 空白会话的 Git 分支选择器 + Git 图，**host 侧真实 git 操作**与守卫 | npm 家族包 | **不可（推断）** | 未知 | 来源明写「**real host-side git operations**」——真机无 git 二进制，必然 127；与 §3 规则 3／4 同源 | 已核实 |
| `@linxin666/dsh-update` | [Hub 页](https://dshpluginhub.ai/en/plugins/linxin666-dsh-update) | 侧栏自更新：探测 npm 新版本并「运行所属 profile 的 pnpm update」 | npm 家族包 | 不可（推断） | 未知 | 会在运行时再触发 pnpm 网络安装与可能的 build scripts；离线／零 JIT 档下不受控 | 已核实 |
| `cc-safety-net` | [Hub 页](https://dshpluginhub.ai/en/plugins/cc-safety-net) | coding agent CLI hook：拦截破坏性命令与敏感文件访问 | npm 名 | 可（推断） | 未知 | 纯 JS hook，无原生依赖描述 | 已核实 |
| `pi2dsh`（`weijiafu14/...`） | [deepseekharnessplugins](https://deepseekharnessplugins.com/plugins/weijiafu14/pi2dsh) · [dshfind](https://dshfind.com/zh/plugins/bruc3van/awesome-dsh-plugin?ref=badge) | 一层 Pi Host ABI，把未改动的 Pi 扩展原生挂载为 DSH 插件，并提供 convert 模式与 MCP 配置翻译 | `dsh plugin --profile web add pi2dsh`（npm 名） | **不可（推断）** | 未知 | 来源明写「**Requires Node.js 22.19+**」，与包内 **v22.12.0** 冲突（与 `@xmanrui/dsh-im` 同一类硬约束）；还涉及 `npx pi2dsh inspect/matrix/mcp-config` 与 `pnpm approve-builds` | 已核实 |
| `dsh-TUI`（`ccch1mneyyy/...`）／`@deepseek-harness-tui/dsh-tui`／`dsh-tianshu-tui`（`huiliyi37/...`） | [dshfind](https://dshfind.com/en) · [Hub 页](https://dshpluginhub.ai/en/plugins/deepseek-harness-tui-dsh-tui) · [dshhub.dev 目录](https://dshhub.dev/plugins?sort=rising) | 官方 TUI 缺位下的全屏交互式终端（Claude Code 风格） | 未在来源给出具体命令 | 不可（推断） | 不适用 | 全屏终端 TUI 依赖 TTY／终端能力；本包通过 Safari Web UI 使用，没有可挂载的 TTY | 已核实 |
| `dsh-openpencil`（`ZSeven-W/...`） | [dshfind](https://dshfind.com/en) | 设计稿生成类（「AI 做设计不该止于一张图」） | 未在来源给出具体命令 | 未知 | 未知 | 仅推荐位一句话描述 | 已核实（仅推荐位） |
| `tt-a1i/archify`、`ranxianglei/billion-context`、`sixtysevenlf/dsh-blender-plugin` | [dsh.so](https://www.dsh.so/zh/artifacts?type=eco) · [dshhub.dev 目录](https://dshhub.dev/plugins?sort=rising) | 交互式图表生成 / 超长上下文 / Blender 集成 | `dsh plugin --profile web add @tt-a1i/archify`（archify 在 dsh.so 给出） | 未知 | 未知 | 仅目录条目；`dsh-blender-plugin` 需外部 Blender 桌面程序，形态上不可 | 已核实（仅目录条目） |
| `dsh-claude-slides` / `dsh-claude-design` / `dsh-claude-design-system` / `dsh-claude-dashboard` | [Hub 四页](https://dshpluginhub.ai/en/plugins/dsh-claude-slides) · [design](https://dshpluginhub.ai/en/plugins/dsh-claude-design) · [system](https://dshpluginhub.ai/en/plugins/dsh-claude-design-system) · [dashboard](https://dshpluginhub.ai/en/plugins/dsh-claude-dashboard) | 把 baoyu-design 的 skill 包成 DSH 插件，生成可编辑幻灯片／画布／设计系统／仪表盘并在**本地编辑器**打开 | npm 名 | 不可（推断） | 未知 | 来源明写「opens them in a **local slide / canvas / design-system / dashboard editor**」——依赖本机图形编辑器进程 | 已核实 |
| `@linxin666/dsh-client-ui-skill-explorer` / `-task-board` / `-market` / `-web-ui-settings` / `@linxin666/dsh-web-all` | [Hub 列表页](https://dshpluginhub.ai/en/plugins) | 技能中心、任务看板、社区皮肤／桌宠市场卡、Web UI 设置分组、以及「一键装全部」的聚合包 | npm 家族包 | 可（推断，逐个看） | 未知 | `dsh-web-all` 是聚合 bundle，会一次拉起多个子插件；`-market` 从 `dsh-market.com` 下载资源，`-task-board` 含 cron 调度，需逐个复核 | 已核实 |

### 1.7 其他 ／ 安全审计 ／ 发行版

| 插件名／包名 | 来源 | 一句话功能 | 安装方式 | iOS A11 | Safari 16.6 | 判定依据 | 核实状态 |
| --- | --- | --- | --- | --- | --- | --- | --- |
| `api-relay-audit` | [GitHub null119/awesome-dsh-plugin](https://github.com/null119/awesome-dsh-plugin) · [镜像站](https://dsh.deepseek404.com/detail.php?id=bruc3van%2Fawesome-dsh-plugin) | 本地审计 AI API 中继：提示注入／模型替换／工具调用重写／SSE 异常／Web3 钱包风险 | 未在来源给出具体命令 | **不可（推断）** | 未知 | 来源明写「**单文件 Python 即跑即出脱敏报告（AGPL-3.0）**」——真机无 Python | 部分核实 |
| `dsh-pentest` | [GitHub null119/awesome-dsh-plugin](https://github.com/null119/awesome-dsh-plugin) | 授权范围内的渗透测试模式：目标／线索／验证结果／资产与漏洞视图 | 未在来源给出具体命令 | 未知 | 未知 | 仅聚合清单转述；并注明「仓库暂无许可证文件」 | 部分核实 |
| `dsh-undo-savepoint` | [GitHub null119/awesome-dsh-plugin](https://github.com/null119/awesome-dsh-plugin) | 配置与插件代码改动可撤销、secret-safe 快照、SAFE MODE、离线 CLI/GUI 回滚 | 未在来源给出具体命令 | 不可（推断） | 未知 | 含「**离线 CLI/GUI**」回滚工具，形态上依赖桌面可执行程序 | 部分核实 |
| `dsh-purge`（`YuJunZhiXue/...` 与 `mmparko/...`） | [dshhub.dev 目录](https://dshhub.dev/plugins?sort=rising) | 会话／缓存清理类条目 | 目录页「Install」按钮 | 未知 | 未知 | 仅目录条目，且两个不同作者同名 | 已核实（仅目录条目） |
| `oh-dsh`（`hust-open-atom-club/...`） | [dshfind](https://dshfind.com/en) | 华科开放原子开源社的 DSH 发行版 | 未在来源给出具体命令 | 不可（推断） | 未知 | 发行版（distribution）会自带运行时与预置插件，与本包「干净底座」冲突 | 已核实（仅推荐位） |
| `dsh-desktop`（`@anywhere-labs/...`）／`deepseek-harness-desktop` | [dshfind](https://dshfind.com/en) · [guibai.dev](https://guibai.dev/a/7679542577553473590) · [dshhub.dev 目录](https://dshhub.dev/plugins?sort=rising) | Windows／Mac 原生桌面客户端，免配 Node 与 `dsh web` | 独立安装包（非 `dsh plugin add`） | **不可（推断）** | 不适用 | 明确「native desktop client for **Windows and Mac**」、Electron 形态；iOS 无对应二进制 | 已核实 |
| `dsh-redteam-model`（`SeaOf0/...`） | [dshfind](https://dshfind.com/en) | 10 种授权安全研究工作模式（pentest／代码审计／二进制分析／事件响应等） | 未在来源给出具体命令 | 未知 | 未知 | 仅推荐位一句话描述；涉及二进制分析，形态上需要外部工具链 | 已核实（仅推荐位） |
| `dsh-vision`（`Anionex/...` 与百科条目） | [百度百科](https://baike.baidu.com/item/deepseek%20harness/68533699) | 视觉能力扩展 | 未知 | 未知 | 未知 | 仅百科列举的功能增强类案例 | 部分核实 |
| `dsh-plugin-claude-bridge` / `dsh-claude-move` | [百度百科](https://baike.baidu.com/item/deepseek%20harness/68533699) | 从 Claude Code 迁移／集成到 DSH 的桥接工具 | 未知 | 未知 | 未知 | 仅百科列举；需外部 Claude Code 客户端 | 部分核实 |
| `dsh-plugin-hub` | [dshfind](https://dshfind.com/zh/plugins/dshplugin/dsh-plugin-hub) | 独立的插件管理 GUI：已装列表、自定义安装（NPM 包／GitHub 源码／DSH 命令行三通道）、确认安装／卸载／更新、通知中心 | 独立 GUI 应用（含「在 Finder 中显示」） | **不可（推断）** | 不适用 | 来源明写「**在 Finder 中显示**」「`D:\...` 路径」等桌面文件管理器能力；且它自己就是安装入口，与本包 §4 的手动安装路径重叠 | 已核实 |

**收录条数**：以上共 **80 行条目**（含「同名多实现」并列与组合行，部分组合行内含多个插件名，故实际点名的插件多于 80 个），覆盖 7 个分类；其中「已核实」**60 行**、「部分核实」**20 行**。这个数量只是本次检索能附来源 URL 的切片，远小于各目录站自报的 721～25,508，**不是生态全集**。

---

## 2. 已核实 vs 推测／未核实（明确分界）

### 2.1 已核实（附来源 URL，见 §1「来源」列）

- **4 个目录站全部核实**：`dshfind.com`、`dsh.so`、`dshhub.dev`、`dshpluginhub.ai`（§0 表格）。
- **任务线索中的已知插件全部核实到来源**：`@xmanrui/dsh-im`、`@tencent-connect/dsh-qqbot`、`dsh-pocket`、`dsh-remote`、`pi2dsh`、`dsh-routing-suite`、`dsh-usage-stats`、`dsh-cost-meter`、`TokenLedger`、`DeepSeek-Balance-Whale-Widget`、`liyupi/dsh-kun-like-pet`、`@zaofan/dsh-qqbot`、`@xcisxc29/dsh-wechat`（对应仓库）、`accomplish07zrh-eng/dsh-aurabot-qq`。
- **扩展性核实**：`dsh-plugin-hub`、多个 `@linxin666/*` 家族包、`dsh-ops`、`dsh-windows-mcp`、`cc-safety-net`、`dsh-mnemon`、`dsh-free-search`、`dsh-claude-*`、`dshmarket`、各移动端客户端等，均附了一手页面 URL。
- **官方口径核实**：[deepseekai.works/plugins](https://deepseekai.works/plugins) 明确「无中央注册表、唯一官方发现机制是 GitHub topic `dsh-plugin`、第三方目录站非官方且未审核」；[官方 harness 页](https://deepseek.com/harness/en) 明确 `npx @deepseek-ai/dsh web` 与 `git clone https://github.com/deepseek-ai/deepseek-harness` 两条官方入口。

### 2.2 未核实／有分歧（不要当事实引用）

| 项 | 状态 | 说明 |
| --- | --- | --- |
| `@xcisxc29/dsh-wechat` 这个**包名形式** | **未核实** | 所有来源页面的仓库是 `xcisxc29/dsh-wechat`、npm 名是 `dsh-wechat-plugin`，**没有任何来源出现 `@xcisxc29/dsh-wechat` 这一 scope 包名**。线索里的写法不成立，安装请用 `dsh-wechat-plugin` 或 `github:xcisxc29/dsh-wechat`。 |
| `accomplish07zrh-eng/dsh-aurabot-qq` 与 `aureth-labs/dsh-aurabot-qq` | 有分歧 | [中文页](https://dsh-plugin.org/zh/plugins/accomplish07zrh-eng/dsh-aurabot-qq)与[英文页](https://dsh-plugin.org/plugins/aureth-labs/dsh-aurabot-qq)指向功能描述几乎相同的插件但 owner 不同；安装命令给的是 `github:aureth-labs/dsh-aurabot-qq`。不替用户判定哪个是上游。 |
| `dsh-usage-stats` 的 4 个作者（`ailawu0409` / `@kindred7` / `Jockjrop`+`@sligqoer` / 目录站另有收录） | 有分歧 | 同名不同实现，功能相似但仓库与包名不同，见 §1.3 并列行。 |
| `dsh-cost-meter` 的 3 个作者（`Han-1413141` / `codeora-Kayson` / `maxwell234smith`） | 有分歧 | 同上；`codeora-Kayson` 版明写「桌面版 Electron 独占」，另两版未提。 |
| `dsh-remote` 的 5+ 个作者（`Autumn984` / `@suj1e` / `scspotato` / `xgone` / 聚合清单里的 SSH 版） | 有分歧 | 名字相同、功能完全不同（手机远程 vs SSH 工具集 vs 端点白名单），见 §1.2。 |
| `dsh-pocket` 的 2 个作者（`@restregular` / `shaobeichen`） | 有分歧 | 见 §1.2。 |
| `TokenLedger`、`dsh-routing-suite`、`dsh-plan-execute`、`dsh-minigames`、`dsh-ads`/`dsh-anti-ads`、`dsh-qq2006`、`dsh-ui-whale`、`dsh-gomoku`、`dsh-lazyfish`、`OpenViking`、`dsh-memory-evolve`、`dsh-session-library`、`dsh-okf`、`dsh-vision`、`dsh-plugin-claude-bridge`、`dsh-claude-move`、`dsh-plugin-subscriptions`、`api-relay-audit`、`dsh-pentest`、`dsh-undo-savepoint`、`dsh-web-ui`、`dsh-at-file`、`dsh-agent-teams` | **部分核实** | 仅见于百度百科、guibai.dev 榜单、今日头条文章或 `awesome-dsh-plugin` 聚合 README 的**转述**，未找到独立一手仓库／npm 页；功能描述与安装方式一律不臆造，安装方式写「未知」。 |
| 各站自报的 star 数、收录总数、版本号、兼容等级（L1–L5／verified） | 不采信为事实 | 同一插件在不同站 star 相差数倍，同一站不同页面收录数不一致（dshfind 4,597 vs 2 万+；dsh.so 25,482 vs 25,508）；`dshhub.dev` 第三方说明明确其「verified」只表示仓库可达，不含安全审计。 |
| **所有 iOS A11／Safari 16.6 兼容性结论** | **推测，未真机验证** | 见 §0 口径。唯一例外是项目 README 自身记载的 `+ios7`（QQ Bot）与 `+ios9`（dsh-im）离线固化实测，已作为「判定依据」引用。 |

---

## 3. 安装方式全清单（iOS rootless 可行性）

**项目侧事实（来自 `/workspace/dsh-ios/README.md`，非推测）**：

- 真机上 **没有** `git` / `npm` / `npx` / `corepack` / `pnpm` 系统二进制（README 第 238 行），只有包内 node 与 **纯 JS pnpm 10.28.2（19MB / 0 个 `.node`）**，以 `/var/jb/usr/bin/pnpm` 由包内 node 直接跑（第 24–30 行）。
- `dsh` 的 `plugin` 子命令**把参数原样转发给 pnpm**（`bin.js:116`；`dsh-plugin-manager/types/index.js:217`）；缺 pnpm/npm/corepack/git 时必然**退出码 127**（第 27–30、231–238 行）。
- 内置 node 是 **v22.12.0**（A11 实测版，第 6 行）；`nowasm` 档＝ `--jitless --require fetch-shim.cjs`，**零 JIT、WASM 被 stub**（第 443、472 行）。A11／3GB、V8 堆限 384MB（第 564 行）。
- 项目内有 **Safari 16 垫片**（第 72 行）；Web UI 默认 `http://127.0.0.1:3080`。
- `+ios12` 已回退预装插件路线，改为「干净底座 + 内置纯 JS pnpm 让官方 `dsh plugin add` 可用」，包内 **0 预装插件**（第 6、607 行）。

据此逐条判定：

| # | 安装方式 | 示例（来自 §1 来源） | iOS rootless 可行性 | 为什么 |
| --- | --- | --- | --- | --- |
| 1 | **npm 包名** | `dsh plugin --profile web add dsh-cost-meter`、`pi2dsh`、`@restregular/dsh-pocket` | **可行** | `dsh plugin add` 原样转给包内纯 JS pnpm；pnpm 用 JS 解析 registry、用内置 `fetch` 下 tarball 并解包，全程不需要 npm/npx/corepack 二进制。零 JIT 档的 `fetch-shim.cjs` 已接管 fetch。**前提**：包内无 `.node`、不触发 `prepare`／build（pnpm 10 默认拦 build scripts，真机也无编译器）。 |
| 2 | **带版本 npm 包名** | `@xmanrui/dsh-im@4.8.0`、`@zaofan/dsh-qqbot@1.12.2`、`@kindred7/dsh-usage-stats@0.4.7` | **可行**（更推荐） | 同 #1，且锁版本／可复现。**注意**：版本能装上不代表能跑——`@xmanrui/dsh-im` 要求 Node ≥ 22.19，与 22.12.0 冲突；`pi2dsh` 同理。 |
| 3 | **`github:` 简写** | `github:liyupi/dsh-kun-like-pet`、`github:xcisxc29/dsh-wechat#commit`、`github:Han-1413141/dsh-cost-meter#v1.9.62`、`github:aureth-labs/dsh-aurabot-qq` | **不可行** | pnpm 的 git 依赖要起 `git` 子进程做 clone／checkout／`prepare`；真机无 git → 127。且 `prepare` 脚本被 pnpm 10 默认拦截（`ERR_PNPM_GIT_DEP_PREPARE_NOT_ALLOWED`／`ERR_PNPM_IGNORED_BUILDS`），需 `allowBuilds` 放行——真机没有编译链，放行也跑不动。**转化见 §4：改成 codeload tarball**。 |
| 4 | **GitHub 仓库 URL** | `dsh plugin --profile desktop add https://github.com/ailawu0409/dsh-usage-stats`、`https://github.com/xcisxc29/dsh-wechat` | **不可行** | pnpm 把 https 仓库 URL 内部同样降级为 git fetch／clone，仍需 git 二进制。**转化见 §4：改成 codeload tarball**。 |
| 5 | **`git+https://` URL** | `git+https://github.com/owner/repo.git#sha` | **不可行** | 显式 git 协议，需 git 二进制 + 网络出栈；子路径／ref 解析也依赖 git。**转化**：可取到 tarball 则改 tarball，否则提示用户换 npm 名。 |
| 6 | **`git@` SSH** | `git@github.com:owner/repo.git` | **不可行** | 需 git + ssh 客户端 + 私钥／`known_hosts`；rootless `/var/jb` 下无 ssh 二进制、无常规 `~/.ssh` 路径，且 DSH 社区分发基本不用 SSH。**转化**：提示改用 HTTPS tarball 或 npm 名，不尝试自动改写密钥。 |
| 7 | **tarball URL** | `https://registry.npmjs.org/.../pkg.tgz`、`https://codeload.github.com/<owner>/<repo>/tar.gz/<ref>`（GitHub 标准端点，此处仅为格式模板，不指向任何具体仓库） | **可行** | 纯 JS pnpm 用内置 fetch 下载、`fetch-shim.cjs` 在零 JIT 档兜底，tgz 解包也在 JS 层完成，无外部二进制。这是 §4 转化后的**目标形态**。**前提**：tarball 内是预构建产物（`lib/`、`dist/`、`client.js`），不含 `.node`、不含需要执行的 build／prepare。 |
| 8 | **本地目录路径 / `file:` / `link:` / 本地 `.tgz` 绝对路径** | `dsh plugin --profile web add /path/to/dsh-qqbot`、`dsh-remote-1.2.0.tgz`、`plugin_manager install_bundle <dir>`、`github:file:///...` | **可行但受限** | 不依赖网络与二进制，直接读本地文件，最稳的是 `file:` tgz。**限制**：① `link:` 方式 pnpm **不会为被链接目录安装其可选依赖**（`dsh-pocket` 来源明确写了这点，cloudflared 需先在该目录 `pnpm install`）；② 来源里大量出现 `D:\...`／`C:\...` Windows 路径，iOS 上必须换成 `/var/jb/...` 或 `$DSH_HOME/...` 的可写路径；③ 目录需归当前可写用户，否则触发 README 记载的 EACCES。 |
| 9 | **插件市场索引条目** | `https://api.dshfind.com/market/dsh-index.json`、`scripts/market.mjs` 生成的 `market.json`（format 1）、`dsh.so` 的 L1–L5 索引 | **可行（间接）** | 索引本身只是一份 JSON URL，Web UI 前端 fetch 后得到的是若干「npm 名／tarball／git 地址」条目，**最终仍要落到 #1～#8 之一**；目录站不代装（`dshhub.dev` 第三方说明明写「研究索引，不替任何人安装」）。注意：索引里若含 `github:`／git URL，仍需按 §4 转化；且官方[插件说明](https://deepseekai.works/plugins)明确「没有官方集中市场，所谓市场就是一份 format 1 的 JSON 索引，用户自己添加索引源」。 |
| 10 | **monorepo 子包** | `github:owner/repo#path:packages/foo`、`workspace:*`、pnpm workspace 内子包、`@scope/pkg` 指向 monorepo 内包 | **多数不可行** | `#path:` 语法要先 `git clone` 整仓再切子目录 → 需 git；`workspace:` 协议要求本地 workspace 根 + `pnpm-workspace.yaml`。**例外**：若子包已单独 publish 到 npm，则退化为 #1／#2 可行。**转化**：优先查子包的独立 npm 名；否则取整仓 codeload tarball，解包后在 JS 层只取目标子目录再按 #8 本地目录安装（codeload 只出整仓 tarball，不出子目录 tarball）。 |

> 补充：`npx -y @deepseek-ai/dsh plugin ...`（多个 Hub 页给出）与 `npx -p @deepseek-ai/dsh dsh plugin ...`、`irm ... \| iex`（PowerShell 安装器）、`npm install -g` 这几种**外层包装命令**在真机同样不可用（`npx`／`npm`／`irm` 都不是包内二进制）。但它们的**内层参数**（npm 包名、带版本包名）是可用的——手动安装路径应只提取内层参数交给 `dsh plugin add`。

---

## 4. `+ios15` 手动安装转化规则表

> **适用范围（硬边界）**：以下规则**只在 Web UI 手动安装路径生效**——即用户在「插件 → 添加插件／自定义安装」里**手动粘贴一个来源字符串**时，前端先做归一化再交给 `dsh plugin add`。
>
> **AI 帮你装（agent tool / CLI）不应用这套转化**：那条链路是模型／调用方直接把源字符串交给 `dsh plugin add`（原样转发给 pnpm），`+ios15` **不在那一层改写参数**——避免改变 agent 的既定意图、避免把用户／模型已经 pin 好的 commit 悄悄换成 tarball。换句话说：**人粘贴的才转化，AI 下令的不转化**。
>
> 转化只解决「把源码／包取到手」这一步（即 §3 的 #3～#6、#10）；**不解决运行期不兼容**（下面第 2～8 类），那些靠硬拦或提示处理。`+ios15` 修的是安装链路本身，不改运行时、不预装、不替用户选插件。

| # | 类别 | 识别信号（静态判定） | 转化动作 | 是否硬拦 |
| --- | --- | --- | --- | --- |
| 1 | 依赖 git 子进程的源 | `github:` 前缀 / `https://github.com/<owner>/<repo>` / `git+https://` / `git@` / `#path:` monorepo 子包 | **转 codeload tarball**：解析出 `<owner>/<repo>` 与 ref（`#sha`／`#tag`／分支→ ref），改写成 GitHub 标准 codeload tarball 端点（格式模板，不指向具体仓库）；`git@` 改 HTTPS；`#path:` 取整仓 tarball 后在 JS 解包层只取子目录并按本地目录装。解析不出 owner/repo 的原样保留并提示 | **否**（自动转化后放行）——这是 `+ios15` 的核心修复 |
| 2 | **原生 `.node` addon / 需 node-gyp 编译** | `gypfile`、`.node` 文件、`node-gyp`／`prebuild-install`／`sharp`／`better-sqlite3`、`install`／`prepare` 里跑编译、含平台三元组包名（`*-win32-x64`、`*-darwin-arm64`） | **前端提示 + 替代建议**：说明「A11 无编译工具链、`nowasm` 零 JIT 档无法加载 `.node`、包内 pnpm 0 个 `.node`」；建议找纯 JS／预构建 `lib/` 版本或 `pnpm pack` tarball；不改写安装源 | **是（硬拦）** |
| 3 | **Electron 桌面 / desktop profile 独占** | `electron`、`app.asar`、`--profile desktop`、来源写「桌面版由 Electron 独占，命令行会被拒绝」、`dsh-desktop` / `deepseek-harness-desktop` | **前端提示 + 替代建议**：只能走 `web` profile，给出同功能的纯 JS web 版；不改写 | **是（硬拦）** |
| 4 | **Playwright / Puppeteer / 浏览器自动化** | `playwright`、`puppeteer`、`chromium`、`BrowserSkill`／`bsk_*`、`CursorTouch`／`Windows-MCP`、安装期下载浏览器二进制 | **前端提示 + 替代建议**：改用宿主内置 fetch／search 工具或纯 HTTP 方案；不改写 | **是（硬拦）** |
| 5 | **macOS / Windows 专属 API 与平台二进制** | `afplay`、`PowerShell`／`irm ... \| iex`、`registry`、`win32-*`／`darwin-*` 包、`cloudflared-win32-x64`、`RVC (Windows-only)`、`SnowLuma (Windows)`、`D:\`／`C:\` 路径、「在 Finder 中显示」、系统音／系统通知 | **前端提示 + 替代建议**：把 Windows/macOS 路径提示改成 `/var/jb/...` 或 `$DSH_HOME/...`；只有**可选**能力（cloudflared、afplay 系统音、系统通知）时可剥离该能力后放行；核心能力依赖平台 API 则硬拦 | **是（硬拦）**，可选依赖降级为软提示 |
| 6 | **要求 Node ≥ 24（或任何 > 22.12.0 的下限，如 22.19+）** | `engines.node`、README 的「Requires Node.js 22.19+」／「Node >= 22.19」 | **前端提示 + 替代建议**：明确「包内 node 为 v22.12.0，安装链路不受 `engines` 影响但运行会失败」，建议锁到支持 22.12 的旧版本或换等价插件；**不改写安装源、不自动降级版本** | **否（软警告，用户可继续）** ——`+ios15` 只修安装链路，运行期约束交给用户决定；但必须给醒目提示（`@xmanrui/dsh-im`、`pi2dsh` 即此类） |
| 7 | **需要 Python 或本地编译** | `.py` 单文件、 `python`／`pip`、`Dockerfile`／`docker compose`、`make`／`gcc`／C/C++ 源码、`node scripts/build-*.mjs` 生成载荷 | **前端提示 + 替代建议**：真机无 Python／编译器／make，建议纯 JS 等价物或预构建产物；不改写 | **是（硬拦）** |
| 8 | **Docker** | `docker run`／`docker compose`／镜像名 | **前端提示 + 替代建议**：iOS rootless 无容器运行时；不改写 | **是（硬拦）** |
| 9 | **纯 JS 可兼容** | 0 个 `.node`、`engines.node` ≤ 22.12.0、无平台 API／外部 CLI／浏览器二进制依赖、声明 `dsh.bundle` 且带预构建 `lib/`／`client.js` | **直接放行**（仍统一走「tarball / npm 名」归一化，便于复现与锁版本） | **否** |
| 10 | **浏览器插件形态**（只有 `client.js`／`dsh.client` 声明，无 host 半） | `package.json` 只有 `dsh.client`、无 `dsh.bundle` patch、官方 Creator mode 生成的 `package.json + client.js` bundle | **直接放行** + 附 Safari 16.6 提示（无 WASM／无 `SharedArrayBuffer` 需求、Web Push 需「添加到主屏幕」且能力受限、拖拽／音效需用户手势）；不改写安装源 | **否** |

**判定优先级**：先跑 #1 做源归一化 → 再按 #2～#8 逐类扫描包内 manifest／依赖树／文件清单 → 命中硬拦类则停并给替代建议，只命中软警告类（#6、#10 提示）则带提示放行 → 全不命中即 #9 直接放行。硬拦不等于「禁止用户手动绕过」：Web UI 应保留「仍要试」入口，但把风险与依据写明（与 §0「不替用户选插件」一致）。

**不做的三件事**（避免越界）：不替用户挑同名多实现里的「唯一正确」仓库（§2.2）；不把 `engines` 不满足的包自动降到旧版本（#6）；不在 agent tool／CLI 路径上改写参数（开头硬边界）。

---

## 5. 与本项目关系

- **本包不预装任何第三方插件**。README 第 6、607 行记载：`+ios7`（QQ Bot）与 `+ios9`（`@xmanrui/dsh-im`）曾走「构建期把依赖树离线固化进 `/var/jb/usr/lib/dsh/node_modules/`」的预装路线，`+ios12` 已**整体回退**，改为「干净底座 + 内置纯 JS pnpm 10.28.2（0 个 `.node`）让官方 `dsh plugin add` 可用」，包内 0 预装插件。本文 §1 的所有插件**只是索引与判定参考**，不预置、不安装、不背书。
- **插件由用户自行安装**。用户从 §0 的目录站挑好插件，复制来源页上的安装命令，在 Web UI 手动安装路径里粘贴；`+ios15` 负责把其中在 iOS 上取不到的源形式归一化（§4 #1），并对运行期不兼容类别给硬拦／提示。
- **`+ios15` 修的是安装链路本身**。真机没有 `git` / `npm` / `npx` / `corepack` 二进制（README 第 238 行），`dsh plugin add` 又只是把参数原样转给 pnpm（`bin.js:116`），所以凡依赖 git 子进程的源（`github:` 简写、GitHub 仓库 URL、`git+https`、`git@` SSH、monorepo `#path:`）**必然退出码 127**——这与 node 版本、签名、A11、网络都无关（README 第 238 行原话）。`+ios15` 不动运行时、不改 Cordis、不注入补丁，只把「取包」这一步从 git 子进程换成纯 JS fetch + tarball。
- **运行底座决定了「不可」判定的边界**：A11 arm64 / 3GB、node v22.12.0、`nowasm` 零 JIT 档（`--jitless --require fetch-shim.cjs`，WASM 被 stub）、V8 堆 384MB（README 第 443、472、564 行）、Safari 16.6 WebKit（项目内有 Safari 16 垫片，第 72 行）。§1 里标「不可（推断）」的行，几乎都落在这几条约束上：原生 `.node`／平台 API／Electron／浏览器自动化／外部 CLI 或 Python／`engines.node > 22.12.0`。
- **与官方包内件的边界再申明**：Cordis 组件与 `@deepseek-ai/*`（`@deepseek-ai/dsh`、`dsh-mcp-client`、`dsh-tools`、`dsh-host-plugin-inventory`、`dsh-base`、`dsh-web-app` 等）是 DSH 官方自带、随包分发，**不在本文统计范围**；本文只统计第三方／社区插件。
- **风险提示**：多个索引站反复强调「插件以 dsh 进程权限运行，可读取文件、使用凭据、访问网络，工具审批不沙盒化」「GitHub 源还会在安装期跑 build scripts」「Hub 收录不等于安全审计」（见 [awesome-dsh-plugin.com 的 Jockjrop 页](https://awesome-dsh-plugin.com/p/Jockjrop/dsh-usage-stats)、[dshx.io](https://dshx.io/zh/plugins/zaofan-dsh-qqbot)、[官方插件说明](https://deepseekai.works/plugins)）。在 iOS 上更应只装可信源、锁版本或 pin commit，并在独立 profile 里先试。
