# 单包（APP + DSH 0.2.2-rc.3 引擎 + 全屏入口）

本目录是 `dev.airdevs.dsh` **rc.3 全屏单包**的可复现构建与核验材料，也是
「最新 DSH + 像官方 App 一样点图标即用」的主交付。稳定底座
（`build.sh` 产出的 `0.2.1-rc.5+ios15` / `0.2.2-rc.1+ios16`）一个字节都没动。

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
- `dsh-extras-postinst.sh` / `dsh-extras-prerm.sh`：**全屏 Web Clip 安装 + uicache**、APP 签名、launchd 保活、卸载清理。
- `webclip/`：`FullScreen=true` 的 `Info.plist` 与 `icon.png`。
- `dsh-web-token`：固定 loopback token，唯一真相源。
- `build-one-package.sh`：组装 deb。
- `verify-one-package.sh`：独立核验（含**静态 Web Clip URL 的 rc.3 鉴权黑盒**）。
- `patch-rc3-client-transform.sh`：可选，替换 rc.3 上游 `client.js` 以恢复 Web UI 手动安装对话框的「生态插件转化」钩子。

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
