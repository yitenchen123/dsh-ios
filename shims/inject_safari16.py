#!/usr/bin/env python3
"""构建期把 Safari 16.7 兼容垫片 + iOS 手动安装转化逻辑固化进 dsh web 前端（幂等）。

用法: inject_safari16.py <dsh-web-frontend/dist 目录> <polyfill 源文件> [转化逻辑源文件]

- 把每个源文件复制成 dist/assets/<文件名>
- 在 dist/index.html 的 <head> 内、所有 <script type="module"> 之前插入
  普通 <script src>（同步执行；module 默认 defer，故必然先加载）
- 按【文件分别幂等】：老设备/旧包可能已注入过垫片但未注入 +ios15 转化逻辑，
  只补缺失的那个，绝不重复插入、也不跳过未注入的。

背景：iPhone X (A11) 只能停在 iOS 16.7 / WebKit Safari 16.6，缺少
AbortSignal.any / Promise.withResolvers / Object.groupBy / Map.groupBy /
Array.fromAsync 等 Safari 17.4+ API。dsh 前端运行时动态加载的插件
client.js 会调用它们，浏览器里直接抛 "AbortSignal.any is not a function"。
这是浏览器 WebKit 版本问题，与后端 node / 越狱 / .deb 无关。
iOS 上换任何浏览器都无效（强制系统 WebKit）。

+ios15 追加：dsh-ios-manual-install-transform.js 定义
window.__dshIosTransformSpec，只由 Web UI 手动安装对话框的 client.js 调用，
AI 帮你装（tools.js）与命令行（operations.js）都不经过，满足硬约束。
"""
import sys
import shutil
import re
from pathlib import Path


def main() -> int:
    if len(sys.argv) not in (3, 4):
        print("用法: inject_safari16.py <dist 目录> <polyfill 源文件> [转化逻辑源文件]", file=sys.stderr)
        return 1
    dist = Path(sys.argv[1])
    index = dist / "index.html"
    assets = dist / "assets"
    if not index.is_file():
        print(f"找不到 {index}", file=sys.stderr)
        return 1
    assets.mkdir(parents=True, exist_ok=True)

    # (源文件, 目标文件名)；顺序即 <head> 内 script 顺序：垫片先于转化逻辑
    jobs = [(Path(sys.argv[2]), "safari16-polyfill.js")]
    if len(sys.argv) == 4:
        jobs.append((Path(sys.argv[3]), "dsh-ios-manual-install-transform.js"))

    html = index.read_text(encoding="utf-8")
    tags = []
    for src, name in jobs:
        if not src.is_file():
            print(f"找不到 {src}", file=sys.stderr)
            return 1
        shutil.copyfile(src, assets / name)
        print(f"    + assets/{name} ({src.stat().st_size} 字节)")
        if name not in html:
            tags.append(f'    <script src="./assets/{name}"></script>')

    if not tags:
        print("    = index.html 两个引用都已存在，跳过")
        return 0

    # 插到 <head> 之后第一行；已存在的引用不重复，新引用按 jobs 顺序追加在
    # 已有 <script src="./assets/..."> 之后、任何 <script type="module"> 之前。
    block = "\n".join(tags)
    m = re.search(r"(<head(?:\s[^>]*)?>)", html)
    if not m:
        print("index.html 找不到 <head> 标签", file=sys.stderr)
        return 1
    new = html[:m.end()] + "\n" + block + html[m.end():]
    index.write_text(new, encoding="utf-8")
    print(f"    + index.html 注入 {len(tags)} 个引用（<head> 内, module 之前）")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
