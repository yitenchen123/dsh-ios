#!/usr/bin/env python3
"""构建期把 Safari 16.7 兼容垫片固化进 dsh web 前端（幂等）。

用法: inject_safari16.py <dsh-web-frontend/dist 目录> <polyfill 源文件>

- 把 polyfill 复制成 dist/assets/safari16-polyfill.js
- 在 dist/index.html 的 <head> 内、所有 <script type="module"> 之前插入
  一个普通 <script src>（同步执行；module 默认 defer，故必然先加载垫片）
- 重复执行不会重复插入

背景：iPhone X (A11) 只能停在 iOS 16.7 / WebKit Safari 16.6，缺少
AbortSignal.any / Promise.withResolvers / Object.groupBy / Map.groupBy /
Array.fromAsync（均为 Safari 17.4+）。dsh 前端运行时动态加载的插件
client.js 会调用它们，浏览器里直接抛 "AbortSignal.any is not a function"。
这是浏览器 WebKit 版本问题，与后端 node / 越狱 / .deb 无关。
iOS 上换任何浏览器都无效（强制系统 WebKit）。
"""
import sys
import shutil
import re
from pathlib import Path

MARK = "safari16-polyfill.js"


def main() -> int:
    if len(sys.argv) != 3:
        print("用法: inject_safari16.py <dist 目录> <polyfill 源文件>", file=sys.stderr)
        return 1
    dist = Path(sys.argv[1])
    src = Path(sys.argv[2])
    index = dist / "index.html"
    assets = dist / "assets"
    if not index.is_file():
        print(f"找不到 {index}", file=sys.stderr)
        return 1
    if not src.is_file():
        print(f"找不到 {src}", file=sys.stderr)
        return 1

    assets.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(src, assets / MARK)
    print(f"    + assets/{MARK} ({src.stat().st_size} 字节)")

    html = index.read_text(encoding="utf-8")
    if MARK in html:
        print("    = index.html 已注入过，跳过")
        return 0
    tag = f'    <script src="./assets/{MARK}"></script>'
    new, n = re.subn(r"(<head(?:\s[^>]*)?>)", lambda m: m.group(1) + "\n" + tag, html, count=1)
    if n != 1:
        print("index.html 找不到 <head> 标签", file=sys.stderr)
        return 1
    index.write_text(new, encoding="utf-8")
    print("    + index.html 注入垫片引用（<head> 内, module 之前）")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
