# dsh for iPhone X / iOS 16.7.15 / Dopamine 3.0 (rootless)

**做成 rootless 越狱包（.deb），装完在终端敲 `dsh` 直接启动。** 不走 Air2，不需要 WKWebView，不需要 iSH 模拟器，不需要 TrollStore，不装系统 node。

> 目标机：iPhone X (iPhone10,3), A11 **arm64**, iOS **16.7.15**, Dopamine 3.0 rootless (`/var/jb`)。
> 当前版本 **`+ios15`**：修好「点击插件 → 安装插件」里所有手动方式（AI 帮你装本来就成功）、修好「插件市场加载失败一堆报错」、给生态插件加仅手动安装生效的转化逻辑、并让 GitHub 仓库可 1:1 字节级复现构建。dsh 版本保持 **0.2.1-rc.5**、内置 node 保持 **22.12.0**（A11 唯一 100% 能跑的组合）。最后阶段的「新 Node / 最新版 DSH」评估**已完成**：查无「和 22.12.0 一样 100% 能用、又原生适配最新版 DSH」的 iOS arm64 Node，维持现底座不升级，详见 [`docs/DSH-NODE-UPGRADE-EVALUATION.md`](docs/DSH-NODE-UPGRADE-EVALUATION.md)。此前 14 轮修复全部保留并回归。

---

## 最新修复 · `+ios15`：手动安装全方式 / 插件市场 / 生态插件转化 / 可复现构建

这一版把用户反馈的四件事一次性收口，**不升级 dsh 版本、不换 node 二进制**（避免已装插件的版本豁免失效、也免重传额外部件）。

### 1. 修好「点击插件 → 安装插件」里【所有手动安装方式】

真机现象：手动装 npm 包名 / GitHub 仓库 / tarball / 本地路径全失败，其中 GitHub 仓库「不再是 127、有别的新报错」；而**「AI 帮你装」成功**。

根因（0.2.1-rc.5 真机逐行核对）：Web UI 手动安装与 AI 装最终都走 service 产物 `dsh-plugin-manager/lib/index.js` 的 `installBundle()`，但 `installBundle` 在真正下载前会跑 `checkGithubConnection()`，对 git/GitHub spec **裸调 `execa("git", ["ls-remote", ...])`**。iOS rootless 没有 git 二进制 → ENOENT 被判成 `network` → 直接 `throw` 中止安装。AI 装会把仓库地址智能转成 npm 包名/tarball（`spec.kind != "git"`），不触发这个预检，所以成功。这个预检只是「提前给个更好看的报错」，真正的下载由包内纯 JS pnpm 走 codeload HTTP tarball，根本不需要本地 git。

修法：`apply_plugin_install_patch.cjs` 在 iOS 上短路这个**可选**预检（保留环境变量 `DSH_IOS_KEEP_GIT_PROBE=1` 给装了 git 的环境）。不改变安装结果，只去掉那条必然失败的提前探测。

### 2. 修好「插件市场点进去直接加载失败、一堆报错」

根因两条：
- `fetchIndex()` 用 `fetch(url, {redirect:"error"})`，而目录站 / CDN / `http→https` 必然跳转 → fetch-shim 直接抛 `Request redirected`；
- `parseIndexInWorker()` 用 `new Worker(entry, {execArgv: []})` 起子线程解析索引。在 A11 的 nowasm 零 JIT 主进程下，这个新 Worker 会**重新启用 V8 JIT**，按线程生效的 `pthread_jit_write_protect_np` 让 V8 写可执行页即 **SIGBUS**（x86 Linux 复现不了，真机 A11 必崩）。

修法：`redirect:"error"` → `follow`；索引解析从子 Worker 改到**主线程**，复用官方 `worker.cjs` 里逐字同源的 `parseIndexBody`（派生出 `worker-parse.cjs`）。彻底不 `new Worker`，从原理上杜绝 SIGBUS，返回值结构与官方完全一致。

### 3. 生态插件转化逻辑（★ 只在手动安装生效，AI 帮你装绝不应用）

`shims/dsh-ios-manual-install-transform.js` 定义 `window.__dshIosTransformSpec(spec)`，由 `apply_plugin_install_patch.cjs` **只**注入到 Web UI 手动安装对话框专属的 `dsh-client-ui-plugin-manager/lib/client.js` 的 `installBundle(spec)` 提交点之前。

- GitHub 仓库地址 / `git@` / `git+https` → pnpm hosted-git 简写 `github:owner/repo`（pnpm 走 codeload HTTP，无需 git）。含 `/tree/<branch>` 的分支名支持斜杠，例如 `.../tree/release/v2` → `github:foo/bar#release/v2`；
- 已知 iOS/浏览器不兼容插件（原生 `.node`、Electron、Playwright、桌面专属、要求 Node≥24）→ 前端明确提示 + 替代建议，**不硬拦**；
- npm 包名 / tarball / 本地路径 / 已合规的 `github:` 简写 → 原样放行。

交付前有 32 条转化用例回归（含带斜杠分支、尾斜杠、`#tag` 优先、`git+ssh`、tarball 原样放行、不兼容只提示不拦截），见 `sh verify-deb.sh` 的 G 段。

**硬约束**：AI 帮你装走 `tools.js`（agent tool）、命令行走 `types/operations.js`，都不经过这份前端 client.js。构建期强校验 `grep -c __dshIosTransformSpec` 在这两个文件里必须为 **0**（doctor 第 25 项也会真查）。同时扩展 Safari 16.6 垫片，补齐生态插件可能用到的 `Promise.try` / `RegExp.escape` / `toSorted` / `Uint8Array` base64-hex / `Float16Array` 等（特性检测+原生优先，新设备零影响）。全量生态清单见 [`docs/DSH-ECOSYSTEM-PLUGINS.md`](docs/DSH-ECOSYSTEM-PLUGINS.md)。

### 4. GitHub 仓库 1:1 字节级可复现构建

用户要求「不管多大 GitHub 仓库，别人写构建脚本都构建出来，要和你本地一样」。仓库 `.gitignore` 排除了三个超 GitHub 单文件限制的大件（node 二进制 101MB、依赖树 bundle 88MB、deb 125MB），以前 clone 后 `build.sh` 第一步就失败。现在：

```sh
git clone https://github.com/yitenchen123/dsh-ios && cd dsh-ios
sh bootstrap.sh        # 从 Releases 下载 2 个大文件，逐个 SHA-256 硬校验放回 bundles/
sh build.sh            # 缺大文件会自动调用 bootstrap；全程离线，字节级可复现
sh verify-repro.sh     # 连跑两次 build 并比对 SHA，证明两次产物完全一致
sh verify-deb.sh       # 从交付 deb 自解包做 57 项独立断言（无需 iOS 真机）
```

可复现的关键：`build.sh` 把所有 stage 文件 mtime/属主固定到 `SOURCE_DATE_EPOCH`（默认 1700000000）、`dpkg-deb -Zgzip -z9`；`bundles/pnpm` 与全部补丁/热修/前端注入都随 git 跟踪且确定性生成（tar 成员排序、gzip mtime=0）。`fix-ios15.sh` 内嵌文件与 deb 内对应文件**逐字节比对**通过才允许出包。

**实测结果**（2026-11-10）：`verify-repro.sh` 两次完整构建 SHA-256 完全一致 = `67d54667ce3ebc7734151ec621f6ec118a9d760e36d1c48922eb644d79528d70`；`verify-deb.sh` 从该 deb 自解包跑 **57 项断言全部通过、0 失败**（git 预检短路 / 市场主线程解析 / redirect follow / 仅手动安装注入且 AI·CLI 零泄漏 / 前端注入顺序 / 语法 / 32 条转化用例 / 历史回归 / 热修逐字节一致）。此外用 `+ios14` deb 模拟「已装旧版设备」跑 `fix-ios15.sh install` 就地升级成功，`--status` 全绿、`--restore` 可回滚，升级后的 21 个热修覆盖文件与全新 `+ios15` deb **逐字节一致**（唯一不覆盖的是热修脚本自身，符合设计）。`dsh-doctor` 全 26 项中新增的 23~26 项全部 `[ OK ]`。

### 5. 装到手机（免重传 125MB deb）

```sh
# 已装 +ios14 的设备：传 4.9MB 热修脚本就地升级
scp dist/fix-ios15.sh mobile@<iphone-ip>:/var/mobile/
ssh mobile@<iphone-ip> 'cd /var/mobile && sudo sh fix-ios15.sh && dsh-doctor'
sh fix-ios15.sh --status     # 只看状态
sh fix-ios15.sh --restore    # 回滚启动文件（用户数据不动）
```

`dsh-doctor` 新增 **23~26 项**：git 预检短路 / 插件市场主线程解析 / 手动转化钩子（并核验不泄漏到 AI 路径）/ 扩展垫片语法，缺任一项都会尝试就地自愈再复检。

> 关于「更新 DSH 到最新版」（**最后阶段评估已完成**）：官方 `0.2.2-rc.1` 的 `engines.node >= 24.9.0`（且依赖 `import.meta.main`，Node 24.0 都不够），而 A11 上 100% 能用的只有包内 22.12.0。打兼容补丁后 0.2.2-rc.1 在 22.12.0 上 `--version` / `web` 真监听 / `headless` 真 boot 全通，但那属于"靠 shim 绕过"而非原生适配，不满足用户的硬条件，且会让已装插件 `runtimeVersion` 豁免失效、需重传整包。公开可得的 iOS arm64 Node 最高只到**经真机验证的 Node 22.x**（且验证机型是 A9 / iOS 15.8.5，非本项目 A11 / iOS 16.7.15）；**Node 24.9.0 的 iOS 可执行文件不存在**。结论：**维持 `0.2.1-rc.5 + Node 22.12.0 + +ios15` 不升级**。完整判据、候选对照表与"未来什么条件下才升"的 5 条门槛见 [`docs/DSH-NODE-UPGRADE-EVALUATION.md`](docs/DSH-NODE-UPGRADE-EVALUATION.md)。

---

## 最新修复 · `+ios12`：干净底座 + 修好安装插件 + 根治「无法创建新对话」

这一版把用户反馈的问题一次性收口，并**回退整条「预装插件」路线**。

### 1. 不再默认自带两个插件，改为修好官方安装命令

`+ios7` 起把 QQ Bot、`+ios9` 起把 dsh-im 随包固化，和用户（或别的 AI）用
pnpm 自装的那份形成**两份副本**，接连引发 root 属主 patch、`.pnpm` 残留
副本、`sessions/` 目录树 root 属主等一连串故障。本版起：

- 包内**完全不含** `@xmanrui/dsh-im` / `@tencent-connect/dsh-qqbot`；
- wrapper **不再**写 `cordis.patch.yml`、不建软链、不改属主；
- 内置 **pnpm 10.28.2 纯 JS 发行版**（19MB / 0 个 `.node`），提供
  `/var/jb/usr/bin/pnpm` 用包内 node 直接跑。

`dsh` 的 `plugin` 子命令本来就把参数原样转发给 pnpm（`bin.js:116`），默认
命令名就是字符串 `'pnpm'`（`dsh-plugin-manager/types/index.js:217`）——
所以**不用改 dsh 一行源码**，PATH 里有这个包装脚本就行。真机原本没有
pnpm/npm/corepack/git，才必然退出码 127。

```sh
dsh plugin --profile web add <包名>   # 现在能真正安装
dsh-compat                           # 装完 dsh-im 跑一次，补 A11 零 JIT 补丁
```

store/cache 全部落到 `$DSH_HOME`（`PNPM_HOME` / `XDG_*` / `npm_config_*`），
不写 root 属主目录。`dsh-compat` 会扫描设备上**所有** dsh-im 副本逐份补
`+ios9` 的 libsignal WASM 补丁，幂等、不写配置、不建软链。

### 2. 根治「无法创建新对话」(EACCES) —— 上轮点名的 bug

```
新建会话失败: gateway/internal: failed to create session:
Error: EACCES: permission denied, open
'/var/jb/var/mobile/.dsh/sessions/--private-preboot-...-DSH--/session-xxx/session.v4.jsonl'
```

`--private-preboot-...--` 是 dsh 把**当前工作目录**编码成的会话分组名
（`projectKey(cwd)`）。整棵 `sessions/` 目录树曾被 root + `.zshenv` 包装器
建过，mobile 写不进去；gateway 建不了会话，依赖会话的插件自然「未运行」，
而纯 Cordis 的 QQ Bot（`inject: ['agents']`）绕开这条路，所以「另一个能成功
运行」。旧 doctor 只测 `$DSH_HOME` 顶层可写（postinst `chmod 777` 过），
**没测子目录** —— 又一个假绿灯。

**免 root 修法**：`dsh-home-heal.cjs` 用 `rename(2)` —— 只要求父目录可写，
不要求对目标本身有写权限，也不需要 `chown`。已用 `nobody` 身份对
`root:root` 444 文件实测通过。

| 对象 | 处理 |
|---|---|
| 单文件（`cordis.patch.yml`、`profiles/*/package.json`、`pnpm-lock.yaml` 等） | 读内容 → 同目录写临时文件 → `rename` 覆盖，新文件归当前用户；目录带 sticky 时先 unlink 再 rename |
| `sessions/` 整棵树 | rename 到 `sessions-legacy-root-<ts>` → 新建归当前用户的树 → 复制历史 `*.jsonl` 回来 |
| 旧预装痕迹 | 整块删除 `cordis.patch.yml` 里 `id: im-qqbot` / `xmanrui-dsh-im` 的 `- insert:` 块（不逐行 `grep -v`，那会把 YAML 拆坏）；只删**指向包内**的 `node_modules` 软链，用户自建的真实目录绝不碰 |

幂等、每次启动都跑（只做 stat，<10ms），报告走 stderr 不污染
`dsh --dump-config` 的 stdout。`dsh-doctor` 新增**第 20 项**：真写一次
session 文件 + 扫描所有子目录可写。

### 3. 此前全部修复保留并回归

`tier.sh` 自动选档 / `nowasm` 零 JIT / `fetch-shim` 幂等 body / Safari 16
垫片 / 会话默认压缩 `none` / `--experimental-sqlite` / 全副本零 JIT 补丁
扫描 / 第 9 项 pending 判定与失败正则 —— 全部保留。doctor 的 15/17/19/21
项重写为「干净底座 + 安装链路 + 自动补齐补丁 + 装后命令」。

**已装 `+ios11` 的设备不用重传 125MB deb**：

```sh
sh /var/jb/usr/lib/dsh/fix-ios12.sh    # --status 查状态 / --restore 回滚
dsh-doctor                            # 第 17/20 项应为 OK
```

热修以 mobile 跑时若写不进 root 属主的包目录，**第 3 步的用户数据自愈
照样生效**（脚本直接从临时目录执行），并会明确提示用 root 重跑或装新 deb
来升级 pnpm/doctor，不再静默假成功。

## 最新修复 · `+ios11`：patch 属主 + 旧 pnpm 残留副本（两个「假绿灯」）

`+ios10` 之后 doctor 已经 `WARN=0 FAIL=0`，但用户一敲 `dsh` 又是
`1 entry did not activate`。这轮的两个问题都**不是** `node:sqlite`：

```
/var/jb/usr/bin/dsh: 45: cannot create /var/jb/var/mobile/.dsh/cordis.patch.yml: Permission denied
dsh: 已挂载 QQ Bot 插件（im-qqbot）          <- 假的
dsh: warning: 1 entry did not activate
xmanrui-dsh-im (@xmanrui/dsh-im): failed to import:
TypeError: ge.lthashantitampering_new is not a function
    at new VC (.../node_modules/.pnpm/@xmanrui+dsh-im/5.10.0/node_modules/@xmanrui/dsh-im/lib/index.js:586:...)
```

| # | 根因 | 修法 |
|---|---|---|
| A | `cordis.patch.yml` 被旧版热修以 **root** 创建，mobile 用 `>>` 追加失败；旧代码 `|| true` 吞掉错误还打印「已挂载」，是假成功 | `dsh` / `dsh-doctor` / 热修统一改成**同目录写临时文件 + `mv` 原子替换**：只要目录可写就能换掉 root 属主的旧文件，新文件归当前用户；失败明确打印 `[warn]` |
| B | 设备上还有第二份 dsh-im：`.pnpm/@xmanrui+dsh-im/5.10.0/.../lib/index.js`（旧安装残留）。**dpkg 升级只覆盖自己清单里的文件，不会清理它**，ESM resolver 恰恰加载了这份没打 `+ios9` 零 JIT 补丁的副本。doctor 第 17 项只 grep 扁平那份（已打补丁），于是汇总 `FAIL=0` 却实际挂掉 | `fix-ios11.sh` 扫描设备上**所有** `@xmanrui/dsh-im/lib/index.js` 逐份补补丁（精确替换 + 变量名反查兜底）；doctor 新增**第 19 项**全盘扫描，缺任一份即 FAIL；第 9 项失败正则补上 `lthashantitampering` / `is not a function` |

**已装 `+ios10` 的设备不用重传 125MB deb**：

```sh
sh /var/jb/usr/lib/dsh/fix-ios11.sh    # 自包含，--status 查状态 / --restore 回滚
dsh-doctor                            # 第 19 项应为「全部 N 份副本均已打补丁」
```

`dist/fix-sqlite.sh` 与 `fix-ios11.sh` **字节相同**，跑任意一个都是最新修复
（避免老用户误跑旧名把启动文件刷回 `+ios10`）。两者都由
`shims/make_fix_ios11.py` 在每次构建时从 payload 重新生成。

## 最新修复 · `+ios10`：`node:sqlite` builtin 未注册（A11 真机最后一个 FAIL）

真机 `dsh-doctor` 汇总 `OK=20 WARN=1 FAIL=1`：

```
[FAIL] headless boot 撞到依赖或插件加载问题
  -> dsh: warning: 1 extraneous did not activate:
     xmanrui-dsh-im (@xmanrui/dsh-im): failed to import:
     Error [ERR_UNKNOWN_BUILTIN_MODULE]: No such built-in module: node:sqlite
```

**根因**：`@xmanrui/dsh-im 5.10.0` 的 `lib/index.js` 顶层是静态 ESM
`import { DatabaseSync as sLe } from "node:sqlite";`，静态 import 无法
try/catch。包内 Node **22.12.0** 虽然已把 SQLite 编译进二进制（`strings`
可见 `node::sqlite::DatabaseSync` / `sqlite3_open`），但仍把 `node:sqlite`
标为实验性，必须显式传 `--experimental-sqlite` 才注册这个 builtin；
**22.13+ 才默认打开** —— 构建机 Linux 是 22.13.1，所以 `+ios9` 的离线
1:1 验证全是绿灯，真机一跑就露出来。这是「构建机比目标机新」造成的漏测。

已在 Linux 上用 `node --no-experimental-sqlite` **精确复现**同一报错（连
`esm/translators:356` 堆栈都一致），并做了 A/B 对照：

| 组 | 启动参数 | `headless ping` 结果 |
|---|---|---|
| A（+ios9） | 无 sqlite flag | `1 entry did not activate` + `failed to import: ... node:sqlite` |
| B（+ios10） | `--experimental-sqlite` | 报错消失；dsh-im 成功 import，只剩 `pending (waiting for services: connection, credentials)`（等待渠道凭据，正常） |

**修法（零降级）**：`tier.sh` 集中定义 `$TIER_SQLITE_ARGS`，`dsh` /
`dsh-doctor` / `install-im.sh` / `install-qqbot.sh` / `fix-session.sh`
的所有启动行统一带 `--experimental-sqlite`（并用
`--disable-warning=ExperimentalWarning` 压掉实验性提示）。dsh-im 的
SQLite 缓存完整可用，不需要删功能、不需要降级补丁。

顺带修掉三个会让人以为「还没修好」的误报：

- 第 9 项旧逻辑把裸 `did not activate` 一律判 FAIL；修好 sqlite 后
  dsh-im 只是等待凭据的 `pending`，仍会误报。改成只看原因行
  （`failed to import` / `ERR_*` / `Cannot find module`），pending 给 INFO。
- 第 15 项 `im-qqbot 未挂载` 那条 WARN：装完 `+ios9` 直接跑 doctor 时，
  wrapper 的自动挂载要等第一次敲 `dsh` 才执行。改成幂等自愈补挂。
- 新增第 18 项：真跑一次 `require('node:sqlite')`，并核对启动链路带开关。

**已装 `+ios9` 的设备不用重传 125MB deb**：

```sh
sh /var/jb/usr/lib/dsh/fix-sqlite.sh   # 24KB 自包含，--status / --restore
dsh-doctor                            # 应为 WARN=0 FAIL=0
```

全新安装直接装 `+ios11` 的 .deb。热修包在 `+ios10` 时由 `shims/make_fix_sqlite.py`
生成，`+ios11` 起改由 `shims/make_fix_ios11.py` 在每次构建时从 payload 重新生成，
内嵌文件与 deb 字节一致。

## 最新修复 · `+ios9`：预装 `@xmanrui/dsh-im`（10 渠道 IM 机器人）

[github.com/xmanrui/dsh-im](https://github.com/xmanrui/dsh-im) 5.10.0 把**飞书 / 微信 / 企业微信 / 钉钉 / QQ / Slack / Telegram / Discord / WhatsApp / Matrix / iMessage** 接进 DSH，设置 → IM机器人 里扫码或填凭据即可。官方装法是 `dsh plugin --profile web add -w @xmanrui/dsh-im`，还要求 `Node >= 22.19` —— 在 iPhone X 上两条都走不通：前者因缺 pnpm 必然**退出码 127**，后者与本包内置的 22.12.0 冲突。

### +ios9 做了什么

| 环节 | 官方 / 手机上的结果 | `+ios9` |
|---|---|---|
| 装依赖 | `pnpm add` → 127 | 插件本体 + **114 个运行时依赖 / 1275 文件 / 22.9MB / 0 个 `.node`** 固化进 `node_modules/@xmanrui/dsh-im/` 的**私有嵌套 node_modules**，与宿主 dsh、`+ios7` QQ Bot 版本完全隔离 |
| Node 版本 | 要求 ≥22.19 | 实测 481 个 JS 文件在 **22.12.0** 全部通过语法检查、0 失败；`engines` 只是保守声明 |
| 注册 | pnpm 写 `cordis.patch.yml` | 首次敲 `dsh` 自动追加 `- insert: { id: xmanrui-dsh-im }` 到 `$DSH_HOME/cordis.patch.yml` |
| 前端入口 | 依赖 `dsh.client.inject` | 宿主 `dsh-client-modules` 原生机制；实测 `index.html` 的 client graph 含 `{"id":"@xmanrui/dsh-im","url":".../client.js"}` |

### 只有 A11 真机才会踩的坑（本次核心修复）

`+ios3` 选出的 `nowasm` 档带 `--jitless --no-expose-wasm`，而 **`--jitless` 会连带禁用 WebAssembly**（实测连 `node:vm` 都取不到）。dsh-im 把 WhatsApp/Baileys 的 libsignal WASM glue 内联进 `lib/index.js`，并在**模块顶层**执行 `var JCe = new VC` —— 无 WASM 时整包 import 直接抛 `TypeError: ge.lthashantitampering_new is not a function`，Cordis 只报「1 entry did not activate」而 web 照常监听：**网页能开，设置里却没有「IM机器人」入口、10 个渠道全废**，是最坑的假故障。

`+ios9` 在构建期给 `lib/index.js` 打两处精确补丁：顶层单例 `try/catch` 惰性化、history-sync 的 lthash 收尾加 null 保护。`native` 档走 try 成功分支，行为与官方包完全一致；补丁只在 WASM 缺失时改变路径。

> 唯一降级：零 JIT 档下 **WhatsApp 的「加密历史同步哈希」** 返回占位值（无 WASM 无法计算）。其余 9 个渠道与前端设置页完整可用。

### 安装（二选一）

```sh
# A. 已装 +ios8 或更早版本：不用重传 118MB deb，7.8MB 脚本就地热修
sh install-im.sh
# ！！！必须 Ctrl+C 退出当前 dsh，再重新敲 dsh（刷新网页无效）
# sh install-im.sh --status 查状态；--remove 可完整回滚

# B. 全新安装：直接装 +ios9 的 .deb，插件已自带、补丁已打
sudo dpkg -i dev.airdevs.dsh_0.2.1-rc.5+ios12_iphoneos-arm64.deb
```

`install-im.sh` 是**自包含**的：内嵌 base64 tar.gz，用包内 node 解码 + gunzip，只依赖系统 `tar`（越狱环境必备）；安装现场打零 JIT 补丁、注册 patch、建 ESM 解析链路，并**顺带修 `+ios8` 的会话 bug**。凭据在「设置 → IM机器人」里扫码或填，`DeepSeek API Key` 沿用工作台原配置。`DSH_IM=0 dsh` 可临时禁用。

### 验证证据（x86 Linux 按 iOS 目录布局 1:1 模拟 `/var/jb`）

| 场景 | 结果 |
|---|---|
| 真实 `wrapper` 启动 · `native` / `nowasm` 两档 | 均 `0 did-not-activate`、`0 failed-import`、`0 fatal`、无 SIGBUS |
| 带 cookie 握手后抓 `index.html` | client graph 含 `@xmanrui/dsh-im/client.js`，前端入口确实注入 |
| 热修脚本 安装 / `--status` / 幂等 / `--remove` / 重装 | 全通过；回滚后 `cordis.patch.yml` 仍是合法 YAML |
| `--dump-config` | 配置树含 `id: xmanrui-dsh-im` |

> 边界：沙盒里没有各平台的真实机器人凭据，也没法替你扫码，「连上网关收发消息」要在真机上完成；这里保证的是**插件本体、依赖树、前端入口在 A11 零 JIT 档确实加载并运行**。

---

## `+ios8` 修复：重启 DSH 后上一次的对话不会保留

`+ios2` 为兼容 Node 22.12 把 `dsh-session-persistence-jsonl` 的 zstd API 降级成 gzip，但 `DEFAULT_COMPRESSION` 仍是 `zstd` —— **写出去是 gzip 帧，读回来却校验 ZSTD 魔数**，会话写得出、读不回，重启后历史对话全空，恢复时报 `corrupt Zstandard session log`。`+ios8` 把默认压缩改成 `none`（明文 JSONL），读写走同一分支。新装包自带；老设备跑 `sh fix-session.sh`，它会改这一行、把已有 gzip 会话解成明文，并把原件移到 `$DSH_HOME/sessions-legacy-zstd/`（**必须移走**，否则 none 模式下启动会直接拒绝）。修复后会话以明文存储，与桌面端 zstd 会话不互通。

---

## `+ios7` 历史修复：把 QQ Bot 插件装进手机，不再需要 pnpm

你用的是 [@tencent-connect/dsh-qqbot](https://github.com/tencent-connect/dsh-qqbot)（QQ 机器人插件，0.5.5）。之前在 iPhone 终端里装它报 **「退出码 127」**，换几个插件包都一样 —— `+ios6` 里我把它判成「设备缺前置工具、不是本包缺陷」，那个结论只对了一半：缺工具是事实，但可以**让包自己把插件带上**，不必让用户在手机上装。

### 127 的确切来源

dsh 的 `plugin` 子命令把参数原样转发给 pnpm，源码里写死了这个判定：

```
dsh/lib/plugin-BiveYA7h.js:94
if (result.exitCode === 127) process.stderr.write("dsh: pnpm was not found; install pnpm ...")
```

插件自带的 `install.sh` 开头也直接检查 `command -v pnpm`。而 rootless iPhone 上没有 `pnpm / npm / npx / corepack / git`，本包又只内置了 node —— 所以在手机上执行 `dsh plugin --profile qqbot add ...` **必然** 127，跟 node 版本、签名、A11、网络都无关。

### +ios7 的做法：绕开设备端包管理

| 环节 | 官方做法（手机上行不通） | `+ios7` |
|---|---|---|
| 装依赖 | profile 目录里 `pnpm add` | 构建期把 **32 个包 / 321 个纯文本 JS/JSON 文件 / 1.2MB** 固化进 `/var/jb/usr/lib/dsh/node_modules/` |
| peer 依赖 | pnpm 解析 | 直接复用宿主自带的 `cordis / dsh-agent / dsh-llm / dsh-session / schemastery / dsh-user-approval`（都是 0.2.1-rc.5，符号已逐个验证：`createUserMessage`、`BlockAssembler`、`SessionId`、`Schema`、`Context` 全部存在） |
| 注册插件 | pnpm 写 `cordis.patch.yml` | 首次敲 `dsh` 时把一行 `- insert: id: im-qqbot` 追加到 `$DSH_HOME/cordis.patch.yml`（dsh 原生 home 级用户层，对所有 profile 生效） |
| 原生模块 | 可能有 | **0 个 `.node`**，纯 JS |

还有一个**只有真机才会暴露**的坑：dsh 的 ESM resolver 以 **profile 目录** `$DSH_HOME/profiles/<name>/` 为基准解析插件包名，而插件实体在包目录 `/var/jb/usr/lib/dsh/node_modules`，两者不在同一祖先链上 —— 不处理的话真机必然 `ERR_MODULE_NOT_FOUND: Cannot find package '@tencent-connect/dsh-qqbot'`。构建机上因为目录层级巧合（工作目录下的 `node_modules` 恰好是 profile 的祖先）会给出**假绿灯**。`+ios7` 在 `$DSH_HOME/node_modules` 建一条软链（若用户已有真实目录，则只在内部挂一个插件链接，不覆盖），安装脚本把它列为**强校验项**，建不起来直接报错而不是静默成功。

QQ 网关走 `ws` 包、扫码绑定走 `node:https`、API 调用走全局 `fetch`（零 JIT 档由 `fetch-shim.cjs` 接管），三条链路都不受 `nowasm` 档影响。

### 实测证据（x86 Linux，按 iOS 目录布局 1:1 模拟 `/var/jb`）

| 场景 | 结果 |
|---|---|
| `--dump-config` 组合树 | 含 `- id: im-qqbot` / `name: '@tencent-connect/dsh-qqbot'` |
| 真实 wrapper 启动 · `native` 档 | `0 did not activate`、0 error |
| 真实 wrapper 启动 · `nowasm` 档（A11 实际档位） | `0 did not activate`、0 error |
| 给 `apply()` 打探针 | `[QQBOT-PROBE] apply() 真的执行了` —— 排除「没加载所以没警告」的假绿灯 |
| 热修脚本 `--remove` → 重装 → 复跑 | 幂等，回滚干净，解析链路自动重建 |

### 怎么装（二选一）

```sh
# A. 已装 +ios6 或更早版本：不用重传 113MB deb，1.2MB 脚本就地热修
sh install-qqbot.sh
# ！！！必须 Ctrl+C 退出当前 dsh，再重新敲 dsh（刷新网页无效）
# 可选：sh install-qqbot.sh --status / --remove

# B. 全新安装：直接装 +ios7 的 .deb，插件已自带
sudo dpkg -i dev.airdevs.dsh_0.2.1-rc.5+ios12_iphoneos-arm64.deb
```

### 凭据（两种，任选）

1. **推荐**：编辑 `/var/jb/etc/dsh/qqbot.env`，填 `QQBOT_APPID` / `QQBOT_SECRET`（到 [q.qq.com](https://q.qq.com) 建机器人）。填好后启动即连网关，不扫码、不依赖终端二维码渲染。
2. **留空**：插件自动进入扫码绑定，终端会打印绑定链接，也可在工作台的「QQ 机器人」设置页用手机 QQ 扫码。凭据写入 `$DSH_HOME/cordis.patch.yml`，重启保留。

`DeepSeek API Key` 不用在这里配，沿用工作台原本的 LLM 配置。A11 / 3GB 上默认关掉 `media`（富媒体下载）和 `vision`，避免图片消息把 jetsam 引来；想开把 `qqbot.patch.yml` 里的 `media.enabled` 改回 `true`。临时不加载插件：`DSH_QQBOT=0 dsh`。

> 边界照旧说清：沙盒里没有 QQ 开放平台的真实 AppID/Secret，也没法替你按手机 QQ 扫码，所以「连上网关、收到消息」这一步要在真机上用你自己的凭据完成。这里能保证的是**插件本体在 A11 的零 JIT 档确实被加载并运行**，不再卡在 127。

---

## `+ios6` 历史修复：`DeepSeek Messages transport failed`

`+ios5` 之后目录能打开、doctor 全绿，但**发一条消息就会失败**：

```
本轮运行失败  DeepSeek  TRANSPORT
Messages transport failed
已重试模型请求（5/5） · 8s
失败原因：DeepSeek Messages transport failed
```

**不是网络、不是 API key、不是 WebKit，是 shim 的 `Response.body` 写错了。** 原生 `Response.body` 是幂等 getter（多次读取返回同一个 `ReadableStream`），而 `ShimResponse.body` 第一次就置 `_bodyUsed`，第二次直接抛 `TypeError: Body is unusable`。

`dsh-llm-deepseek/lib/index.js` 第 2259–2260 行恰好**连续访问两次**：

```js
if (response.body === null) throw new LlmError("DeepSeek Messages returned no response body", "EMPTY_RESPONSE");
yield* translate(parseSse(response.body, activity), options.model);
```

第二次抛的异常不是 `LlmError`、不是超时、不是主动取消，于是被 `generate()` 兜底包成 `new LlmError("DeepSeek Messages transport failed", "TRANSPORT", ...)`，重试 5 次全一样 —— 截图里的「5/5」就是这么来的。

**为什么之前没测出来**：沙盒用假 key，`/messages` 返回 401，走 `!response.ok` 分支的 `response.text()`，根本到不了这两行；只有真机上配了有效 key、真正进入 SSE 流才触发。

决定性对照（真实 `dsh headless` 对本地 mock 的 DeepSeek Messages API 发消息）：

| shim | 结果 |
|---|---|
| 只把 `body` getter 还原成旧实现 | `rc=1`，`dsh: TRANSPORT: DeepSeek Messages transport failed`，连续 6 次连接被 reset（= 5/5 重试） |
| `+ios6` 修复版 | `rc=0`，正常输出「你好，这是 mock 回复」 |

**修法**：`body` getter 缓存同一个流（幂等），顺带补齐 `dsh-client-connection/lib/client.node.js` 会用的 `formData()` 和 Node 22 的 `bytes()`。11 项兼容探针（SSE 完整链路 / gzip / json / text / formData / bytes / arrayBuffer / redirect:error / clone）全通过。

**已装任意旧版，不用重传 113MB deb：**

```sh
sh fix-transport.sh
# ！！！必须重启 dsh：Ctrl+C 退出当前 dsh，再重新敲 dsh
# shim 是启动期 --require 加载的，刷新网页无效
# 然后回 Safari 刷新工作台，重新发一条消息
```

`dsh-doctor` 第 14 项会直接报「fetch-shim 是否为 `+ios6` 版」。`+ios6` 只是把这个修复固化进包。

### 关于「插件安装退出码 127」

这一条在 **`+ios7` 已经解决**，见上面的章节。结论修正：127 是设备端缺 pnpm（不是 dsh 后端故障），但**不需要**让用户在电脑上装好 profile 再同步 `node_modules` —— 包里已经把插件和依赖预置好了，跑一次 `sh install-qqbot.sh` 即可。


## `+ios5`：`directoryPicker/list failed: Load failed`

`+ios4` 之后，Safari 里 `AbortSignal.any` 的报错没了、弹窗能打开，但「选择工作区目录」里出现新红字：

```
client api:
directoryPicker/list failed:
Load failed
```

**这次不是浏览器版本问题，也不是 `AbortSignal.any` 了。** `Load failed` 是 Safari 里 `fetch()` 对「连接被掐断、零响应」的标准报错。顺着 `client api: ${endpoint} failed: ${error.message}` 找到 HTTP carrier（`dsh-client-connection` 的 `globalThis.fetch` POST `/api/...`），`directoryPicker/list` 是 `invocation.kind = "direct"` 的 unary RPC。

A/B 实测把根因钉死：

| 场景 | `POST /api/directoryPicker/list` |
|---|---|
| native 档（不加载 shim） | **200** 正常响应 |
| `nowasm` 档（+ios4） | **连接被直接关闭、零响应** |
| 仅 `--require fetch-shim.cjs`（无 jitless） | 同样断连 |
| 仅 WASM stub / 只覆盖 `fetch` | **200** |

隔离出唯一变量：`+ios3/+ios4` 的 `fetch-shim.cjs` 在 preload 阶段把 **原生 `Headers` / `Request` / `Response` / `FormData` 一起覆盖**成了半成品 `Shim*` 类。而 dsh 后端 Web 框架（`dsh-api-session-controller`、`dsh-client-connection`）正是用这些原生全局构造 HTTP 响应、解析 multipart —— 处理 POST 时抛异常并静默断连。因为**只有 A11 (iPhone X) 会落到 `nowasm` 档并加载这个 shim**，能跑 native 档的 iPhone 17 Pro Max 完全不受影响，这就是「别人用正常」的真正原因。

**修法**：shim 改为**只覆盖 `fetch` 和 `WebSocket`**，保留四个原生全局。WASM stub 已能让内置 undici 在 `--jitless` 下完成加载期，所以原生全局可以安全保留。

| 改动 | 内容 |
|---|---|
| `shims/fetch-shim.cjs` | 最小侵入版：只覆盖 `fetch`（node:http 出站）/ `WebSocket`（`ws` 包），不再覆盖 `Headers`/`Request`/`Response`/`FormData` |
| `dist/fix-api-load-failed.sh` | **免重传 113MB deb**：只替换设备上这一个 15KB 文件，自动备份、语法自检、幂等 |
| `dsh-doctor` | 新增第 13 项自检，确认 shim 是否为 `+ios5` 版 |

**已装 `+ios3`/`+ios4` 的设备，跑一次脚本即可（几秒）：**

```sh
sh fix-api-load-failed.sh
# ！！！然后必须重启 dsh：Ctrl+C 退出当前 dsh，再重新敲 dsh
# （shim 是 node 启动期 --require 加载的，刷新网页无效）
# 最后回 Safari 刷新工作台，再点「选择工作区目录」
```

`+ios5` 只是把这个修复固化进包，方便以后全新安装自带。若还没修过浏览器垫片（仍报 `AbortSignal.any`），先跑一次 `fix-safari16.sh`，两个脚本互不冲突。

验证（真实起 web 服务）：`--version`、`dump-default-config`、**headless 出站 HTTPS 到 DeepSeek API 的 401**、`/api/directoryPicker/list` POST **200**、WebSocket `/api/remote.mux` **101 握手并收到服务端帧**、Safari 垫片仍注入、服务端异常 0 行、插件全激活。

---

## 零、`+ios4`：手机 Safari 打开工作台报 `AbortSignal.any` 的修复

`+ios3` 装上后 `dsh-doctor` 全绿、终端里 `dsh` 正常起 web 并打印带 token 的 URL，但**用手机 Safari 打开工作台**、点「选择工作区目录」之类弹窗时出现红字：

```
AbortSignal.any is not a function. (In
'AbortSignal.any([token.abort.signal, callerSignal])',
'AbortSignal.any' is undefined)
```

而 iPhone 17 Pro Max 打开同一个工作台完全正常；换别人的 node / 别人的 dsh 移植包，在这台 iPhone X 上还是一样。

**根因：这次不是终端，是浏览器。** 括号措辞 `(In '...', '...' is undefined)` 是 JavaScriptCore(Safari/WebKit) 独有格式，后端 node 用的是 V8，只会写 `TypeError: ... is not a function`。`AbortSignal.any()` 是 **Safari 17.4 / iOS 17.4** 才加入的 Web API，同批还有 `Promise.withResolvers` / `Object.groupBy` / `Map.groupBy` / `Array.fromAsync`。iPhone X (A11) 硬件上限只能停在 **iOS 16.7 / WebKit Safari 16.6**，这批全没有；iPhone 17 Pro Max (iOS 26) 全有。

所以变量是**设备的 WebKit 版本**，不是 node、不是越狱、不是 deb：换后端包没用，iOS 上换 Chrome/Edge/Firefox 也没用（Apple 强制系统 WebKit）。唯一解是给前端补 polyfill。调用点在运行时**动态加载**的插件 `client.js`（如 `dsh-client-ui-workspace`），不在 vite bundle 内，所以必须在页面入口的全局对象上补齐。

| 改动 | 内容 |
|---|---|
| `shims/safari16-polyfill.js` | 按规范实现 5 个 API，**特性检测 + 原生优先**：原生已有就一个字节都不改，iPhone 17 / iOS 17.4+ 零影响，重复加载幂等 |
| `shims/inject_safari16.py` | 构建期把垫片放到 `assets/` 并在 `index.html` 的 `<head>` 内、所有 module 脚本之前插入同步 `<script src>` |
| `dist/fix-safari16.sh` | **已装 `+ios3` 的设备无需重传 113MB deb**，跑一次即可就地热修，幂等 |
| `tier.sh` | `nowasm` 档加 `--no-expose-wasm`，消掉无害但碍眼的 `Warning: disabling flag --expose_wasm` |

验证：真实起 web 服务 + token 认证 + cookie 跟随，渲染后页面含垫片引用、`/assets/safari16-polyfill.js` 返回 200 且内容正确、垫片（pos 36482）先于 module（36936）与 boot 脚本（37877）；模拟 Safari 16 抹掉 5 个原生 API 后，5 个垫片的语义、reason 传递、Set 迭代、幂等全部通过。

**已装 `+ios3` 的设备，不用重传包：**

```sh
sh fix-safari16.sh           # 就地补垫片，幂等，几秒完成
# 然后回 Safari 强制刷新页面（设置 → Safari → 清除历史记录与网站数据）
```

`+ios4` 只是把这个修复固化进包，方便以后全新安装自带。

---

## 一、`+ios3` 修了什么

`+ios2` 已经把 JS 层全部修好（`--version`、配置树、五个内部模块、`--expose-internals`、V8 优化编译都通过），但真机截图显示输入 `dsh` 仍 `zsh: bus error`。根因不在 node 二进制、不在签名、不在传输、不在 shim：

> dsh 真 boot 会调全局 `fetch` → 加载 **Node 内置 undici** → 其 HTTP/1 解析器是 `llhttp` 的 **WebAssembly**，模块加载期即 `new WebAssembly.Module(...)`。V8 默认把 WASM / 优化代码编译放到**后台线程**，而 iOS 的 `pthread_jit_write_protect_np`（APRR/W^X）是**按线程**生效的：后台线程没有可写权限，写可执行代码页即 SIGBUS。

这解释了截图里全部现象：轻量命令全 OK；`dsh-doctor` 的「V8 JIT 通道畅通」也 OK（那只测 JS 循环，**假绿灯**）；web / headless 真 boot 零输出直接死。`--jitless` 单独用不行（会移除 WebAssembly 全局，内置 undici 加载期就崩）。

**`+ios3` 的解法不是猜一个 flag，而是让设备自己试。**

| 改动 | 内容 |
|---|---|
| `smoke.js` | 不联网，但真跑「fetch → 内置 undici → llhttp WASM 编译 → 一次 HTTP 往返」，精确覆盖崩溃路径 |
| `tier.sh` | 启动前逐档跑 `smoke.js`，选第一个不 SIGBUS 的档位，缓存到 `$DSH_HOME/.dsh-tier`，之后零开销 |
| `fetch-shim.cjs` | `nowasm` 兜底档：`--jitless` 下用 `node:http(s)` 接管 fetch 家族 + `ws` 顶 WebSocket + WASM stub 让模块图能建起来，**完全不生成可执行代码** |
| 自动降级 | 选定档位启动后若仍被 SIGBUS/SEGV 杀死，自动切 `nowasm` 重试并写回缓存 |
| `dsh-doctor` | 修两个误报（见下），删假绿灯 JIT 判定，改逐档 WASM 探测 + 捕获退出码明确报 SIGBUS |

### 档位链（从性能最优到确定性最高）

| 档位 | V8 参数 | 特点 |
|---|---|---|
| `native` | 无 | 性能最好，设备本来正常时 |
| `single` | `--single-threaded` | 编译收回主线程，**保留 WASM 与全部功能** |
| `balanced` | + 禁并发编译 / WASM 编译单线程 | 更保守 |
| `safe` | + 禁并发 GC / 限优化层 | 最保守的 JIT 档 |
| `nowasm` | `--jitless --require fetch-shim.cjs` | **零 JIT**，原理级杜绝 SIGBUS |

### 截图里的两个 FAIL 其实都是脚本误报

| 截图输出 | 真相 |
|---|---|
| `[FAIL] node 大小 … 101297040 字节异常` + `[: Illegal number: ?` | iOS 的 `stat -f %z` 被当成「文件系统状态」输出一大段文本（那堆「文件:/ID:/Inodes:」），混进 `?` 才让数值比较失败。**`101297040` 正是正确大小，文件一个字节没少，不用重传。** 已改用 `wc -c` |
| `[WARN] 无法读取 hw.memsize` | iOS 不暴露这个 sysctl key，无害。已改成中性 INFO，不计入汇总 |
| `[ OK ] V8 JIT 通道畅通` | 只测 JS 优化编译，没测 WASM → 假绿灯。已换成真 WASM 冒烟探针 |

### 实测证据链（x86 Linux，真 Node 22.12.x 语义）

- 干净离线 bundle 打三处 22.12 补丁后：`dsh --version` → `0.2.1-rc.5`；`web` 真监听并输出带 token URL；`headless` 到 DeepSeek API 报 401；5 个插件全激活；0 个 `.node`
- `nowasm` 档（`--jitless` + shim）：冒烟探针 rc=0、`--version` 正常、**web 真监听**、**headless 到 401（HTTPS 走通）**
- `single` / `balanced` / `safe` 三档：WASM 仍可用、web/headless 全部通过
- `--jitless` 单独用必崩（`WebAssembly is not defined`），已排除

关于「100%」的边界照旧说清：沙盒里没有你的 A11 真机，设备端签名/trust cache 那一下替不了你按。所以 `+ios3` 做的是**让设备自己逐档探测并自动落到能跑的档**，最后一档在原理上不生成任何可执行代码；`dsh-doctor` 会强制重探并把每档 rc 打给你看。

---

## 二、文件清单

| 文件 | 作用 |
|---|---|
| `build.sh` | 一键组装 `.deb`：校验内置 node（大小/SHA/Mach-O）→ 解包离线依赖树 → 打三处兼容补丁 → **叠加 `+ios7` 插件依赖树** → 复制 `+ios3` 档位链 → 注入 `+ios4` Safari 垫片 → 语法自检 → 打包。**全程离线、字节级可复现** |
| `bundles/node-v22.12.0-iphoneos-arm64` | iPhone X 实测版 node 二进制（101,297,040 字节，随包固化） |
| `bundles/dsh-nodemodules-*.tar.gz` | 已实测通过的纯 JS 依赖树快照（含两个 addon shim、0 个 `.node`） |
| `shims/apply_compat_patches.py` | 三处 Node 22.12 兼容补丁（精确替换 + 断言） |
| `shims/fetch-shim.cjs` | **+ios6** 零 JIT 档接管层：WASM stub + 只覆盖 `fetch`/`WebSocket`，`Response.body` 幂等，补齐 `formData()`/`bytes()` |
| `shims/safari16-polyfill.js` | **+ios4** Safari 16.7 浏览器垫片（5 个 17.4+ API，特性检测+原生优先） |
| `shims/inject_safari16.py` | **+ios4** 构建期把垫片注入前端 `dist/` |
| `dist/fix-safari16.sh` | **+ios4** 已装 `+ios3` 设备的就地热修脚本（免重传 deb） |
| `dist/fix-api-load-failed.sh` | **+ios5** 已装任意旧版设备的就地热修脚本：只替换 `fetch-shim.cjs`，修 API 断连（免重传 deb） |
| `dist/fix-transport.sh` | **+ios6** 已装任意旧版设备的就地热修脚本：只替换 `fetch-shim.cjs`，修 SSE 流式 `TRANSPORT`（免重传 deb） |
| `dist/install-qqbot.sh` | **+ios7** 自包含热修：内嵌 321 个插件文件，装依赖 + 追加 patch + 建 ESM 解析链路 + 校验 + 回滚（1.2MB，免重传 deb） |
| `dist/install-im.sh` | **+ios9** 自包含热修（7.8MB）：内嵌 dsh-im + 114 个依赖，现场打零 JIT 补丁 + 注册 + 解析链路 + 顺带修会话，支持 `--status` / `--remove` |
| `dist/fix-session.sh` | **+ios8** 会话持久化热修：改默认压缩为 none、迁移 gzip 历史会话 |
| `dist/fix-sqlite.sh` | **+ios10** 设备端热修（24KB 自包含）：覆盖 3 个启动文件 + 补挂 im-qqbot + 真跑校验，`--status` / `--restore`，免重传 125MB deb |
| `shims/make_fix_sqlite.py` | **+ios10** 历史生成器（已被 `make_fix_ios11.py` 取代，保留供追溯） |
| `dist/fix-ios11.sh` | **+ios11** 设备端热修：覆盖 3 个启动文件 + 扫描补齐所有 dsh-im 副本补丁 + 重建 patch 属主 + 真 boot 校验 |
| `dist/fix-ios12.sh` | **+ios12** 设备端热修（自包含，含纯 JS pnpm）：修 EACCES + 补插件补丁 + 覆盖启动文件，`--status` / `--restore` |\n| `shims/dsh-home-heal.cjs` | **+ios12** 用户数据目录自愈（免 root rename 修属主、迁移历史会话、清旧预装痕迹） |\n| `shims/dsh-plugin-compat.cjs` | **+ios12** 扫描所有 dsh-im 副本补零 JIT 补丁（由 `dsh-compat` 调用） |\n| `shims/make_fix_ios12.py` | **+ios12** 构建期从 payload + bundles/pnpm 重新生成热修包，保证与 deb 字节一致 |\n| `dist/fix-sqlite.sh` | **+ios11** 与 `fix-ios11.sh` 字节相同的别名，防旧名误用 |
| `shims/make_fix_ios11.py` | **+ios11** 构建期生成上面两个热修包，内嵌文件与 payload 字节一致 |
| `bundles/dsh-im-addon/` | **+ios9** 裁剪后的插件依赖树（1275 文件 / 22.9MB / 0 个 `.node`），构建期叠加并打补丁 |
| `shims/apply_im_patches.py` | **+ios9** 零 JIT / 无 WASM 兼容补丁（两处精确替换，命中数强校验） |
| `bundles/qqbot-addon/` | **+ios7** 裁剪后的插件依赖树（32 包 / 321 文件 / 1.2MB / 0 个 `.node`），构建期叠加进宿主 `node_modules` |
| `payload/var/jb/etc/dsh/qqbot.env` | **+ios7** QQ Bot 凭据（AppID/Secret），留空走扫码 |
| `payload/var/jb/etc/dsh/qqbot.patch.yml` | **+ios7** 插件的 Cordis patch 模板（`im-qqbot` insert 行） |
| `shims/node-addon-require-builtin__lib__index.js` | addon shim：`createRequire` 加载 `internal/*` |
| `shims/node-addon-system__lib__flock.js` | addon shim：单实例恒成功锁 |
| `payload/var/jb/usr/lib/dsh/smoke.js` | **+ios3** WASM/HTTP 冒烟探针 |
| `payload/var/jb/usr/lib/dsh/tier.sh` | **+ios3** 档位定义、逐档探测与缓存 |
| `payload/var/jb/usr/bin/dsh` | 终端入口：越狱态门禁 → 环境变量 / QQ Bot 凭据 → **首次启动挂载 im-qqbot + 建 ESM 解析链路** → 自动选档 → `--expose-internals` → 崩溃自动降级 |
| `payload/var/jb/usr/bin/dsh-doctor` | 装后 12 项自检，含逐档 WASM 探测、真起 web、真 boot headless、SIGBUS 精确诊断 |
| `payload/var/jb/etc/dsh/dsh.env` | 默认 profile / 端口 / `NODE_OPTIONS` / `DSH_TIER` / `DSH_REPROBE` |
| `payload/var/jb/usr/lib/dsh/README-A11.txt` | 设备端 A11 兼容说明 |
| `DEBIAN/control` `postinst` `prerm` | rootless deb 元数据、保留签名/trust-cache、升级时清档位缓存 |
| `ent.plist` | node 自带 9 项 entitlements 的超集，仅兜底补签用 |
| `device-check.sh` | 拷到手机装前跑，只读检查 iOS/架构/越狱态/空间/内存 |
| `dist/*.deb` | 构建产物 |

---

## 三、三步操作

**1. 构建（PC/Mac/Linux，需 python3 / dpkg-deb / sha256sum）**

```sh
cd dsh-ios && sh build.sh
# 产物：dist/dev.airdevs.dsh_0.2.1-rc.5+ios15_iphoneos-arm64.deb
# node 二进制与依赖树都随包固化，不联网、不跑 npm install（缺大文件会自动跑 bootstrap.sh 下载并校验）。
```

**2. 传到手机并装（Sileo 或 SSH）**

```sh
scp dist/*.deb mobile@<iphone-ip>:/var/mobile/
ssh mobile@<iphone-ip> 'sudo dpkg -i /var/mobile/dev.airdevs.dsh_0.2.1-rc.5+ios12_iphoneos-arm64.deb'
```

装前建议先跑一次只读环境检查：

```sh
scp device-check.sh mobile@<iphone-ip>:/var/mobile/
ssh mobile@<iphone-ip> 'sh /var/mobile/device-check.sh'
```

**3. 验收 + 启动**

```sh
dsh-doctor          # 强制逐档重探，打印每档 rc；全 OK 即可用
dsh                 # 首次打印「已选定启动档位 [xxx]」，随后正常启动
```

其它用法：

```sh
dsh web --port 3099                 # 换端口
dsh headless "帮我看下这个报错"      # 一次性任务，出结果就退出
dsh --version                      # 0.2.1-rc.5
DSH_TIER=nowasm dsh                # 强制零 JIT 档
DSH_REPROBE=1 dsh-doctor           # 强制重新逐档探测
```

API Key 走环境变量或 `$DSH_HOME` 里的配置（`dsh` 自己管），不进 deb、不进 Air2。

若 `dsh-doctor` 第 4 项（entitlement）失败：

```sh
ldid -S/var/jb/usr/lib/dsh/ent.plist /var/jb/usr/lib/dsh/bin/node
trustcache inject /var/jb/usr/lib/dsh/bin/node
dsh-doctor
```

---

## 四、必须知道的约束

1. **半不拴绳越狱**：Dopamine 每次重启后 `/var/jb` 会失效。`dsh` 用 `-L` 判链接本身并直接提示「打开 Dopamine 点一次 Jailbreak」。
2. **`--expose-internals` 是硬性要求**，两个 addon shim 依赖它；不能放进 `NODE_OPTIONS`。
3. **三处兼容补丁不能省**：ESM 链接期依赖，缺了 `dsh` 会静默退出或掉 5 个插件。
4. **内存互斥**：A11 / 3GB，`dsh.env` 已限 V8 堆 384MB。**不要和 MC（JVM + JIT）同时跑**。
5. **会话格式**：本构建把 zstd 降级为 gzip，与桌面端 dsh 不互通；iOS 端本地自洽。
6. **保留 node 原签名**：构建机与 `postinst` 都不无条件重签。`+ios3` 不换二进制。
7. **档位缓存**：`$DSH_HOME/.dsh-tier`。升级安装会被 `postinst` 清掉以强制重探；`DSH_REPROBE=1` 可手动重探。
8. **nowasm 档降级项**：`dispatcher`（undici 专有的 DNS pinning）被忽略，web fetch provider 的固定 IP 能力降级；`--jitless` 下纯解释执行会慢一些，但 dsh 是 I/O 密集 CLI，影响有限。
9. **卸载不删数据**：`$DSH_HOME` 里的会话与配置保留。

---

## 五、和 Air2 的关系

这一步**完全独立**，不碰 Air2 的任何一行代码、不动 `Assets.xcassets`、不改 `fetch_deps.py`、不影响 CI 的 ≥50MB 校验。它就是一个越狱终端包。

之后若要把 Harness 接进 Air2，最省事的是复用同一份 `$DSH_HOME`：Air2 侧加一个「连接本机 loopback 的 web 工作台」入口，或加 `A2InstanceKind.harnessLocal` 走 ACP/JSON-RPC，不需要重新解决运行时问题。

## 六、许可证

- Node.js: MIT；`davghz/node22-ios-source` 的 iOS 交叉编译产物按其仓库许可证。
- `@deepseek-ai/dsh` 及各依赖：随包保留各自 LICENSE（`build.sh` 只删 `.md`/`.d.ts`/`.map`）。
- 本工程内的 shim / 补丁 / 脚本：自行使用。

---

## 七、构建产物校验

```sh
dpkg-deb -f dist/*.deb Package Version Architecture   # dev.airdevs.dsh / ...+ios11 / iphoneos-arm64
dpkg-deb -c dist/*.deb | grep -c '\.node$'             # 应为 0
dpkg-deb -c dist/*.deb | grep -E 'smoke.js|tier.sh|fetch-shim.cjs'   # 三个 +ios3 文件
sha256sum dist/*.deb
```

| 项 | 值 |
|---|---|
| 内置 node | 101,297,040 字节，Mach-O 64-bit **纯 arm64** `MH_EXECUTE` + PIE，SHA `f091585d…a8cfc163`（与 `+ios2` 完全一致，未改动） |
| 签名 | 保留上游真机签名（9 项 JIT entitlements），未重签 |
| 包内 `.node` | **0** |
| 三处兼容补丁 | 全部命中（build 时断言） |
| `+ios3` 档位链 | `smoke.js` / `tier.sh` / `fetch-shim.cjs` 齐全且通过语法自检 |
| `dsh` / `dsh-doctor` 权限 | 0755 |
| `+ios9` 插件预装 | dsh-im 1275 文件 / 0 个 `.node`；零 JIT 补丁已打；`install-im.sh` 常驻 |
| `+ios10` sqlite 开关 | 6 处启动链路带 `--experimental-sqlite`；doctor 第 18 项真跑 `node:sqlite`；热修包内嵌文件与 payload 字节一致 |
| `+ios11` 假绿灯 | `dsh` / `dsh-doctor` 用原子 `patch_append`；doctor 第 19 项扫描所有 dsh-im 副本；两个热修脚本字节相同且与 payload 同步 |
| `+ios12` 干净底座 | 包内 0 预装插件；pnpm 纯 JS 0 个 `.node`；wrapper 不写 patch/软链/属主；doctor 第 15/17 项校验 |\n| `+ios12` 新建会话 EACCES | 1:1 复现 root 属主 sessions 树 → 自愈后可真写 `session.v4.jsonl`；doctor 第 20 项 |\n| 无参数默认动作 | `web --no-open --port 3080`（自动带 `im-qqbot`） |

## 八、（可选）20MB 传输限制

传输通道卡 20MB 时，用 `DEB_COMP=xz sh build.sh` 生成 xz 版（`+ios14xz`），再分片：

```sh
DEB_COMP=xz sh build.sh
split -b 15000000 -a 2 dist/*+ios14xz*.deb dsh.part-
# 设备端：cat dsh.part-* > full.deb && sudo dpkg -i full.deb
```

> xz 版需设备 dpkg 支持 xz 解包（Procursus / Dopamine bootstrap 默认支持）。传输不卡 20MB 就直接用 gzip 原包。

## 九、+ios14：修真机「敲 dsh 直接 fatal」与「dsh plugin 仍 127」

+ios12 上真机截图暴露两个回归，已在 1:1 复现环境（`/var/jb` 指向 stage、`nobody` 身份）逐字复现并修好。

| 症状 | 根因 | 修复 |
| --- | --- | --- |
| `dsh: fatal uncaught exception -> patches: patches.yml/cordis.patch.yml must be a top-level YAML array of loader patch entries` | `dsh-home-heal.cjs` 的 `cleanPatch()` 把两条旧预装 `- insert:` 整块删掉后留下纯注释，`js-yaml.load` 返回 `null`，`dsh-app-boot/lib/index.js:4000` 的 `parsePatchList` 直接抛错。更糟的是 doctor 第 15 项会触发这次清理并报 OK，于是「doctor 全绿、一敲 dsh 就崩」 | 重写为 `cleanAllPatches()`：全量扫描 home 级 + 所有 `profiles/*` 级 `cordis.patch.yml` / `patches.yml`，整块删目标后强制保证顶层是合法 YAML 数组（空则写官方模板 `[]`），并能修复已被 +ios12 删坏的纯注释文件。严格只按 `id` 匹配，用户自装插件块保留 |
| headless boot `ERR_MODULE_NOT_FOUND`（`@tencent-connect/dsh-qqbot` / `@xmanrui/dsh-im`） | `readProfilePatches` 读两类 patch 文件，+ios12 只清了 home 级，profile 级残留仍引用两个已不预装的包 | 同上，全量扫描清除 |
| `dsh: pnpm was not found; install pnpm and make it available on PATH.`（127） | `package.json` 的 exports 把 CLI（`lib/types/operations.js`，单引号）与 web service（`lib/index.js`，双引号）分成两份构建产物，都以 `execa(options.command ?? 'pnpm', ..., {extendEnv:false})` 启动 pnpm；真机上 dsh 自造的 env 里 PATH 找不到 `/var/jb/usr/bin`，`pnpm` 的 `/usr/bin/env node` shebang 也不可靠 | `apply_pnpm_abs_patch.cjs` 给两份产物各 5 处 `command` + 5 处 `args` 注入「包内 node 绝对路径 + `pnpm.cjs` 绝对路径」直连，命令变成 `$D/bin/node $D/libexec/pnpm/bin/pnpm.cjs add <pkg>`，彻底绕开 PATH/shebang |

配套改动：`dsh-doctor` 开头先跑 heal 再检测（否则第 9 项 headless boot 会先崩），第 15 项改为用包内 `yaml` 真解析所有 patch 文件校验顶层数组，新增第 22 项校验两份产物的 pnpm 注入；`dsh` wrapper 导出 `DSH_NODE`。

**升级方式（二选一）**

```sh
# 免重传 120MB deb（推荐，4.7MB 自包含热修）
sh /var/jb/usr/lib/dsh/fix-ios14.sh
sh /var/jb/usr/lib/dsh/fix-ios14.sh --status    # 只看状态

# 或重装完整包
sudo dpkg -i dev.airdevs.dsh_0.2.1-rc.5+ios14_iphoneos-arm64.deb
dsh-doctor
```

热修以 `mobile` 跑时，用户数据自愈（patch 清理 / 会话树属主）一定生效；包内两份构建产物的 pnpm 补丁若因 `$D` 归 root 写不进去，会明确提示用 root 重跑或装新 deb。

装插件（新包不再自带任何插件）：

```sh
dsh plugin --profile web add <包名>
dsh-compat        # 装完 @xmanrui/dsh-im 后补 A11 零 JIT 补丁
```

---

## 本仓库内容说明

git 里提交的是**全部源码、构建脚本、补丁脚本、设备端热修与文档**：

| 路径 | 内容 |
| --- | --- |
| `build.sh`、`device-check.sh`、`ent.plist` | deb 构建、设备预检、entitlements |
| `DEBIAN/` | control / postinst / prerm |
| `payload/` | 设备端 `dsh` 包装器、`dsh-doctor`、`pnpm`、`dsh-compat`、`tier.sh`、环境模板 |
| `shims/` | Node 22.12 兼容补丁、零 JIT / WASM 补丁、自愈脚本、热修生成器 |
| `bundles/pnpm/` | 内置纯 JS pnpm 10.28.2（构建必需，19MB） |
| `dist/*.sh`、`dist/legacy/`、`dist/SHA256SUMS.txt` | 各版本设备端热修、安装脚本与校验清单 |

以下**故意不入 git**（见 `.gitignore`）：

- `.build/`：构建中间产物，约 1.3GB，可由 `build.sh` 重建；
- `dist/*.deb`、`dist/archive/`：单个 118~130MB，超过 GitHub 单文件 100MB 硬限制；
- `bundles/node-v22.12.0-iphoneos-arm64`（97MB）与 `bundles/dsh-nodemodules-*.tar.gz`（85MB）：构建所需的离线二进制依赖；
- `bundles/dsh-im-addon/`、`bundles/qqbot-addon/`：+ios12 起已弃用的历史预装插件。

成品 deb 与大体积构建输入通过本仓库 **Releases 附件**分发。克隆后要本地重建，把 Releases 里的两个文件放回 `bundles/`，再执行：

```sh
sh build.sh        # 产物输出到 dist/，构建期自带强校验
```
