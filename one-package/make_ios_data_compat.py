#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""修 +ios24.x 真机「工作区/对话加载不出」：单包 stage 副本的数据层兼容补丁。

只改 dpkg stage 里的依赖树副本，绝不碰仓库 payload/ 与 shims/（那些文件
被稳定底座 build.sh / make_fix_ios15.py 共用，动一个字节就会改变已发布的
+ios15 deb SHA，用户要求稳定底座逐字节不动）。

真机截图（+ios24.1 / iPhone X / A11，2026-11-14）暴露两个功能级根因，
都在「依赖树的数据/平台适配」层，与 Node 版本、鉴权、零 JIT 无关：

1) 会话压缩格式不匹配 —— 对话/工作区读不出的总闸门
   rc.3 的 @deepseek-ai/dsh-session-persistence-jsonl 里
       const DEFAULT_COMPRESSION = "zstd";
   而 dsh-base/cordis.patch.yml 的 session-persistence-jsonl config 只设
   root、不设 compression，于是后端真用 zstd。

   用户从 +ios15 / +ios18 升级上来，$DSH_HOME/sessions 里全是稳定底座
   apply_compat_patches.py 写出的「明文 .jsonl」（那套补丁把默认值改成
   none）。JsonlSessionPersistence.checkRootEncoding() 在 create/open/list
   的入口通过 ensureRootEncoding() 全局执行：扫描到 opposite 编码
   （.jsonl，因为当前配置 zstd 的 opposite 是 none）就抛
       session artifact ... uses .jsonl, but this backend is configured
       for compression "zstd"; use a separate root or select the matching
       compression mode
   这是 host 装配期的全局 fatal —— headless 起不来（dsh-doctor 的
   [WARN] headless boot ... rc=1、安装日志 [warn] Web UI 尚未就绪），
   于是 typert gateway 里所有 host 侧 controller（workspace /
   conversation / directoryPickerController）统统「active Service
   ... is unavailable」：前端工作区列表、对话全空，点「选择工作区目录」
   报 directoryPicker/list: active Service "directoryPickerController"
   is unavailable。

   修法：把 DEFAULT_COMPRESSION 改回 "none"，与稳定底座、用户既有会话
   逐字一致。Node 24 原生 zstd API 保留（读 .jsonl.zstd 仍可用），只是
   默认写/读明文，彻底绕开这个全局闸门。这跟 Node 主版本无关：
   +ios24 之前「因为 Node 24 原生支持 zstd」整包跳过 apply_compat_patches
   是错的 —— 那条 zstd→none 的本质是「兼容用户已有明文会话数据」，
   不是「补 Node 22 缺的 API」。

2) iOS 上目录选择器选错后端 —— 工作区目录列表/新建仍会失败
   @deepseek-ai/dsh-host-directory-picker-auto 的
       resolveDirectoryPickerBackend()
   在 process.platform === "darwin"（iOS 也是 darwin）且 loopback 绑定时
   返回 "native"。native 后端靠 osascript / NSOpenPanel / koffi，iOS 没有，
   且只暴露 pick capability；而 Web Clip 是浏览器，前端「选择工作区目录」
   用的是 browse UI（在-app 目录浏览 + 新建文件夹），走 directoryPicker/list
   需要 browse capability。选 native 会让 directoryPickerController 的
   list() 里 requireCapability("browse") 抛 directory-picker/unavailable。

   修法：把 resolveDirectoryPickerBackend() 里 darwin/win32 分支的
   return "native" 直接改成 return "browse"（纯 node:fs/promises，零原生
   依赖）。本 deb 是 iOS 专用单包，darwin 即 iOS、永远不会是有屏幕的 macOS
   桌面，Web Clip 又只可能用 browse UI；auto 装配会据此同时挂载
   dsh-host-directory-picker-browse（后端）与
   dsh-client-ui-directory-picker-browse（前端）两个 entry。

两处替换都带「锚点精确命中 1 次」断言 + 幂等 marker；命中漂移立即中止
构建，绝不产出「补丁没打上但看起来像打过」的包。

用法：make_ios_data_compat.py <node_modules 目录>
  （构建期传 ENGINE/node_modules；调试/复核可直接传解包后的
   var/jb/usr/lib/dsh/node_modules。设备端热修的 sed 版见 dist/fix-ios24.sh。）
退出码：0=两处都命中（或已应用幂等跳过）；1=任一锚点漂移/文件缺失。
"""
import os
import sys

MARK1 = "// dsh-iOS compat: 会话默认明文 .jsonl（兼容用户既有会话，见 make_ios_data_compat.py）"
MARK2 = "// dsh-iOS compat: Web Clip 浏览器无原生选择器，iOS/darwin 强制 browse"
# 结果值幂等标记：+ios18(Node22) 已由 apply_compat_patches.py 改成 none，
# 本脚本对它必须安全跳过而不是判定锚点漂移、误中止构建。
DONE1 = 'const DEFAULT_COMPRESSION = "none";'
DONE2 = '\tif (facts.platform === "darwin" || facts.platform === "win32") return "browse";'


def read(p):
    with open(p, "r", encoding="utf-8", newline="") as f:
        return f.read()


def write(p, s):
    with open(p, "w", encoding="utf-8", newline="") as f:
        f.write(s)


def patch(nm, rel, old, new, label, marker):
    """精确命中 1 次才替换；已有 marker 则幂等跳过；否则中止。"""
    p = os.path.join(nm, rel)
    if not os.path.isfile(p):
        print("  [FAIL] %s: 目标文件不存在 %s" % (label, rel), file=sys.stderr)
        return False
    s = read(p)
    done = DONE1 if label.startswith("会话") else DONE2
    if marker in s or (done in s and old not in s):
        # 二次构建 / Node22 档已被 apply_compat_patches.py 改过 / 设备端
        # 热修已打过：结果值已正确，安全跳过。
        print("  [ == ] %s: 已应用（幂等跳过）: %s" % (label, rel))
        return True
    n = s.count(old)
    if n != 1:
        print("  [FAIL] %s: 锚点命中 %d 次（应为 1），依赖树版本可能变化: %s"
              % (label, n, rel), file=sys.stderr)
        print("         anchor=%r" % old[:120], file=sys.stderr)
        return False
    write(p, s.replace(old, new, 1))
    print("  [ OK ] %s: %s" % (label, rel))
    return True


def main():
    if len(sys.argv) != 2:
        print("用法: make_ios_data_compat.py <stage 目录>", file=sys.stderr)
        return 1
    nm = sys.argv[1]
    if not os.path.isdir(nm):
        print("node_modules 不存在: %s" % nm, file=sys.stderr)
        return 1

    ok = True

    # --- 补丁 1：会话默认压缩 zstd -> none（兼容用户既有明文 .jsonl）---
    OLD1 = 'const DEFAULT_COMPRESSION = "zstd";'
    NEW1 = (
        MARK1 + '\n'
        'const DEFAULT_COMPRESSION = "none";'
    )
    ok &= patch(
        nm,
        "@deepseek-ai/dsh-session-persistence-jsonl/lib/index.js",
        OLD1, NEW1, "会话默认压缩 zstd→none", MARK1,
    )

    # --- 补丁 2：iOS/darwin 强制 browse 目录选择器后端 ---
    # 原行（tab 缩进）：
    # \tif (facts.platform === "darwin" || facts.platform === "win32") return "native";
    # 本 deb 是 iOS 专用单包，process.platform==="darwin" 即 iOS，永远不会是
    # 有屏幕、有 osascript/NSOpenPanel 的 macOS 桌面；Web Clip 又是浏览器，
    # 前端目录选择器只可能用 browse。直接把 darwin 从 native 判定里摘出来，
    # 落到函数既有的 browse 分支（win32 在此包同样不可达，一并视为 browse）。
    OLD2 = '\tif (facts.platform === "darwin" || facts.platform === "win32") return "native";'
    NEW2 = (
        '\t' + MARK2 + '\n'
        '\t// dsh-iOS: this deb only runs on iOS (darwin) behind a Web Clip browser;\n'
        '\t// native needs osascript/NSOpenPanel which iOS lacks, and the browse UI\n'
        '\t// served to the Web Clip calls directoryPicker/list. Fall through to browse.\n'
        '\tif (facts.platform === "darwin" || facts.platform === "win32") return "browse";'
    )
    ok &= patch(
        nm,
        "@deepseek-ai/dsh-host-directory-picker-auto/lib/index.js",
        OLD2, NEW2, "directoryPicker iOS 强制 browse", MARK2,
    )

    if not ok:
        print("iOS 数据兼容补丁未全部应用，构建中止。", file=sys.stderr)
        return 1
    print("  iOS 数据兼容补丁：2/2 应用成功")
    return 0


if __name__ == "__main__":
    sys.exit(main())
