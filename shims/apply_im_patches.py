"""
apply_im_patches.py — 给 @xmanrui/dsh-im 5.10.0 打「iOS 零 JIT / 无 WASM」兼容补丁。

背景
----
iPhone X (A11) / iOS 16.7.15 / Dopamine 3.0 上，dsh 的 tier.sh 最终会落到
`nowasm` 档：--jitless --no-expose-wasm --require fetch-shim.cjs。这是为了
避开内置 undici 的 llhttp WASM 在后台线程触发 SIGBUS（+ios3 的 bus error）。

dsh-im 的 lib/index.js 是 esbuild 打包产物，里面内联了 WhatsApp/Baileys 的
libsignal WASM glue（lthash / expandedappstatekeys）。该 glue 在**模块顶层**
执行 `var JCe=new VC;`，而 VC 的构造函数直接调用
`ge.lthashantitampering_new()`。零 JIT 档下 WebAssembly 全局不存在
（连 node:vm 的 runInNewContext('WebAssembly') 都取不到，已实测），
ge 拿不到 exports，于是整包 import 失败：

    xmanrui-dsh-im (@xmanrui/dsh-im): failed to import:
    TypeError: ge.lthashantitampering_new is not a function

Cordis 会把它降级成 "1 entry did not activate"，但 web 仍能监听 —— 这是最
危险的假故障：网页能开、设置里却没有「IM机器人」入口，9 个渠道全废。

补丁内容（两处精确替换，全部在 lib/index.js）
--------------------------------------------
1) 顶层单例惰性化：WASM 不可用时 JCe 置 null，不再让整包 import 崩掉。
2) history-sync 的 finish() 加 null 保护：JCe 不可用时返回 128 字节占位
   hash，而不是抛 TypeError。WhatsApp 的「加密历史同步哈希」这一项能力
   在零 JIT 档降级；其余 9 个渠道（飞书/微信/企微/钉钉/QQ/Slack/
   Telegram/Discord/Matrix 以及 AI Office Connector）完全不受影响。

已确认 JCe 在整包里只有 2 处引用（顶层构造 + finish），改动面极小。
native 档（有 WASM）因为 try 分支会成功，行为与官方包完全一致 —— 补丁
只在 WASM 缺失时才改变路径，不会劣化桌面 / 新 iPhone 的体验。

用法：apply_im_patches.py <包含 @xmanrui/dsh-im 的 node_modules 目录>
退出码：0=两处全部命中并替换；1=任一模式未命中（构建必须中止）。
"""
import sys
from pathlib import Path

REL = "@xmanrui/dsh-im/lib/index.js"

# 1) 顶层 lthash 单例。原文（esbuild 产物，无空格）：
OLD_TOP = "var JCe=new VC;"
NEW_TOP = (
    "var JCe=null;try{JCe=new VC}catch(_dshImWasmErr){}"
    "/* dsh-ios +ios9: libsignal WASM unavailable under --jitless */"
)

# 2) WhatsApp history sync 的 lthash 收尾。
OLD_FINISH = "let e=JCe.subtractThenAdd(t,a,o);"
NEW_FINISH = (
    "let e=JCe?JCe.subtractThenAdd(t,a,o):Buffer.alloc(128);"
    "/* dsh-ios +ios9: degrade gracefully without WASM */"
)


def main(argv):
    if len(argv) != 2:
        print("用法: apply_im_patches.py <node_modules 目录>", file=sys.stderr)
        return 1
    target = Path(argv[1]) / REL
    if not target.is_file():
        print(f"找不到 dsh-im 主体: {target}", file=sys.stderr)
        return 1

    text = target.read_text(encoding="utf-8")
    for label, old, new in (
        ("顶层 JCe 单例", OLD_TOP, NEW_TOP),
        ("history-sync finish", OLD_FINISH, NEW_FINISH),
    ):
        count = text.count(old)
        if count != 1:
            print(f"[FAIL] {label}: 期望恰好 1 处，实际 {count} 处 —— 拒绝打坏包", file=sys.stderr)
            return 1
        text = text.replace(old, new, 1)
        print(f"[ ok ] {label} 已打补丁")

    target.write_text(text, encoding="utf-8")
    print("dsh-im 零 JIT / 无 WASM 兼容补丁全部应用。")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
