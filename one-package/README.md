# 单包（APP + 引擎 + 手机操控 + 全屏 WebClip）

本目录是 `dev.airdevs.dsh` 单包 deb 的可复现构建材料：

- `DEBIAN/control`：中文包描述（rc.3）。
- `DEBIAN/postinst`/`prerm`：引擎安装脚本 + 单包 extras 调用。
- `dsh-extras-postinst.sh`：APP 签名/图标、手机操控 provider/bridge、全屏 WebClip、npm 国内镜像、插件市场 region=china。
- `dsh-extras-prerm.sh`：卸载清理。
- `webclip/`：全屏 Web Clip 的 Info.plist 与图标。
- `build-one-package.sh`：把引擎树、APP payload、手机操控打包成一个 deb。

iOS 补丁（构建前对引擎树执行）：
1. `apply_pnpm_abs_patch.cjs <dsh-plugin-manager/lib>`：pnpm 包内绝对路径 + `--jitless`（去掉 Node24 不认的 `--no-expose-wasm`）。
2. `apply_plugin_install_patch.cjs <node_modules>`：GitHub 预检短路 + 插件市场主线程解析/redirect follow。
3. `apply_frontend_inject.cjs <dsh-web-frontend/dist> <safari16-polyfill.js> <dsh-ios-manual-install-transform.js>`。
4. rc.3 的 pnpm 隔离布局：把 `dsh-plugin-manager` 的 `__dshRoot` 固定为 `/var/jb/usr/lib/dsh`；tier 用 `--preserve-symlinks`。
5. `dsh-phone-bridge-daemon` 去掉 `--no-expose-wasm`，`ensure-config` 加 `--jitless`。

rc.3 前端“生态插件转化”钩子：rc.3 上游 client.js 的锚点和 +ios15 补丁不一致，不能直接跑 apply_plugin_install_patch.cjs。已在单包里用 `patch-rc3-client-transform.sh` 把已验证的 client.js（含 `__dshIosTransformSpec`）替换进 rc.3 的 pnpm 隔离树，前端注入的 transform 资产 + polyfill 也已就位，手动安装对话框的转化恢复。

验证：rc.3 `--version`=0.2.2-rc.3；rc.3 web 3085=401；`dsh plugin --profile web add is-number`=Done in 4.5s；8090/8091 health=ok。
