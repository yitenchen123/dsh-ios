# 最后阶段评估：是否存在「和 Node 22.12.0 一样 100% 能用、又适用于最新版 DSH」的 Node

> **⚠️ 2026-11-14 状态更正（先读这段，正文是历史评估，保留原貌）**
>
> | 判据 | 本文写作时 | 现在 |
> | --- | --- | --- |
> | **B：存在 ≥24.9.0 的 iOS arm64 `node` 可执行文件** | ❌ 没有 | ✅ **有**：本仓库 GitHub Actions run `43532556241`（`success`）编出 `v24.19.0`，artifact `14095226518` / Release `node24-exp`，SHA `8bebb2a2…`，`Mach-O 64-bit arm64`、JIT entitlements 已签 |
> | **A：和 22.12.0 一样在 A11 / iOS 16.7.15 上 100% 真机验证** | ❌ | ❌ **仍未满足**：24.19.0 编译成功 ≠ 真机跑通，JIT / W^X / llhttp WASM 零验证 |
>
> 所以本文**最终结论仍然成立**（不把未验证的 Node 设为默认稳定底座），
> 但理由变了：从「编不出来」变成「编出来了，但没在 A11 上验证」。
> 与本文并行地，rc.3 全屏单包已改用该成品作为**并列实验档 `+ios24`**，
> 稳定 `+ios15` 未动。详见 `one-package/README.md` 与根 README「最新修复」章。
>
> **另需更正正文的一处自相矛盾**：第 7 节把 `engines.node >= 24.9.0`
> 称作「advisory 而非硬阻断」，但第 2 节（本文第 27 行）已正确指出
> 入口 `bin.js` 依赖 `import.meta.main`、Node 24.0 都不够。对 **rc.3**
> 而言这是**硬门槛**：Node 22 上 `dsh web` 起不来。rc.1 之所以能靠补丁
> 在 22.12.0 上跑通，是因为 +ios15 补丁链补了 `import.meta.main` shim；
> 该 shim 未覆盖 rc.3，故不可外推。本文其余判据（条件 A、门槛清单）
> 继续有效。

> 触发条件（用户原话）：「如果版本升不了就后面再说，就放到最后，看看有没有新的合适的 NODE 适合的版本。和目前能用的一样。完全百分百能用的，适用于最新版本 DSH 的。」
>
> 本文是**主线全部完成后的最后阶段评估**。结论先行：**当前不存在「原生适配最新版 DSH、又和 22.12.0 一样 100% 能用」的 iOS arm64 Node 二进制**，因此默认底座维持 `0.2.1-rc.5 + Node 22.12.0 + +ios15`。下面给出判据、证据与"未来什么条件下才升"的门槛。
>
> **+ios16 更新（后续实证）**：从 npm 取官方 `0.2.2-rc.1` 原始 tarball 逐文件核对后确认，其四处 Node 22.12 兼容补丁锚点与 `0.2.1-rc.5` **逐字一致**，`engines.node >= 24.9.0` 是 advisory 而非硬阻断。于是用同一套补丁 + 同一个已验证的 Node 22.12.0，做出了经 `verify-022.sh` **31 项 0 失败**（含真 boot、web 监听、会话创建与恢复）的**可选升级包** `dev.airdevs.dsh_0.2.2-rc.1+ios16_iphoneos-arm64.deb`。这不改变「Node 24.9 的 iOS 可执行文件不存在」的事实，但满足了用户「最新版 DSH 能用」的实质目标。详见第 6 节。

---

## 1. 用户设定的两个硬条件，必须同时满足

| 条件 | 含义 | 为什么不能让步 |
|---|---|---|
| **A. 和目前能用的一样「完全百分百能用」** | 在 iPhone X / A11 (arm64，非 arm64e) / iOS 16.7.15 / Dopamine 3.0 rootless / `/var/jb` 上，带 `dynamic-codesigning` entitlement、能跑通 V8 JIT/WASM 链路、能真 boot 到模型层、web 真监听 | 前面 15 轮修复全部围绕这个二进制的实测行为；换任何一个未在此环境 100% 验证的 Node，等于把已解决的问题全部重新打开（历史上 `bus error` / SIGBUS / `pnpm 127` / `node:sqlite` 缺失都由此而来） |
| **B. 适用于「最新版本 DSH」** | 原生满足最新版 DSH 的 `engines.node`，而不是靠兼容补丁勉强绕过 | 用户明确说「适用于最新版本 DSH 的」；打补丁跑通属于"能用但非原生适配"，不能算满足条件 |

两个条件是 **AND**。只满足其一不算。

---

## 2. 事实核查（2026-11-10）

### 2.1 最新版 DSH 是什么、要求什么

- npm 上 `@deepseek-ai/dsh` 的 `latest` 与 `next` 当前都指向 **`0.2.2-rc.1`**，仍是**开发者预览 / release candidate**，不是正式稳定版（官方 README 自述 "developer preview"、迭代快、会有破坏性变更）。[^1][^2]
- `0.2.2-rc.1` 的 `engines.node` 为 **`>=24.9.0`**；且这不只是声明：入口依赖 `import.meta.main`，**Node 24.0 都不够**（24.0 缺该 API），项目决策记录明确要求 Node 22 用户升级、24.0 也不行。[^3]
- 也就是说，"原生适配最新版 DSH" 的下限是 **Node 24.9.0 的 iOS arm64 越狱 rootless 可执行文件**——注意是可在终端直接跑的 `node` 二进制，不是嵌入用的静态库。
- 生态侧已同步收紧：例如 `dsh-tool-manager` 明确写「要求 DeepSeek Harness 0.2.2-rc.1 或更新 … DSH 0.2.2 起运行时最低要求 Node.js 24.9，升级 DSH 前请先升级 Node.js」，并提示从 0.2.1 升 0.2.2 必须移除 `tools.mode` 配置（保留会导致启动失败）。[^4] 这进一步说明"只升 DSH 不升 Node"不是一个被支持的组合。

### 2.2 iOS arm64 上现成的 Node 有哪些、能不能满足条件 B

| 候选 | 是什么 | 满足条件 B（≥24.9.0 可执行文件） | 满足条件 A（A11/iOS16.7.15 100% 实测） | 判定 |
|---|---|---|---|---|
| **本包内置 `Node 22.12.0`（iphoneos-arm64）** | 带完整 JIT entitlement、A11 真机唯一 100% 跑通的二进制；本项目 15 轮修复的底座 | ❌ 22 < 24.9 | ✅ 唯一已验证 | **当前唯一可用，但不适配新版 DSH** |
| **`openclaw-ios` 交叉编译的 Node 22（full JIT）** | 首个公开的"Node 22 → iphoneos-arm64 全 JIT"交叉编译，解决 V8 用 `mprotect` W^X 在无 APRR 芯片上的 JIT、缺 `sys/random.h`、keychain 守卫等；打包成 rootless `.deb`、ldid 签 `dynamic-codesigning` | ❌ 仍是 Node 22（该项目自身需求是 ≥22.19），不是 24.9 | ⚠️ 只对 **iPhone 6s Plus / A9 / iOS 15.8.5** 实测；README 明确写"其它设备/系统 probably work, but **untested**" | **不能算"完全百分百能用"**：芯片(A9→A11)、iOS(15.8.5→16.7.15)全不同，且版本不够 |
| **`puerts/backend-nodejs` 的 `ios.sh`** | 把 Node 源码交叉编译成 iOS arm64 **静态库**（`libnode.a` + V8 库），供 App 嵌入 | ❌ 产物是静态库不是 `node` 可执行文件；且为通用脚本，非 24.9 的现成二进制 | ❌ 无 A11 真机验证 | 不适用 |
| **V8 iOS 交叉编译（`v8_monolith`）** | 官方 `target_os=['ios']` 编译静态库；iOS 侧文档明确要求 **`jitless`**、关掉 Sparkplug/Maglev、正则走解释器，因为 iOS 禁止运行时分配可执行内存 | ❌ 只是 V8 库；且 `jitless` 与 dsh 需要的 WASM/llhttp 链路方向相反 | ❌ | 不适用 |
| **Procursus / Dopamine 自带 bootstrap** | rootless 引导与工具链（`iphoneos-arm64` deb 架构），不是 Node 运行时 | ❌ 不提供 Node 24.9 | — | 不适用 |
| **Node 24.9.0 官方 iOS 二进制** | Node 官方不发布 iOS 可执行文件 | — | — | **不存在** |

补充一个容易误判的点：Dopamine / Procursus 的 `iphoneos-arm64` 只是 **deb 打包架构名**（rootless 布局 `/var/jb`），不代表"有 arm64 的 Node 24 可用"。[^5]

### 2.3 已经做过的"打补丁在 22.12.0 上跑 0.2.2-rc.1"实测（为何仍不算）

此前已在 `/tmp/dsh-022-full` 全量依赖树上做过：打兼容补丁（`import.meta.main` shim / zstd / TS 剥离）+ addon shim 后，用 Node 22.12.0 实测通过：

- `--version` ✅
- `web --dump-config` ✅
- `headless` 真 boot 到模型层 401 ✅
- `web --no-open` 真监听 ✅

**但这只证明"能跑"，不满足条件 B**（不是原生 ≥24.9.0，是靠 shim 绕过 `engines` 与 `import.meta.main`），也不满足用户对"适用于最新版本 DSH"的语义。且 `engines` 在 npm 默认是 advisory（不设 `engine-strict` 只会 warn），"装上了不报错"不等于"运行时不会踩到 24 才有的 API"——官方排错资料明确指出 unsupported Node 上"安装看起来成功，失败迟到运行时才出现"。[^3] 因此不能拿它当 100% 方案。

### 2.4 升级本身的代价（即使假设能升）

1. 已装插件的 `runtimeVersion` 版本豁免失效 —— 用户设备上已装的 `dsh-qqbot` / `dsh-im` 等生态插件要重新验证甚至重装。
2. `0.2.2-rc.1` 仍是 rc / 开发者预览，官方自述会有破坏性变更（例如 `tools.mode` 配置被删），升级会引入新的不稳定面。
3. 需重传 **125MB** 整包（用户此前明确说过传输受限，才有了 4.9MB 热修方案）。
4. 新版生态插件大量要求 Node ≥24.9，等于逼着换 Node；而换 Node 又回到 A11 的 JIT/W^X/`bus error` 老问题。

---

## 3. 结论

> **找不到「和当前 Node 22.12.0 一样 100% 能用、又原生适用于最新版 DSH」的 Node 二进制。** 公开可获得的 iOS arm64 Node，最高是**经过真机验证的 Node 22.x**（且验证机型是 A9/iOS 15.8.5，不是本项目 A11/iOS 16.7.15）；Node 24.9.0 的 iOS 可执行文件**不存在**，需要自行交叉编译并解决 A11 的 V8 JIT W^X / ldid entitlement / llhttp WASM SIGBUS 等一整套问题——那属于"未验证的新二进制"，与条件 A 直接冲突。

因此按用户的预设（「如果版本升不了就后面再说」）：

- **维持 `dsh 0.2.1-rc.5` + 内置 `Node 22.12.0` + `+ios15` 不变**，不升级、不换二进制；
- `+ios15` 的全部修复（手动安装全方式 / 插件市场加载 / 仅手动安装生效的生态插件转化 / 浏览器垫片 / 可复现构建）都落在这个 100% 可用的底座上；
- 版本升级**搁置**，不作为本轮交付动作。

---

## 4. 未来什么条件下才升级（明确的门槛）

只有同时满足下列全部条件，才建议重新评估升级；否则一律维持现底座：

1. 出现 **Node ≥24.9.0 的 iphoneos-arm64 可执行文件**（非静态库），且带 `dynamic-codesigning` entitlement，能在 rootless `/var/jb` 直接运行；
2. 该二进制在 **iPhone X / A11 / iOS 16.7.15 / Dopamine 3.0** 上实测通过本项目 `dsh-doctor` 全 26 项（含 5 档 V8/WASM 冒烟、`dsh --version`、headless 真 boot、web 真监听、`node:sqlite`、会话写入）；
3. 通过本仓库 `sh verify-deb.sh`（57 项交付物断言）与 `sh verify-repro.sh`（字节级可复现）；
4. 用户设备上已装的每一个生态插件，在新 DSH 版本下重新验证 `runtimeVersion` 兼容，或确认可接受重装；
5. 用户确认接受重传整包（125MB）与 rc 版本的不稳定风险。

在此之前，`0.2.1-rc.5 / Node 22.12.0 / +ios15` 是**唯一满足「100% 能用」的组合**。

---

## 5. 参考来源

[^1]: SSD Nodes, *Fix DeepSeek Harness install and version errors* — npm `latest`/`next` 指向 0.2.2-rc.1、全部为 prerelease、官方 README 称 developer preview：https://www.ssdnodes.com/learn/dsh-install-and-version-errors
[^2]: CSDN, *DeepSeek Harness 完整排错指南* — 2026-11-10 核验 npm `latest` 与 `next` 均为 0.2.2-rc.1、`engines.node >=24.9.0`、仍标"开发者预览"：https://blog.csdn.net/aidoudoulong/article/details/170419583
[^3]: 华为云社区, *装 DeepSeek Harness：三个会装错的地方* — `@deepseek-ai/dsh` 包元数据、`engines.node >=24.9.0`、Node 18/20/22 均不满足：https://bbs.huaweicloud.cn/blogs/519287 （`import.meta.main` / 24.0 不够的决策记录见 [^1]）
[^4]: DSH Plugin Hub, *Tool Manager* — 要求 DSH 0.2.2-rc.1+ / Node 24.9，以及从 0.2.1 升级需移除 `tools.mode`：https://dshpluginhub.ai/en/plugins/dsh-tool-manager
[^5]: The Apple Wiki, *Rootless* — `iphoneos-arm64` 是 rootless deb 架构名、`/var/jb` 布局：https://theapplewiki.com/wiki/Rootless
[^6]: `j0shua-SYSON/openclaw-ios` — 首个 Node 22 → iphoneos-arm64 全 JIT 交叉编译，参考设备 iPhone 6s Plus / A9 / iOS 15.8.5，其它设备 untested：https://github.com/j0shua-SYSON/openclaw-ios
[^7]: `puerts/backend-nodejs` iOS 构建系统 — 产物为 iOS arm64 静态库：https://deepwiki.com/puerts/backend-nodejs/3.1-ios-build-system
[^8]: V8 官方文档 *Cross-compile iOS* 与 iOS jitless 约束：https://v8.dev.org.tw/docs/cross-compile-ios

---

## 6. `+ios16` 更新：`0.2.2-rc.1` 可选升级包已落地（2026-11-11）

第 2~3 节的判据**仍然成立**：Node 24.9.0 的 iOS arm64 可执行文件不存在，公开可得的 iOS Node 最高只到经真机验证的 22.x。但「最新版 DSH 能不能在这台 A11 上用」这个问题，后续用实证给出了更完整的答案。

### 6.1 决定性实证：补丁锚点逐字一致

从 npm 下载 `0.2.2-rc.1` 的 7 个官方包 tarball，与 `0.2.1-rc.5` 的补丁目标逐行比对：

| 补丁 | 官方 `0.2.2-rc.1` 原文 | 与 `0.2.1-rc.5` |
|---|---|---|
| `dsh/lib/bin.js` | `if (import.meta.main) await runCli();` | 完全相同 |
| `dsh-session-persistence-jsonl/lib/index.js` | `import { constants, createZstdCompress, ... } from "node:zlib";` | 完全相同 |
| 同上 | `const DEFAULT_COMPRESSION = "zstd";` | 完全相同 |
| `dsh-ptc-runtime-node/lib/index.js` | `import { stripTypeScriptTypes } from "node:module";` | 完全相同 |

也就是说 `0.2.2-rc.1` 在 Node 22.12.0 上的缺口，和 `0.2.1-rc.5` **是同一个缺口**。`+ios15` 的全套补丁（compat / pnpm 绝对路径直连 / 手动安装 git 预检短路 / 插件市场主线程解析 / 前端注入）在**官方原始 0.2.2 树**上从零逐项精确命中；`+ios14`、`+ios15`、前端注入三套补丁重跑幂等，`apply_compat_patches.py` 也已补上幂等标记判定。

### 6.2 实测结果（`verify-022.sh`，与真机同版本 Node 22.12.0 + 零 JIT 档）

```
=== 汇总: OK=31 FAIL=0 ===
✔ dsh 0.2.2-rc.1 + dsh-iOS 全套补丁树核验全部通过
```

覆盖：`--version` → `0.2.2-rc.1`；`web --dump-config` 1243 行；`headless --help`；`web --no-open` 真监听且进程存活；`headless "ping"` 到模型层（仅 `MISSING_CREDENTIAL`，无 SIGBUS/段错误）；`session.v4.jsonl` 创建且非空；`--session-id` 恢复到模型层、无 `zstd/corrupt`；`cordis.patch.yml` 顶层均为数组；AI 帮你装 / CLI 两条路径 0 个转化钩子泄漏；10 个补丁文件 `node --check` 通过。

另有：`verify-deb.sh` 对 0.2.1 与 0.2.2 两个交付 deb 各 **57/0**；`verify-repro.sh` 在 `DSH_VER=0.2.2-rc.1` 下两次完整构建 SHA 完全一致（`f5548928…`）；0.2.1 稳定底座 deb 与热修 SHA 保持不变（`67d54667…` / `4ff34b64…`）。

### 6.3 交付方式与边界

```sh
DSH_VER=0.2.2-rc.1 sh bootstrap.sh   # 下载 0.2.2 官方原始依赖树 bundle（SHA 硬校验）
DSH_VER=0.2.2-rc.1 sh build.sh       # 产出 dev.airdevs.dsh_0.2.2-rc.1+ios16_iphoneos-arm64.deb
sh verify-022.sh .build/stage/var/jb/usr/lib/dsh /path/to/node-22.12.0
```

- **默认不升级**：稳定底座仍是唯一在 A11 真机 100% 验证过的组合，升级包是可选的。
- **不换 Node**：仍是包内 22.12.0 二进制（大小 / SHA / Mach-O 头三重校验不变），没有引入任何未经真机验证的新二进制。
- **仍然不是「原生适配 Node ≥24.9」**：靠的是与 0.2.1 同构的兼容补丁；`engines` 声明为 advisory，Host 侧 `dsh/lib` 未使用 Node 24 专属 API（全树 `import.meta.main` 只在 `dsh-subprocess-local/lib/runner.js` 出现 1 处）。
- **已知代价**：已装生态插件的 `runtimeVersion` 豁免需复核；`0.2.2-rc.1` 仍是开发者预览；需重传整包；从 0.2.1 升级时若保留旧 `tools.mode` 配置需检查。
- **沙箱边界**：所有验证在 x86 Linux 上按 iOS 目录布局完成，无法替代 A11 真机上的 V8/JIT entitlement 与 Web UI 实机确认。

### 6.4 第 4 节「升级门槛」的修订

原门槛 1（必须有 Node ≥24.9 的 iOS 可执行文件）针对的是「**原生适配**升级」。若用户接受「同一已验证 Node + 官方最新 DSH + 实测通过的兼容补丁」，则门槛改为：

1. 通过 `sh verify-022.sh`（31 项，含真 boot 与会话创建/恢复）；
2. 通过 `sh verify-deb.sh <0.2.2 deb>`（57 项）与 `DSH_VER=0.2.2-rc.1 sh verify-repro.sh`（字节级可复现）；
3. 用户设备上每个已装生态插件重新验证 `runtimeVersion`；
4. 用户确认接受重传整包与 rc 版本风险；
5. 真机跑 `dsh-doctor` 全量检查后再作为日常底座。

前三条已在本仓库完成，后两条属于设备侧动作。

---

## 7. 2026-11-14 补充：Node 24.19.0 在 A11 上的真机证据（修正第 2、3 节边界）

第 2 节表格里「JIT / W^X / llhttp WASM 零验证」的状态现在**有了真机证据，
而且是否定的**。用户装上 rc.3 全屏单包（内置 GitHub Actions 编出的
v24.19.0，`Mach-O arm64` + JIT entitlements 已签）后回传的截图显示：

| 实测 | 结论 |
| --- | --- |
| `dsh-doctor` 档位探测：`native / single / balanced / safe` 全 `rc=138`（SIGBUS），`--expose-internals` 探针也 `Bus error: 10` | **Node 24 的原生 JIT 在 iPhone X / A11 / iOS 16.7.x / Dopamine rootless 上不可用**，`dynamic-codesigning` 已签也不改变 W^X 结果 |
| `nowasm` 档 `rc=9`（`bad option`） | `tier.sh` / `pnpm` / 插件子进程注入的 `--no-expose-wasm` 是 Node 22 时代的 V8 flag，**Node 24 / V8 13.x 已删除**；唯一能活的零 JIT 档被这一个废参数挡死 |
| `node -v` 正常、`node --version` 正常，一执行 JS 就 SIGBUS | 与 22.12.0 时代的现象一致：轻量命令不分配可执行页，真 boot 才触发 |

因此「条件 A（和 22.12.0 一样 100% 真机验证）」对 Node 24.19.0 **仍然不成立**，
且不能直接指望 JIT entitlement 解决。**唯一可行的运行形态是 `--jitless`
零 JIT 档 + `fetch-shim.cjs`**（V8 完全不生成可执行代码；用 `node:http`
原生 llhttp 顶替内置 undici 的 WASM 解析器）。这恰恰是稳定底座 +ios3 起
就在用的兜底档 —— 只是首版 `+ios24` 把 +ios15 的运行时脚本原样带进来时，
忘了去掉 Node 24 已删除的 flag。

本仓库据此产出 `+ios24.1`：去掉所有生效行的 `--no-expose-wasm`，新增
`node-safe` 让全部短命 node 调用统一零 JIT，`dsh-doctor` 改为 rc.3 / Node 24
版本感知，并强制升级时换掉旧 daemon。Linux x64 的 Node 24.19.0 上已实跑
`--jitless` 下的 `web` 监听、`smoke.js`、`pnpm --version`、`node:sqlite`、
前端垫片 `--check` 与 `401 → 303 + Cookie → 200` 全链路（JS 层证据）。

## 第三轮真机回归（2026-11-14）：工作区/对话加载不出是数据层问题，与 JIT 无关

`+ios24.1` 装好后 doctor 全过（`OK=28 WARN=1 FAIL=0`），零 JIT 档可用，
但全屏 UI 里工作区/对话全空、目录选择器报 `directoryPickerController is
unavailable`。真机 doctor 里夹着 `session-xxx.jsonl uses .jsonl but configured
for compression "zstd"`。A/B 实跑（Linux Node 24，含明文 `.jsonl` 的
DSH_HOME）定位两个数据层根因，均与 Node 版本 / 鉴权 / JIT 无关：

1. **会话压缩格式不匹配（主因）**：`+ios24` 因「Node 24 原生支持 zstd」整包
   跳过 `apply_compat_patches.py`，`DEFAULT_COMPRESSION` 留在 `zstd`；但那条
   `zstd→none` 本质是兼容用户从 +ios15/+ios18 带来的明文 `.jsonl` 会话数据，
   不是补 Node 22 缺的 API。`checkRootEncoding()` 全局闸门一抛错，host 装配
   fatal，workspace/session/directoryPicker 全部 controller `pending`。
   修法：`DEFAULT_COMPRESSION` 改回 `none`（所有 iOS 档一致），doctor 严格断言。
2. **iOS 目录选择器选错后端**：`process.platform==="darwin"` 让
   `directory-picker-auto` 选 native（`osascript`，iOS 无），而 Web Clip 前端
   需要 browse。修法：iOS/darwin 强制 `browse`（纯 `node:fs/promises`）。

`+ios24.2` 由 `make_ios_data_compat.py` 只改单包 stage 依赖树副本完成修复，
共享 `shims/` / `payload/` 不动，稳定底座 SHA 未变；`dist/fix-ios24.sh`
step 0 提供设备端就地热修。单包 97 项 0 失败、两次构建字节一致、
APP 包 77/0、doctor 27 OK/0 FAIL；未修包 web 日志 `4 entries did not
activate` + 一堆 pending，修后同一场景零挂起。

**边界不变**：零 JIT 档在 A11 真机上的最终表现、SpringBoard 对 Web Clip
缓存刷新时机仍需用户装包 / 跑 `dist/fix-ios24.sh` 后回传截图确认；本仓库
**不承诺 A11 100% 成功**。唯一 100% 真机验证过的组合仍是 `+ios15`
（rc.5 + Node 22.12.0）。
