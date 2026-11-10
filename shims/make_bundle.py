#!/usr/bin/env python3
"""
make_bundle.py —— 从一份 npm/pnpm 装好的 node_modules 生成「字节级可复现」的
dsh iOS 离线依赖树 bundle（tar.gz）。

为什么需要它（用户要求：不管 GitHub 仓库多大，别人写构建脚本都能 1:1 重建
出和本地一样的产物）：
  * build.sh 原来依赖 bundles/*.tar.gz，但那个文件被 .gitignore 排除，
    别人 clone 后 build.sh 第一步就失败。
  * 本脚本把「依赖树 -> 裁剪 -> 打补丁 -> 确定性打包」全部固化进仓库：
    只要输入 node_modules 相同（由 package-lock.json 精确锁定），
    任何人生成的 bundle SHA-256 都完全一致。
  * tar 成员按路径排序、统一 mtime/uid/gid/uname/gname、gzip mtime=0，
    因此 tar.gz 本身也是可复现的。

用法:
  python3 make_bundle.py <node_modules 目录> <输出 tar.gz> [--version VER]
退出码: 0 成功；1 输入非法或校验失败。
"""
import gzip
import io
import os
import stat
import sys
import tarfile
from pathlib import Path

# 固定时间戳（与 build.sh 的 SOURCE_DATE_EPOCH 一致），保证跨机器一致
EPOCH = 1700000000

# 与 build.sh 回退分支完全一致的裁剪规则
DROP_SUFFIX = ('.node', '.d.ts', '.map', '.d.cts', '.d.mts')
DROP_DIRS = {'test', 'tests', '__tests__', 'docs', '.github', 'prebuilds'}
DROP_NAMES = ('readme', 'changelog')
DROP_DIR_PREFIXES = (
    '@deepseek-ai/node-addon-system-', '@img', '@koromix',
    'sherpa-onnx-', 'node-pty',
)


def keep_file(rel: str) -> bool:
    low = rel.lower()
    if low.endswith(DROP_SUFFIX):
        return False
    base = rel.rsplit('/', 1)[-1].lower()
    if base.startswith(DROP_NAMES) and (base.endswith('.md') or '.' not in base[len(base.rstrip('0123456789.')):]):
        # 宽松匹配 readme*/changelog*（含无扩展名）
        if any(base.startswith(n) for n in DROP_NAMES):
            return False
    parts = rel.split('/')
    for p in parts[:-1]:
        if p in DROP_DIRS:
            return False
    # 平台原生包整目录剔除（顶层 node_modules/<name>）
    if len(parts) >= 2 and parts[0] == 'node_modules':
        seg = '/'.join(parts[1:2])
        if seg.startswith(DROP_DIR_PREFIXES):
            return False
    return True


def collect(root: Path):
    """返回排序后的 (arcname, realpath) 列表。"""
    out = []
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames.sort()
        filenames.sort()
        rel_dir = os.path.relpath(dirpath, root.parent)  # 含 node_modules/ 前缀
        for fn in filenames:
            full = Path(dirpath) / fn
            if full.is_symlink():
                continue
            arc = rel_dir.replace(os.sep, '/') + '/' + fn
            if not keep_file(arc):
                continue
            out.append((arc, str(full)))
    out.sort(key=lambda x: x[0])
    return out


def main() -> int:
    if len(sys.argv) < 3:
        print('用法: make_bundle.py <node_modules 目录> <输出 tar.gz>', file=sys.stderr)
        return 1
    nm = Path(sys.argv[1])
    dest = Path(sys.argv[2])
    if not nm.is_dir():
        print(f'node_modules 不存在: {nm}', file=sys.stderr)
        return 1

    members = collect(nm)
    if not members:
        print('裁剪后为空，拒绝生成。', file=sys.stderr)
        return 1

    # 先写未压缩 tar 到内存，再用 mtime=0 的 gzip 包装（gzip 头不带时间戳/文件名）
    raw = io.BytesIO()
    with tarfile.open(fileobj=raw, mode='w', format=tarfile.GNU_FORMAT) as tf:
        for arc, full in members:
            st = os.lstat(full)
            ti = tarfile.TarInfo(name=arc)
            ti.size = st.st_size
            ti.mtime = EPOCH
            ti.mode = 0o644 if stat.S_ISREG(st.st_mode) else 0o755
            ti.uid = 0
            ti.gid = 0
            ti.uname = 'root'
            ti.gname = 'root'
            ti.type = tarfile.REGTYPE
            with open(full, 'rb') as f:
                tf.addfile(ti, f)
    data = raw.getvalue()

    dest.parent.mkdir(parents=True, exist_ok=True)
    with open(dest, 'wb') as out:
        gz = gzip.GzipFile(filename='', mode='wb', fileobj=out, mtime=0, compresslevel=9)
        gz.write(data)
        gz.close()

    import hashlib
    h = hashlib.sha256(dest.read_bytes()).hexdigest()
    print(f'  bundle: {dest.name}  成员 {len(members)}  体积 {dest.stat().st_size} 字节')
    print(f'  sha256: {h}')
    return 0


if __name__ == '__main__':
    sys.exit(main())
