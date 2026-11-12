# Node 24 实验包（`dev.airdevs.dsh-node24`）

> **这是实验分支，不是默认交付物。** 默认稳定底座仍是 `+ios15`
> （dsh `0.2.1-rc.5` + 内置 Node `22.12.0`），本目录**一个字节都不改它**。

## 这个包是什么 / 不是什么

| | |
|---|---|
| **是** | 基于已验证 iOS 移植方案自行编译的 **Node v24.22.3** 独立 CLI + **dsh 0.2.2-rc.2**，装在独立路径，用独立启动器 `dsh24` 运行 |
| **不是** | 不是「已验证能在你的 iPhone X A11 上 100% 跑通」的产品；不是默认包的升级替换；不改动 `dsh` 命令 |

### 为什么现在能做（更正此前错误结论）

此前文档写「iOS arm64 Node ≥24.9 可执行文件不存在」——**这句话是错的**，现更正：

- **没有现成可直接用的独立 CLI 成品**：OpenClaw-iOS 的 Release 只发布 `node-v22.19.0-iphoneos-arm64`；`heylogin/nodejs-mobile v24.5.0-mobile` 的 iOS zip 是 framework/静态库（供 App 嵌入），不是独立 `node` 命令，且 24.5.0 < 24.9.0。
- **但有现成的完整编译流水线源码（MIT）**：[`j0shua-SYSON/openclaw-ios`](https://github.com/j0shua-SYSON/openclaw-ios) 的 `.github/workflows/node-drumbrake.yml` + `scripts/ios-source-fixups-drumbrake.sh`，已在 macOS-14 上把 **Node 24 + DrumBrake（V8 的 WASM 解释器）** 交叉编译成 iOS arm64 独立可执行文件。
- 本仓库把这套补丁与 `davghz/node22-ios-source`（**iPhone X 真机验证过**的打包/签名法、10 项 JIT entitlement 超集）合成一条面向 A11 / iOS 16.7.15 的流水线，见 `.github/workflows/node24-*.yml`。

### 诚实的边界（务必读完）

**编译出二进制 ≠ 能在 A11 上跑 ≠ 能跑 DSH ≠ 插件/会话稳定。** 与默认包的 22.12.0 相比：

| 背书 | 默认 22.12.0 | 本实验 Node 24 |
|---|---|---|
| 上游在 **iPhone X (A11)** 真机测过 `node -v` / JS / **WASM compile+execute=42** | ✔ | ✘ |
| 上游真机签好的 **9 项 JIT entitlement** 随二进制自带 | ✔ | ✘（CI 用 10 项超集 `ldid -S` 自签） |
| iOS 16.7.15 内核是否放行这些 entitlement / APRR 行为 | 你实机验过 | **零验证** |
| DrumBrake 在 A11 的行为、V8 13.6 的 jitless 语义 | — | **零验证** |
| dsh 0.2.2-rc.2 读旧会话、插件兼容 | —（rc.1 已 31 项核验） | **零验证** |
| 你自己实机验证 | ✔ | **待你按下面清单做** |

沙箱是 Linux x86_64，没有 Xcode / iPhoneOS SDK / A11 真机，**编译只能在 GitHub Actions `macos-14` 上做，运行验证只能在你的设备上做**。本地只能验补丁锚点、脚本语法、默认包 SHA 不变。

## 目录结构

```
.github/workflows/node24-jitless.yml   # 主推：Node24 + DrumBrake，--jitless --wasm-jitless
.github/workflows/node24-jit.yml       # 对照：标准 JIT（A11 有 APRR，跳过 A9/A10 的 mprotect W^X 补丁）
node24/
  scripts/LICENSE-MIT.txt              # OpenClaw MIT 全文
  scripts/ios-source-fixups*.sh        # 逐字移植的 iOS 源码补丁（含 A11/APRR 守卫）
  scripts/check-anchors.sh             # 本地可跑：v24.22.3 补丁锚点命中自检
  DEBIAN/{control,postinst}           # 独立包名 + 10 项 entitlement 补签
  payload/
    ent.plist                         # 10 项超集（不是 OpenClaw 的 4 项）
    tier24.sh                         # V8 13.6 flag 白名单过滤，绝不传未知 flag
    fetch-shim24.cjs / smoke24.js     # nowasm 兜底档 / 逐档冒烟探针
    dsh24                             # 独立启动器，复用 DSH_HOME
    dsh24-switch                      # on/off/status/restore，一键回退
    dsh-doctor-node24                 # 专项体检（10 项，不锁 22.12 文件大小）
  verify-node24.sh                    # 本地静态自检
  dist/SHA256SUMS-node24.txt          # 实验产物独立清单（不动 dist/SHA256SUMS.txt）
```

### 隔离性（用户要求「升级插件不丢、对话不丢」）

- node → `/var/jb/usr/lib/dsh-node24/bin/node`，**绝不写** `/var/jb/usr/lib/dsh/bin/node`
- `node_modules` → 实验包自己的 `dsh 0.2.2-rc.2` 树
- **DSH_HOME 与稳定包完全相同**（插件、`sessions/`、配置都在原地）→ `dsh24` 与 `dsh` 共用，天然不丢
- 档位缓存 `.dsh-node24-tier` / flag 白名单 `.dsh-node24-flags` 独立，不碰稳定包 `.dsh-tier`
- `dsh24-switch on` 先 `cp -a` 备份 DSH_HOME；`off` 停用实验入口并清实验缓存；`restore` 从备份回滚
- 包名 `dev.airdevs.dsh-node24` 独立，`verify-deb.sh` 的 `case *0.2.2-rc.1*` 不会误判
- 默认三个 deb 的 SHA 与 `dist/SHA256SUMS.txt` 14 项**字节不变**（`verify-node24.sh` 第 6 项会断言）

## 当前状态（2026-11-12）

| 产物 | 状态 |
|---|---|
| 编译流水线（两条 workflow + MIT 补丁 + 锚点自检） | ✅ 已落地，`check-anchors.sh` 对 v24.22.3 **15 命中 0 失配** |
| dsh `0.2.2-rc.2` 纯 JS 依赖树（661 包 / 0 `.node` / 2000 文件语法 0 错） | ✅ `node24/make-rc2-tree.sh` 已生成，bundle SHA 见 `dist/SHA256SUMS-node24.txt` |
| 旁路实验 deb 的全部文件（control / postinst / payload / 组装脚本） | ✅ 已落地，`build-experimental-deb.sh` 端到端跑通 |
| **可安装的实验 deb** | ⏳ **PENDING**：等 CI 编出真实 iOS arm64 node 二进制后用 `build-experimental-deb.sh` 组装。组装脚本有 ≥20MB 最小尺寸防护，不会把占位文件打成包 |
| **A11 / iOS 16.7.15 真机运行** | ❌ **零验证**，需你按下方清单逐级做 |

> 默认 `+ios15` / `+ios16` / APP 三个 deb 的 SHA 与 `dist/SHA256SUMS.txt` 14 项**字节未变**；`DEBIAN/`、`ent.plist`、`payload/`、`shims/`、`build.sh`、`bootstrap.sh` 相对 HEAD 零改动（`node24/verify-node24.sh` 第 6 项会断言）。

## 编译（GitHub Actions）

1. 推到 `exp/node24` 分支后，手动触发（仅 `workflow_dispatch`，推送不会自动编译）：
   ```sh
   gh workflow run node24-jitless.yml --repo yitenchen123/dsh-ios --ref exp/node24 \
     -f node_ref=v24.22.3
   gh workflow run node24-jit.yml      --repo yitenchen123/dsh-ios --ref exp/node24 \
     -f node_ref=v24.22.3
   ```
2. CI 里 `check-anchors.sh` 先跑（本地已实测 **15 命中 0 失配**）；编译约 60–110 分钟，`make -j2` 避免 macOS runner OOM。
3. 成功产出 `node-v24.22.3-iphoneos-arm64*`（+ `ent.plist`），上传 Actions artifact 与 Release 草稿。
4. **组装可安装 deb**（拿到真二进制后，在构建机上做）：
   ```sh
   gh run download <run-id> -n node24-ios-jitless-v24.22.3 -D node24/dist
   NODE24_BIN=node24/dist/node-v24.22.3-iphoneos-arm64-jitless \
     sh node24/build-experimental-deb.sh
   # 产出 node24/dist/dev.airdevs.dsh-node24_0.2.2-rc.2+ios24exp1_iphoneos-arm64.deb
   # 并把 SHA 写入 node24/dist/SHA256SUMS-node24.txt
   ```
   组装脚本会校验 Mach-O 头、≥20MB 尺寸、dsh 版本、0 个 `.node`、包内路径隔离，并复用 `build.sh` 的 mode 归一化 / `SOURCE_DATE_EPOCH` / `dpkg-deb -Zgzip -z9`。
5. **编译失败**：只交付流水线 + 锚点报告 + 失败日志，明确「未产出二进制、A11 零验证」，**绝不伪造产物**。锚点若因版本升级漂移，才在人工确认后回退 `NODE_REF=v24.18.0`。

## 真机逐级验证清单（你的 iPhone X / A11 / iOS 16.7.15）

> **任一步失败立即停止**，运行 `dsh24-switch off`，稳定包与插件/对话不受影响。

```sh
# 0. 先确认默认包没被动、并备份用户数据
cd /var/jb/usr/lib && sha256sum -c 2>/dev/null || true   # 或直接看 dist/SHA256SUMS.txt
cp -a /var/jb/var/mobile/.dsh /var/jb/var/mobile/.dsh.bak-node24

# 1. 装实验包 + 看签名
dpkg -i dev.airdevs.dsh-node24_0.2.2-rc.2+ios24exp1_iphoneos-arm64.deb
ldid -e /var/jb/usr/lib/dsh-node24/bin/node | grep -c -E 'allow-jit|dynamic-codesigning'
#    期望 >= 3；为 0 就停，别继续

# 2. 最小执行（这步才第一次真正检验「会不会 SIGBUS」）
/var/jb/usr/lib/dsh-node24/bin/node -v                    # v24.22.3
/var/jb/usr/lib/dsh-node24/bin/node -e 'console.log(1+1)' # 2
/var/jb/usr/lib/dsh-node24/bin/node -e 'new WebAssembly.Module(new Uint8Array([0,97,115,109,1,0,0,0])); console.log("wasm ok")'

# 3. HTTP 往返（A11 上 SIGBUS 的经典触发点）
/var/jb/usr/lib/dsh-node24/bin/node /var/jb/usr/lib/dsh-node24/smoke24.js; echo "rc=$?"
DSH_TIER=drumbrake /var/jb/usr/lib/dsh-node24/bin/node --jitless --wasm-jitless \
  /var/jb/usr/lib/dsh-node24/smoke24.js; echo "rc=$?"

# 4. 启用并体检
dsh24-switch on
dsh-doctor-node24
dsh24 --version            # 0.2.2-rc.2
dsh24 --dump-default-config >/dev/null; echo "rc=$?"
dsh24 headless --help >/dev/null; echo "rc=$?"

# 5. web 真监听（另开终端 curl，确认出 token URL 再 Ctrl-C）
DSH_TIER=drumbrake dsh24 web --no-open --port 3081

# 6. 关键：插件不丢、对话不丢
dsh24 plugin list                                  # 与稳定包的清单一致
# 建一次对话 → 退出 → 再进 dsh24 → 确认历史还在
dsh24-switch status                                # 会话文件数应 > 0

# 7. 回退验证（必须做）
dsh24-switch off
dsh --version                                      # 仍 0.2.1-rc.5
/var/jb/usr/lib/dsh/bin/node -v                     # 仍 v22.12.0
# 再确认插件与对话仍在
# 确认无误后可彻底移除： dpkg -r dev.airdevs.dsh-node24
```

**只要第 2 步就 SIGBUS**：说明自签 entitlement 没被 iOS 16.7.15 内核接受 —— 这正是默认包「上游真机签名」无法被本地编译复刻的那一层，本实验包到此为止，不要试图在设备上乱改签名。

## 已知不确定项（不隐瞒）

1. **entitlement 内核放行**：CI 用 `ldid -S` 自签 10 项，但 `dynamic-codesigning` 等私有 entitlement 在 iOS 16.7.15 上是否被信任，取决于 Dopamine 的 trustcache / dyldhook，本地无法验证。
2. **DrumBrake**：上游方案目标是 A9 / iOS 15.8.5（无 APRR、必须 jitless）。A11 有 APRR，理论上两档都能试，但 V8 13.6 的 `--wasm-jitless` 语义未在 A11 验证。
3. **dsh 0.2.2-rc.2**：2026-11-12 当天发布的 `next`，`engines.node >=24.9.0`、90 个依赖与 rc.1 一致；`bin.js` 结构有变化但 Node 24 原生支持 `import.meta.main`，故**不再调用**稳定包那套 `apply_compat_patches.py`（前三条补丁的锚点已失配）。会话格式兼容性需真机第 6 步确认。
4. **补丁链**：`tier.sh` / `fetch-shim.cjs` / `apply_pnpm_abs_patch.cjs` / `dsh-doctor` 里绑死 V8 12.4 的 flag 与 `internal/*` 路径，本包用独立副本 `tier24.sh` 的 **flag 白名单过滤** 规避（不认识的 flag 丢弃而非传参）。真机若五档全灭，说明 V8 13.6 还有未预料的差异。
5. **性能**：jitless / DrumBrake 是解释执行，比 JIT 慢；dsh 是 I/O 密集 CLI，影响通常有限，但 A11 / 3GB 上仍需实测。

## 出处与许可证

- iOS 交叉编译补丁：[`j0shua-SYSON/openclaw-ios`](https://github.com/j0shua-SYSON/openclaw-ios) @ `31a6780c`，MIT（全文见 `scripts/LICENSE-MIT.txt`）
- iPhone X 验证过的打包/签名基线：[`davghz/node22-ios-source`](https://github.com/davghz/node22-ios-source) `v22.12.0-26-ios`
- Node 源码：[`nodejs/node`](https://github.com/nodejs/node) `v24.22.3`（V8 13.6）
