#!/usr/bin/env python3
"""
apply_compat_patches.py — 给 dsh 依赖树打「Node 22.12 兼容补丁」。

背景：本包内置的 node 是 v22.12.0（iPhone X / A11 真机验证过的标准 JIT 构建），
比 dsh 0.2.1-rc.5 假设的 Node 版本略旧，缺几个较晚才加入的语言/内置 API。
这些缺失会在 ESM 模块「链接期」直接抛 SyntaxError / 静默退出，运行时 shim
补不了（syncBuiltinESMExports 只能同步已有导出，加不了新的具名导出，已实测），
所以必须在构建时对源码做精确替换。

四处补丁（均在 x86 Linux 上按 iOS 目录布局实测通过）：

  1) @deepseek-ai/dsh/lib/bin.js
     import.meta.main 在 Node 22.14+ 才有；22.12 恒为 false，导致 `--version`
     和所有命令静默退出（rc=0 无输出）。bin.js 本来就只作为 CLI 入口执行，
     直接无条件调用 runCli() 即可。

  2) @deepseek-ai/dsh-session-persistence-jsonl/lib/index.js
     node:zlib 的 zstd 系列（createZstdCompress / zstdCompress 等）在 Node 22.15+
     才有。改为静态 `import * as zlibImpl`，缺失时降级到签名一一对应的 gzip 族。
     注意：这只能让「写」跑通，不能让「读」跑通 —— 见第 4 条。

  3) @deepseek-ai/dsh-ptc-runtime-node/lib/index.js
     node:module 的 stripTypeScriptTypes 在 Node 22.13+ 才有。改为动态取值，
     缺失时直通（PTC 源在本构建里是纯 JS，无需剥离类型）。

  4) @deepseek-ai/dsh-session-persistence-jsonl/lib/index.js（+ios8）
     把 DEFAULT_COMPRESSION 从 "zstd" 改成 "none"，会话日志走明文 JSONL。
     这是 +ios2~+ios7 一个真实缺陷的根治：第 2 条把 zstd API 降级成 gzip 后，
     写出的帧头是 gzip 的 1f 8b，但读路径的 scanZstdFrames() 仍强制校验
     ZSTD_MAGIC (0xFD2FB528)，于是「重启 DSH 后上一次对话不保留」——
     实际是会话文件写得出、读不回，报 corrupt Zstandard session log。
     改成 none 后读写都走 SessionLogScanner 明文分支，完全绕开 zstd/gzip，
     Node 22.12 自洽。明文体积约压缩版的 3 倍，但省掉解压 CPU，且更好排查。
     仍与桌面端 dsh（zstd）的会话文件不互通，iOS 端本地自洽。

用法：apply_compat_patches.py <node_modules 目录>
退出码：0=全部命中并替换；1=任一模式未命中（构建必须中止，绝不静默打坏包）。
"""
import sys
from pathlib import Path

OLD_BIN = "if (import.meta.main) await runCli();"
NEW_BIN = "await runCli();"

OLD_ZSTD = (
    'import { constants, createZstdCompress, createZstdDecompress, '
    'zstdCompress, zstdDecompress, zstdDecompressSync } from "node:zlib";'
)
NEW_ZSTD = '''import * as zlibImpl from "node:zlib";
// dsh-iOS compat (Node 22.12): zstd landed in 22.15. Degrade to gzip; stream/cb/sync
// signatures match 1:1. Session logs from this build use gzip framing, not zstd.
const { constants } = zlibImpl;
const createZstdCompress = zlibImpl.createZstdCompress ?? zlibImpl.createGzip;
const createZstdDecompress = zlibImpl.createZstdDecompress ?? zlibImpl.createGunzip;
const zstdCompress = zlibImpl.zstdCompress ?? zlibImpl.gzip;
const zstdDecompress = zlibImpl.zstdDecompress ?? zlibImpl.gunzip;
const zstdDecompressSync = zlibImpl.zstdDecompressSync ?? zlibImpl.gunzipSync;'''

OLD_TS = 'import { stripTypeScriptTypes } from "node:module";'
NEW_TS = '''import * as nodeModuleImpl from "node:module";
// dsh-iOS compat (Node 22.12): stripTypeScriptTypes landed in 22.13.
// PTC sources in this build are plain JS; pass through when unavailable.
const stripTypeScriptTypes = nodeModuleImpl.stripTypeScriptTypes ?? ((src) => src);'''

# +ios8：默认压缩改明文。必须与上面的 zlib 降级配套，否则写 gzip / 读 zstd 魔数。
OLD_COMPRESSION = 'const DEFAULT_COMPRESSION = "zstd";'
NEW_COMPRESSION = 'const DEFAULT_COMPRESSION = "none";'

# 每项：(相对路径, 原始串, 替换串, 说明, 补丁后独有的幂等标记)
# marker 用于在「同一棵树被重复打补丁」时判定「已应用」而非「锚点漂移」。
# 只有 old 命中 0 次且 marker 也不存在时才判定为依赖树变化并中止构建。
PATCHES = [
    ("@deepseek-ai/dsh/lib/bin.js", OLD_BIN, NEW_BIN, "import.meta.main",
     "await runCli();"),
    ("@deepseek-ai/dsh-session-persistence-jsonl/lib/index.js", OLD_ZSTD, NEW_ZSTD, "zstd→gzip",
     "// dsh-iOS compat (Node 22.12): zstd landed in 22.15."),
    ("@deepseek-ai/dsh-ptc-runtime-node/lib/index.js", OLD_TS, NEW_TS, "stripTypeScriptTypes",
     "// dsh-iOS compat (Node 22.12): stripTypeScriptTypes landed in 22.13."),
    ("@deepseek-ai/dsh-session-persistence-jsonl/lib/index.js", OLD_COMPRESSION, NEW_COMPRESSION, "会话默认压缩 zstd→none",
     'const DEFAULT_COMPRESSION = "none";'),
]


def main() -> int:
    if len(sys.argv) != 2:
        print("用法: apply_compat_patches.py <node_modules 目录>", file=sys.stderr)
        return 1
    nm = Path(sys.argv[1])
    if not nm.is_dir():
        print(f"node_modules 不存在: {nm}", file=sys.stderr)
        return 1

    ok = True
    for rel, old, new, label, marker in PATCHES:
        target = nm / rel
        if not target.is_file():
            print(f"  [FAIL] {label}: 目标文件不存在 {target}", file=sys.stderr)
            ok = False
            continue
        text = target.read_text(encoding="utf-8")
        count = text.count(old)
        if count == 0 and marker in text:
            # 同一棵树被重复打补丁（热修 / 二次构建）：补丁已在，安全跳过。
            print(f"  [ == ] {label}: 已存在（幂等跳过）: {rel}")
            continue
        if count != 1:
            print(
                f"  [FAIL] {label}: 期望精确命中 1 次，实际 {count} 次 ({rel})。"
                " 依赖树版本可能已变化，拒绝继续，以免打出未经验证的包。",
                file=sys.stderr,
            )
            ok = False
            continue
        target.write_text(text.replace(old, new, 1), encoding="utf-8")
        print(f"  [ OK ] {label}: {rel}")

    if not ok:
        print("兼容补丁未全部应用，构建中止。", file=sys.stderr)
        return 1
    print("四处 Node 22.12 兼容补丁全部应用。")
    return 0


if __name__ == "__main__":
    sys.exit(main())
