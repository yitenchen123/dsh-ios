# 单包（APP + DSH 0.2.2-rc.3 引擎 + 全屏入口）

本目录是 `dev.airdevs.dsh` **rc.3 全屏单包**的可复现构建与核验材料，也是
「最新 DSH + 像官方 App 一样点图标即用」的主交付。稳定底座
（`build.sh` 产出的 `0.2.1-rc.5+ios15` / `0.2.2-rc.1+ios16`）一个字节都没动。

## 四个档位：请装 `+ios24.2`

| 档位 | 内置 Node | DSH | 状态 |
| --- | --- | --- | --- |
| `+ios18` | 22.12.0 | 0.2.2-rc.3 | **坏包**：rc.3 要求 Node ≥24.9，CLI 起不来；仅作对照档 |
| `+ios24` | v24.19.0 | 0.2.2-rc.3 | **已被取代**：首版，A11 运行时脚本不兼容，见第二轮真机回归 |
| `+ios24.1` | v24.19.0 + 零 JIT 全链路 | 0.2.2-rc.3 | **已被取代**：修好启动/鉴权，但工作区/对话加载不出（见第三轮真机回归） |
| `+ios24.2` | **v24.19.0** + 零 JIT 全链路 + 数据兼容 | 0.2.2-rc.3 | **推荐**，A11 第三轮真机回归：修「工作区/对话加载不出」 |

**为什么 `+ios18` 是坏的**：rc.3 的 `package.json` 声明 `engines.node >= 24.9.0`，
且 `lib/bin.js` 用了 `import.meta.main`（Node 24.2+ 才支持）。22.12.0 上
`dsh web` 会静默无输出 / 直接失败——静态检查全过也起不来服务。这不是
「性能差一点」，是版本硬门槛。

**`+ios24` 的 Node 来源（可追溯）**：GitHub Actions
`node24-ios-jit (APRR / standard MAP_JIT)` run `43532556241`，2026-11-14
00:12 UTC 触发、`success`（编译 2h36m），`workflow_dispatch` 的
`node_ref` 填的是 `v24.19.0`，故 artifact 名为 `node24-ios-jit-v24.19.0`
（id `14095226518`）。同一份二进制也发布在 Release `node24-exp`：

```
node-v24.19.0-iphoneos-arm64-jit   82539696 字节
SHA-256  8bebb2a2e45824f9880ac99141ce0ee9359ec4fad72ccd1ef27bcd1341d77697
```

本机核验：`Mach-O 64-bit arm64 executable`、`cputype=ARM64`、
版本串 `v24.19.0`、JIT entitlements 已由 `ldid -S` 签入
（`allow-jit` / `allow-unsigned-executable-memory` / `dynamic-codesigning`
等 10 项，`jit-count=3`）。包内 `bin/node` 与该产物**逐字节一致**。
根 `ent.plist` 与 `node24/payload/ent.plist` 10 项完全相同，postinst 只在
缺 entitlement 时才补签，不会覆盖掉 JIT 权限。

构建（并列实验档，`DSH_IOS_TAG` 只改 stage 内 control 的 Version，
仓库 `DEBIAN/control` 原文件与 `+ios18` 交付物都不动）：

```sh
NODE_IOS_BIN=/path/to/node-v24.19.0-iphoneos-arm64-jit \
DSH_IOS_TAG=ios24.2 \
  sh one-package/build-one-package.sh \
    bundles/dsh-nodemodules-0.2.2-rc.3+ios1.tar.gz \
    app-bundle/payload \
    dist/dev.airdevs.dsh_0.2.2-rc.3+ios24.2_iphoneos-arm64.deb

DSH_IOS_TAG=ios24.2 sh one-package/verify-one-package.sh \
    dist/dev.airdevs.dsh_0.2.2-rc.3+ios24.2_iphoneos-arm64.deb \
    bundles/dsh-nodemodules-0.2.2-rc.3+ios1.tar.gz app-bundle/payload
```

另有旁路可回滚的 `dev.airdevs.dsh-node24_0.2.2-rc.3+ios24exp1`（`exp/node24`
分支的 `node24/build-experimental-deb.sh` 产出）：只落
`/var/jb/usr/lib/dsh-node24/` 与 `dsh24*`，用 `dsh24-switch` 切换，
适合先验证 Node 24 能否在设备上跑，不影响主包。

**诚实边界（2026-11-14 第二轮真机截图后更正）**：首版 `+ios24` 在 iPhone X /
A11 / iOS 16.7.x 上**并没有跑起来**。此前「设置页显示 rc.3、证明 Node 24 在 A11
上能用」的结论来自用户后来明确指出「给错了」的那张安装截图，不能作为证据。
真机实测是：四档原生 JIT 全部 `SIGBUS(138)`，`dsh` 直接 `Bus error: 10`；
Web Clip 只显示 401 黑页。也就是说 **Node 24.19.0 的 JIT / W^X 在 A11 上确实
不可用**（即便 `dynamic-codesigning` 已签），必须全程走 `--jitless` 零 JIT 档。
`+ios24.2` 已按这个事实重做，但**零 JIT 档在 A11 真机上的最终表现仍需用户
装包 / 跑热修后再确认，本仓库不承诺 A11 100% 成功**。该二进制按
`--without-npm --without-inspector --with-intl=small-icu
--without-node-snapshot --without-node-code-cache --openssl-no-asm` 裁剪，
启动会略慢、非英语 `Intl` 数据受限。稳定档 `+ios15`（rc.5 + Node 22.12.0）
仍是唯一真机验证过的组合，逐字节未做改动。

## 为什么之前「依旧不是全屏」

| 层 | 旧状态 | 结果 |
| --- | --- | --- |
| native `DSH.app` | `SFSafariViewController` + `barCollapsingEnabled` | 永远带 Safari 顶栏/底栏/关闭按钮，只是「近似全屏」 |
| 全屏 Web Clip | `build-one-package.sh` **没把 `dsh-extras-postinst.sh` 打进包**，postinst 的 `[ -x "$EX" ]` 恒为假 | `FullScreen=true` 的 Web Clip 从来没装进设备 |
| rc.3 鉴权 | `processLaunchToken()` 每次随机生成 token，而 Web Clip URL 是静态的且不带 token | 点开图标必然 401，前端 JS / 插件 / 工作区 / 对话全部不加载 |
| 探活 | `dsh-app-ctl ping` 用 `statusCode < 500`，把 401 判为「可连」 | daemon 卡在 30s 待机循环、App 探针误判成功 |
| 用户数据 | postinst / extras 里 `chown -R` / `chmod -R` / `config-on` / 写 `.npmrc` 与 `state.json` | 升级会改动已有对话、工作区、插件配置 |

真正无浏览器栏的入口是 `FullScreen=true` 的 standalone Web Clip：有自己的
桌面图标、启动画面，和普通 App 一样。native `DSH.app` 降级为「确保 launchd
daemon + 兜底打开」的辅助壳，不再被描述成全屏。

## 真机回归（+ios24 / iPhone X / iOS 16.7.15，2026-11-14）

首版 `+ios24` 的构建链漏打全套兼容补丁，用户实测截图暴露 4 个问题（这些
截图里能看到设置页，但那不是 `+ios24` 本包跑起来的证据 —— 用户后来明确
指出安装截图给错了，见下一节）：

| 症状 | 根因 | 修复 |
| --- | --- | --- |
| 插件市场 / 插件目录**全部 `fetch failed`**（6 次重试，腾讯 / npmmirror / awesome-dsh 全挂） | `build-one-package.sh` 只把 `shims/*.cjs` **复制进包却一个都没执行**，rc.3 引擎树是裸的：`fetchIndex()` 用 `redirect:"error"` 遇 CDN 跳转即失败，`parseIndexInWorker()` 起子 Worker 在 A11 上 SIGBUS | 构建期执行 `apply_plugin_install_patch.cjs`（改 `redirect:"follow"` + 主线程解析 + 派生 `worker-parse.cjs`） |
| 「选择工作区目录」弹窗报 **`AbortSignal.any is not a function`** | iOS 16.7 = Safari 16.6，缺 `AbortSignal.any` / `Promise.withResolvers` 等 Safari 17.4+ API；`index.html` 没注入 `safari16-polyfill.js` | 构建期执行 `apply_frontend_inject.cjs`，在 `<head>`、module 之前注入垫片与转化逻辑 |
| 「**安装插件前需要先配置 pnpm 环境**」 | 单包没打 `libexec/pnpm`（19MB 纯 JS 发行版），也没执行 `apply_pnpm_abs_patch.cjs` | 构建期复制 `bundles/pnpm` → `libexec/pnpm`，并执行 pnpm 绝对路径直连补丁 |
| 桌面**两个图标**、一个叫 **Untitled**；点开是带 Safari 顶栏/底栏的半屏界面 | Web Clip 的 `Info.plist` 写了 `CFBundleDisplayName`，但 SpringBoard 读的是 `Title` 键；且 `extras` 会 `register` 把半屏 `SFSafariViewController` 的 native APP 图标刷到桌面 | Web Clip 补 `Title`/`PayloadDisplayName`；单包内给 native APP 注入 `SBAppTags=hidden` 并去掉 `register`，桌面只留一个全屏入口（app-bundle 独立包不受影响） |

**教训**：「shims 在 deb 里」≠「补丁已应用」。`build.sh`（稳定底座）
一直执行全套兼容补丁，单包构建却只复制脚本。现在 `build-one-package.sh`
执行与稳定底座相同的 6 组补丁，并加了构建期强断言 + `verify-one-package.sh`
的 3b 段回归检查（逐文件校验垫片 / 插件市场 / pnpm / 转化钩子真的落到引擎树），
从根上杜绝「假绿」。

**版本分流（2026-11-14 第三轮更正）**：`apply_compat_patches.py` 里补
Node 22.12 缺失 API 的 3 条（`import.meta.main` / zstd 降级 / `stripTypeScriptTypes`）
只在内置 node 主版本 `< 24` 时应用，Node 24 原生支持，跳过是对的。但第 4 条
`DEFAULT_COMPRESSION zstd→none` 的本质是**兼容用户从 +ios15/+ios18 带来的明文
`.jsonl` 会话数据**，与 Node 版本无关 —— 它曾因「整包跳过」被误删，正是
+ios24.1「工作区/对话加载不出」的根因。现由 `make_ios_data_compat.py` 对
**所有档位**的单包 stage 副本单独补回（Node22 档幂等跳过），doctor 严格断言
none。另：`apply_compat_patches.py` 是共享文件，一个字节都没动，稳定底座
SHA 不变。下面第三轮真机回归详述这条因果链。

## 真机回归第三轮（+ios24.2 / iPhone X / A11，2026-11-14，工作区/对话加载不出）

用户装好 `+ios24.1` 后安装与 doctor 全过（`OK=28 WARN=1 FAIL=0`），但全屏
UI 里工作区/对话加载不出，点「选择工作区目录」报 `typert gateway:
directoryPicker/list: active Service "directoryPickerController" is
unavailable`，doctor 里夹着 `session-xxx.jsonl uses .jsonl but configured
for compression "zstd"`。这是两个**与鉴权/零 JIT 无关的数据层 bug**：

| 症状 | 文件级根因 | `+ios24.2` 修复 |
| --- | --- | --- |
| 工作区/对话全空、目录选择器 service unavailable | rc.3 的 `dsh-session-persistence-jsonl` 默认 `zstd`，而 `cordis.patch.yml` 只设 root 不设 compression。用户既有会话是稳定底座写出的明文 `.jsonl`；`checkRootEncoding()` 在 create/open/list 入口全局执行，发现 opposite 编码即抛 `encodingMismatch` → host 装配 fatal（`headless boot rc=1`）→ workspace/session/directoryPicker 所有 controller `pending` | `make_ios_data_compat.py`：`DEFAULT_COMPRESSION` 改回 `"none"`；doctor 第 16 项严格断言 none（漏打补丁必 FAIL） |
| 「选择工作区目录」列不出目录 | iOS `process.platform==="darwin"` 让 `directory-picker-auto` 选 native（`osascript`/NSOpenPanel，iOS 无），前端 browse UI 调 `list` 需要 browse capability | 同脚本把 iOS/darwin 目录选择器强制 `browse`（纯 `node:fs/promises`） |

**A/B 端到端实证**（Linux Node 24.19.0，含明文 `.jsonl` 的 DSH_HOME）：
未修包 `dsh web` 日志 = `4 entries did not activate` + `workspace /
session-controller / workspace-controller / ui-deliverables` 全部 `pending
(waiting for service: workspaceRegistry/sessionController)`；`+ios24.2`
同一场景日志**只有一行启动地址、零挂起**，鉴权 `401 → 303 + Cookie` 通过。

**修复文件**：新增 `one-package/make_ios_data_compat.py`（构建期只改单包 stage
依赖树副本，共享 `shims/` / `payload/` 一字节不动）；`build-one-package.sh`
[7/6] 调用并做强断言；`verify-one-package.sh` 3b-2 段 9 项断言；
`make_node24_runtime.py` 的 doctor 会话压缩段改严格断言 none；
`dist/fix-ios24.sh` 新增 step 0（sed 版就地热修，BSD sed 兼容、幂等）。
稳定底座 `67d54667…` 与 +ios18 `927b5308…` 逐字节未变。单包 **97 项 0 失败**、
两次构建 SHA 一致（`1b44deff…`）、APP 包 77/0、doctor 27 OK/0 FAIL。

**已装 `+ios24.1` 的用户**：传 `dist/fix-ios24.sh` 到手机跑 `sh fix-ios24.sh`
（幂等、零写入 `$DSH_HOME`），再 `respring`；或重装 `+ios24.2`。对话/工作区/
插件/配置原样保留。仍不承诺 A11 100% 成功（SpringBoard 缓存刷新需实机确认）。

## 真机回归第二轮（+ios24.1 / iPhone X / A11，2026-11-14）

用户装的是 `+ios24`（不是之前给错的那张安装截图），三张真机截图分别是：
全屏 Web Clip 黑底一行 `dsh web authentication required; reopen the URL
printed by dsh web.`；终端 `dsh` → `Bus error: 10` +「所有 V8 启动档位都在
WASM 冒烟探针里失败了」；`dsh-doctor` → 抬头写着 `+ios15`、`OK=17 FAIL=12`。

| 症状 | 文件级根因 | `+ios24.1` 修复 |
| --- | --- | --- |
| `dsh` / daemon 起不来 | 单包 3b 把稳定底座 `payload/usr/bin/dsh`、`dsh-doctor`、`tier.sh` 原样复制进来。`tier.sh` 的 `nowasm` 档和 `usr/bin/pnpm`、`apply_pnpm_abs_patch.cjs` 注入的 `__dshPnpmFlags` 都带 `--no-expose-wasm` —— 这个 V8 flag 在 Node 24 / V8 13.x **已删除**，传了就是 `bad option` 退出 9。A11 上 `native/single/balanced/safe` 四档全 `SIGBUS(138)`，唯一能活的零 JIT 档被这一个废参数挡死 | `make_node24_runtime.py` 去掉所有生效行的废参数；新增 `node-safe`（`--jitless --require fetch-shim.cjs`）；`dsh`/`tier.sh` 全档失败兜底到 `nowasm`；共享 `payload/`、`shims/` 一个字节不动，稳定底座 SHA 不变 |
| `dsh-doctor` 12 个 FAIL、抬头 `+ios15` | doctor 硬编码 Node 22.12.0 的 `101,297,040` 字节、DSH `0.2.1-rc.5`、`+ios15` 抬头；且 heal / patch 解析 / `--check` / `node:sqlite` / 各 `apply_*.cjs` 都**裸跑 node**（不带零 JIT），在 A11 上连锁 `SIGBUS`，多数 FAIL 是误报 | doctor 改为 rc.3 / Node 24 版本感知（大小只做 >20MB 完整性、版本号 `0.2.2-rc.3`、第二版曾让会话 zstd 按 Node 24 原生支持宽容放行，第三轮已更正为严格断言 none —— 见上一章），所有短命调用改走 `NODE_SAFE`；`ctl ping` 也接上 `SAFE_NODE` |
| 全屏图标打开只有 401 黑页 | postinst 只跑 `dsh-app-ctl enable`，其 `kickstart` 不带 `-k`，launchd 认为服务已在运行 → 升级后 3080 上仍是**旧 daemon**（内存里是随机 `launchToken` 的旧引擎树），固定 token 的 Web Clip 必然 401；旧 Web Clip（无 token / 旧 token / Untitled）还被 SpringBoard 缓存 | `dsh-extras-postinst.sh`：bootout `dev.airdevs.dsh` / `dev.airdevs.dsh-app`、清掉占 3080 的孤儿进程、删掉所有指向 `127.0.0.1:3080` 的旧 Web Clip、重写带 `Title`/`FullScreen`/固定 token 的新 Web Clip、bootstrap + `kickstart -k` 强制换进程、用固定 token 真探 `303/200` |

**关键取舍**：共享 `shims/apply_pnpm_abs_patch.cjs` 会被 `make_fix_ios15.py`
内嵌进 `fix-ios15.sh` 并打进稳定底座 deb，改一个字节就会改变已发布的
`+ios15` SHA。所以单包另建 `apply_pnpm_abs_patch_node24.cjs`（MARK 仍为
`dsh-ios +ios14`，设备端自愈会幂等跳过），构建与设备端热修都用这份副本。

**已装首版 `+ios24` 的用户**不必等重装：把 `dist/fix-ios24.sh` 传到手机，
`sh fix-ios24.sh` 会就地完成同样的修复（幂等、零写入 `$DSH_HOME`），
跑完 `respring` 一次即可。重装 `+ios24.1` 是更彻底的做法。

**仍未验证的部分**：零 JIT 档在 A11 / iOS 16.7.15 真机上的最终表现、
SpringBoard 对 Web Clip 的缓存刷新时机，仍需用户实机确认；本仓库不承诺
A11 100% 成功。Linux x64 的 Node 24.19.0 上已实跑 `--jitless + fetch-shim`
下的 `web` 监听、`smoke.js`、`pnpm --version`、`node:sqlite`、前端垫片
`--check` 与 `401 → 303 + Cookie → 200` 全链路，作为 JS 层证据。

## 修复方案

**固定 loopback token（单一真相源 `one-package/dsh-web-token`）**

`shims/apply_fixed_token_patch.cjs` 让 rc.3 的 `processLaunchToken()` 返回
`process.env.DSH_WEB_TOKEN || <常量>`。四处必须逐字相同，由构建期与
`verify-one-package.sh` 强校验：

1. `one-package/dsh-web-token`
2. `one-package/webclip/Info.plist` 的 `URL` → `http://127.0.0.1:3080/?token=<常量>`
3. `app-bundle/payload/.../dev.airdevs.dsh.plist` 的 `EnvironmentVariables.DSH_WEB_TOKEN`
4. `apply_fixed_token_patch.cjs` / `dsh-daemon` / `dsh-app-ctl` / `dsh-app-ui` 的缺省值

首次访问静态 URL → `303 + Set-Cookie`，之后所有 API / SSE / WebSocket 走
cookie，插件 / 工作区 / 对话全部正常加载。该值不是机密：loopback-only，
rc.1 时代本机 Web UI 根本没有 token 机制，安全模型未变。

**构建链补齐**：`build-one-package.sh` 现在会真正打包
extras、`DSHLauncher` / helper / 图标、`usr/bin/dsh` 等 wrapper、shims 运行时、
Web Clip 资产，并调用固定 token 补丁；`chown 0:0` + mode 归一化 +
`SOURCE_DATE_EPOCH` + `-z9` 保证可复现。`chown` 之后才设 `4755`
（`chown(2)` 会清 setuid 位，旧版顺序反了导致 helper 无法拉起 daemon）。

**零写入 `$DSH_HOME`**：安装 / 卸载 / 启动不 `chown -R`、不 `chmod -R`、
不 `config-on/off`、不写 `.npmrc` / `.dsh-market/state.json`、不建
`$DSH_HOME/logs`。日志统一放 `/var/jb/var/log/dsh-app`。
phone-bridge daemon 也随之修掉自动 `ensure-config on` 与日志路径。
`app-bundle/verify-no-data-touch.sh` 用 17 个预置用户数据文件做全量
SHA-256 / mode / 属主指纹前后对比，实测通过。

## 目录

- `DEBIAN/control`、`postinst`、`prerm`：单包元数据与安装/卸载脚本。
- `dsh-extras-postinst.sh` / `dsh-extras-prerm.sh`：**全屏 Web Clip 安装 + uicache**、APP 签名、launchd 保活、卸载清理；`+ios24.2` 起还负责强制换掉旧 daemon 与清理旧 Web Clip。
- `webclip/`：`FullScreen=true` 的 `Info.plist` 与 `icon.png`；构建期额外写入 `token`（与 `dsh-web-token` 同源）。
- `dsh-web-token`：固定 loopback token，唯一真相源。
- `make_node24_runtime.py`：**仅对 stage 副本**打 Node 24 零 JIT 运行时补丁（去掉 `--no-expose-wasm`、部署 `node-safe`、doctor 版本感知 + 严格断言会话压缩 none），按内置 node 主版本自动触发；共享 `payload/`、`shims/` 不动。
- `make_ios_data_compat.py`：**仅对单包 stage 依赖树副本**修「工作区/对话加载不出」——会话默认压缩 `zstd→none`（兼容用户明文 `.jsonl`）、iOS/darwin 目录选择器强制 `browse`；幂等，所有档位生效，共享文件不动。构建期 [7/6] 调用，设备端 sed 版在 `dist/fix-ios24.sh` step 0。
- `apply_pnpm_abs_patch_node24.cjs`：pnpm 绝对路径直连补丁的单包专用副本（`__dshPnpmFlags` 无废 flag），避免改共享 shim 影响稳定底座 SHA。
- `apply_plugin_install_patch_rc3.cjs`：插件市场 / 手动安装补丁的单包专用副本（支持 rc.3 minified `client.js` 锚点）。
- `build-one-package.sh`：组装 deb。
- `verify-one-package.sh`：独立核验（含**静态 Web Clip URL 的 rc.3 鉴权黑盒**、Node 24 运行时与升级路径断言，共 97 项）。
- `../dist/fix-ios24.sh`：已装首版 `+ios24` 的**设备端就地热修**，不必重装 deb。
- `patch-rc3-client-transform.sh`：历史遗留的可选替换脚本。现已被 `shims/apply_plugin_install_patch.cjs` 的「源码 / minify bundle 双锚点」通用注入取代（rc.3 的 `client.js` 是 webpack bundle，+ios15 补丁锚点命中 0 次），构建链不再调用它。

## 构建

```sh
# 引擎树来源（三选一）：
#   a) 本仓库 exp/node24 分支的 bundles/dsh-nodemodules-0.2.2-rc.3+ios1.tar.gz
#   b) GitHub Release 附件（需发布者上传该 asset）
#   c) 已解好的目录，内含 node_modules/
cp <rc3-bundle>.tar.gz bundles/dsh-nodemodules-0.2.2-rc.3+ios1.tar.gz
sh bootstrap.sh                       # 取 node-v22.12.0-iphoneos-arm64
sh one-package/build-one-package.sh \
    bundles/dsh-nodemodules-0.2.2-rc.3+ios1.tar.gz \
    app-bundle/payload \
    dist/dev.airdevs.dsh_0.2.2-rc.3+ios18_iphoneos-arm64.deb
```

`bundles/*.tar.gz` 与 `dist/*.deb` 都在 `.gitignore` 里（超过 GitHub 单文件
100MB 硬限或体积过大），与稳定包一样靠 Release 附件分发。若本机没有
node 二进制，可用 `NODE_IOS_BIN=/path/to/node` 指定；缺失时脚本会直接
中止，绝不产出「装得上但起不来」的残包。

rc.3 上游 `client.js` 锚点与 +ios15 补丁不一致，`apply_plugin_install_patch.cjs`
会 0/1 命中。若需完整恢复 Web UI 手动安装对话框的转化钩子，用
`DSH_RC3_CLIENT=/path/to/verified-client.js` 指定已验证成品，构建脚本会调用
`patch-rc3-client-transform.sh` 替换。未指定时主加载链不受影响。

## 核验

```sh
sh one-package/verify-one-package.sh \
    dist/dev.airdevs.dsh_0.2.2-rc.3+ios18_iphoneos-arm64.deb \
    bundles/dsh-nodemodules-0.2.2-rc.3+ios1.tar.gz \
    app-bundle/payload
sh app-bundle/verify-no-data-touch.sh
sh app-bundle/verify-app.sh          # 独立 App 小包（77 项）
```

`verify-one-package.sh` 最关键的一段是把 Web Clip 里那条**静态 URL** 直接
喂给 deb 内真实 rc.3 的 `BrowserAuth.authorizeIndex`，验证
`无 token → 401`、`静态 URL → 303 + Set-Cookie`、`带 cookie → 放行`、
`/connect → 302 + Set-Cookie`。这才真正证明「点桌面图标就能加载插件 /
工作区 / 对话」，而不只是文件都在。
