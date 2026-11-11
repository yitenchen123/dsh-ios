#!/bin/sh
# bootstrap.sh —— 让任何人 clone 本仓库后都能 1:1 重建出与本地一致的 deb
#
# 背景：本仓库 .gitignore 排除了三个超过 GitHub 单文件 100MB 限制、或属于
# 构建产物的大文件：
#   bundles/node-v22.12.0-iphoneos-arm64        (101MB, iOS arm64 Node 二进制)
#   bundles/dsh-nodemodules-*.tar.gz            ( 88MB, 已验证的离线依赖树)
#   dist/*.deb                                 (125MB, 由 build.sh 产出，无需下载)
# 它们作为 Release 附件公开。本脚本按 SHA-256 硬校验下载并放回 bundles/，
# 之后 sh build.sh 即可完全离线、字节级可复现地重建 +ios15 deb。
#
# 用法: sh bootstrap.sh                # 缺什么补什么（已存在且校验通过则跳过）
#       sh bootstrap.sh --force        # 强制重下（清空断点续传缓存）
#       sh bootstrap.sh --check        # 只校验本地文件，不联网
#       DSH_VER=0.2.2-rc.1 sh bootstrap.sh   # 下载 0.2.2-rc.1 升级包所需 bundle
#       DSH_ASSET_BASE_URL=https://mirror.example/releases/download sh bootstrap.sh
#                                       # 用镜像/代理源代替 GitHub（弱网/被墙时）
#
# 断点续传: 下载中断会留下 bundles/<name>.download，重跑本脚本即从断点继续，
#           不会从头重下 101MB。GitHub Release 已实测支持 Range（HTTP 206）。
#
# 依赖: curl 或 wget, sha256sum（或 shasum）
# 网络: 默认仅访问 github.com / release-assets.githubusercontent.com
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
B="$ROOT/bundles"

# 稳定的附件来源 tag。这两个附件的【内容永不随 +iosXX 轮次变化】：
# node 二进制是 A11 唯一能跑的 22.12.0；依赖树是打补丁前的原始 0.2.1-rc.5。
# +ios15 的补丁由 build.sh 在解包后确定性应用，不需要重新生成 bundle。
ASSET_REPO="${DSH_ASSET_REPO:-yitenchen123/dsh-ios}"
# 允许整体覆盖下载源（镜像/反代/本地自建源），路径需与 GitHub 的
# /releases/download/<tag>/<asset> 结构一致。
ASSET_BASE="${DSH_ASSET_BASE_URL:-https://github.com/${ASSET_REPO}/releases/download}"
# node 二进制是 A11 唯一能跑的 22.12.0，内容与 +iosXX 轮次无关，固定在旧 tag。
NODE_TAG="${DSH_NODE_TAG:-v0.2.1-rc.5+ios14}"

# 构建版本 → 对应依赖树 bundle 与它所在的 Release tag。
# 两个 bundle 都是「官方原始源码 + 2 个纯 JS addon shim + 0 个 .node」，
# 补丁由 build.sh 在解包后确定性应用，所以内容不会随 +iosXX 轮次变化。
DSH_VER="${DSH_VER:-0.2.1-rc.5}"
case "$DSH_VER" in
    0.2.1-rc.5)
        BUNDLE_NAME="dsh-nodemodules-0.2.1-rc.5+ios1.tar.gz"
        BUNDLE_SIZE="88421378"
        BUNDLE_SHA="b69675d9a8ac51a844051c24a3132d05bdd57d015ca2cd4bf9e815a04174c55c"
        BUNDLE_TAG="${DSH_BUNDLE_TAG:-v0.2.1-rc.5+ios14}" ;;
    0.2.2-rc.1)
        BUNDLE_NAME="dsh-nodemodules-0.2.2-rc.1+ios1.tar.gz"
        BUNDLE_SIZE="90992091"
        BUNDLE_SHA="c21c84efbbab551b70a90516034a96aff74ad019068a9f855e8eb63dda54caa0"
        BUNDLE_TAG="${DSH_BUNDLE_TAG:-v0.2.2-rc.1+ios16}" ;;
    *) echo "不支持的 DSH_VER: $DSH_VER（可用 0.2.1-rc.5 / 0.2.2-rc.1）" >&2; exit 1 ;;
esac

NODE_NAME="node-v22.12.0-iphoneos-arm64"
NODE_SIZE="101297040"
NODE_SHA="f091585d9e3d63b2d8be1fadc17068a21d42d6b2912304462b8dca41a8cfc163"

MODE="${1:-install}"
[ "$MODE" = "--force" ] || [ "$MODE" = "--check" ] || [ "$MODE" = "install" ] || [ "$MODE" = "" ] || {
    echo "未知参数: $MODE（可用 --force / --check）" >&2; exit 1; }

# URL 里 '+' 必须编码成 %2B，否则 GitHub 返回 404。每个附件可有独立 tag。
NODE_TAG_ENC=$(printf '%s' "$NODE_TAG" | sed 's/+/%2B/g')
BUNDLE_TAG_ENC=$(printf '%s' "$BUNDLE_TAG" | sed 's/+/%2B/g')

sha() { # 跨平台 sha256
    if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1
    elif command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | cut -d' ' -f1
    else echo "缺少 sha256sum/shasum" >&2; exit 1; fi
}

verify_one() { # name size sha dest
    _name="$1"; _size="$2"; _want="$3"; _dest="$4"
    [ -f "$_dest" ] || return 1
    _sz=$(stat -c%s "$_dest" 2>/dev/null || stat -f%z "$_dest" 2>/dev/null || echo 0)
    [ "$_sz" = "$_size" ] || { echo "    $_name 大小不符 ($_sz/$_size)"; return 1; }
    _got=$(sha "$_dest")
    [ "$_got" = "$_want" ] || { echo "    $_name SHA-256 不符"; return 1; }
    return 0
}

fsize() { stat -c%s "$1" 2>/dev/null || stat -f%z "$1" 2>/dev/null || echo 0; }

download_one() { # name size sha dest tag_enc
    _name="$1"; _size="$2"; _want="$3"; _dest="$4"; _tag_enc="$5"
    _url="${ASSET_BASE}/${_tag_enc}/${_name}"
    # 固定临时文件名：中断后重跑能续传，不再用 $$ 每次换名导致进度丢失。
    _tmp="${_dest}.download"
    echo "    下载 $_name ($_size 字节) ..."
    echo "    $_url"
    [ "$MODE" = "--force" ] && rm -f "$_tmp"

    # GitHub Release 实测返回 HTTP 206 / accept-ranges: bytes。外层循环反复
    # 调用 `curl -C -`（或 wget -c），每次重新计算断点偏移；单层 curl --retry
    # 不会更新偏移，故不能只靠 --retry。40 次仍不完整就保留 .download 退出，
    # 用户重跑本脚本即可继续，不会丢已下字节。
    _tries=0
    while :; do
        _have=$(fsize "$_tmp")
        [ "$_have" -ge "$_size" ] && break
        _tries=$((_tries+1))
        [ "$_tries" -gt 1 ] && echo "    续传：已有 $_have/$_size 字节（第 $_tries 次尝试）"
        if command -v curl >/dev/null 2>&1; then
            curl -fSsL -C - --connect-timeout 20 --max-time 300 \
                 --retry 1 --retry-delay 2 -o "$_tmp" "$_url" || true
        elif command -v wget >/dev/null 2>&1; then
            wget -q -c -O "$_tmp" "$_url" || true
        else
            echo "缺少 curl/wget" >&2; exit 1
        fi
        _now=$(fsize "$_tmp")
        [ "$_now" -ge "$_size" ] && break
        if [ "$_tries" -ge 40 ]; then
            echo "    [FAIL] $_name 多次中断（$_now/$_size 字节）" >&2
            echo "    已保留 $_tmp；重新运行 sh bootstrap.sh 会从断点继续。" >&2
            exit 1
        fi
    done
    mv "$_tmp" "$_dest"
    if ! verify_one "$_name" "$_size" "$_want" "$_dest"; then
        echo "    [FAIL] $_name 下载后校验不通过，已删除（重跑将重新下载）" >&2
        rm -f "$_dest"; exit 1
    fi
    echo "    [ ok ] $_name 校验通过 (SHA ${_want})"
}

mkdir -p "$B"
FAIL=0
for spec in "$NODE_NAME|$NODE_SIZE|$NODE_SHA|$B/$NODE_NAME|$NODE_TAG_ENC" \
            "$BUNDLE_NAME|$BUNDLE_SIZE|$BUNDLE_SHA|$B/$BUNDLE_NAME|$BUNDLE_TAG_ENC"; do
    IFS='|' read -r name size want dest tag_enc <<EOF
$spec
EOF
    echo "==> $name"
    if [ "$MODE" = "--check" ]; then
        if verify_one "$name" "$size" "$want" "$dest"; then echo "    [ ok ] 本地文件校验通过"; else echo "    [FAIL] 本地文件缺失或校验失败"; FAIL=$((FAIL+1)); fi
        continue
    fi
    if [ "$MODE" != "--force" ] && verify_one "$name" "$size" "$want" "$dest"; then
        echo "    [ == ] 已存在且校验通过，跳过"
        continue
    fi
    download_one "$name" "$size" "$want" "$dest" "$tag_enc"
done

# pnpm 是纯 JS、已被 git 跟踪，但要确认关键文件在
if [ ! -f "$B/pnpm/bin/pnpm.cjs" ] || [ ! -f "$B/pnpm/dist/pnpm.cjs" ]; then
    echo "[FAIL] 缺 bundles/pnpm（应随 git 一起 clone 下来），请检查仓库完整性" >&2
    FAIL=$((FAIL+1))
fi

if [ "$FAIL" -ne 0 ]; then
    echo "==> bootstrap 有 $FAIL 项未通过" >&2; exit 1
fi
echo "==> bootstrap 完成：大文件齐备且 SHA-256 全部匹配。现在可执行 sh build.sh"
