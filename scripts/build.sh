#!/usr/bin/env bash
#
# 在本地 Linux（或 WSL）整条链路构建。
#
#   ./scripts/build.sh                 # 完整构建
#   ./scripts/build.sh --deps          # 先装宿主依赖（需要 sudo）
#   ./scripts/build.sh --keep           # 复用已有 work/firmware 检出
#
# 磁盘需求：约 12~15 GB（工具链 + Buildroot 输出）。
# 耗时：8 核约 40~80 分钟，首次更久（要下工具链和内核源码）。
#
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
project=$(cd "$here/.." && pwd)

FW_REPO="${FW_REPO:-https://github.com/OpenIPC/firmware}"
PINNED_SHA="9f0639eb9f5ad7cdc4380135cbcf658f345038f6"
BOARD="hi3518ev300_fpv_wfbng"
WORK="${WORK:-$project/work}"
FW="$WORK/firmware"
# 下载缓存放在 work/dl，独立于被反复解包的上游树，重跑构建时可直接复用
# 工具链（98.5 MB）与内核源码。CI 那边也用同一个变量做 actions/cache。
DL="${DL:-$WORK/dl}"

DO_DEPS=0
KEEP=0
for a in "$@"; do
	case "$a" in
		--deps) DO_DEPS=1 ;;
		--keep) KEEP=1 ;;
		-h|--help) sed -n '2,12p' "$0"; exit 0 ;;
		*) echo "未知参数: $a" >&2; exit 2 ;;
	esac
done

say() { echo "[build] $*"; }
nproc_hint=$(nproc 2>/dev/null || echo 4)

# ---- 宿主依赖 --------------------------------------------------------------
if [ "$DO_DEPS" -eq 1 ]; then
	say "安装宿主依赖（sudo）..."
	sudo apt-get update
	sudo apt-get install -y automake autotools-dev bc build-essential cpio \
		curl file fzf git libncurses-dev libtool lzop make rsync unzip wget \
		libssl-dev python3 python3-pip
	python3 -m pip install --user --break-system-packages kconfiglib || true
fi

for t in git make python3 gcc; do
	command -v "$t" >/dev/null || { echo "缺工具: $t（试试 --deps）" >&2; exit 1; }
done

# ---- 取上游 ----------------------------------------------------------------
mkdir -p "$WORK"
if [ -d "$FW/.git" ] && [ "$KEEP" -eq 1 ]; then
	say "复用已有检出 $FW"
else
	rm -rf "$FW"
	say "克隆 $FW_REPO ..."
	git clone "$FW_REPO" "$FW"
fi

say "检出 ${PINNED_SHA:0:7} ..."
git -C "$FW" fetch --depth 1 origin "$PINNED_SHA" 2>/dev/null || true
git -C "$FW" checkout -q "$PINNED_SHA"

# ---- 铺 overlay ------------------------------------------------------------
"$here/apply-overlay.sh" "$FW"

# ---- 构建 ------------------------------------------------------------------
mkdir -p "$DL"
say "下载缓存: $DL（当前 $(du -sh "$DL" 2>/dev/null | cut -f1 || echo 0)）"
say "开始构建（$(nproc 2>/dev/null || echo '?') 线程）..."
cd "$FW"
# 记录完整日志，方便失败后定位
set -o pipefail
make "BOARD=$BOARD" "BR2_DL_DIR=$DL" 2>&1 | tee "$WORK/build.log"

say "下载缓存现有 $(du -sh "$DL" 2>/dev/null | cut -f1 || echo 0)（重跑构建时会自动复用）"

# ---- 产物 ------------------------------------------------------------------
say "产物清单:"
find output/images -maxdepth 1 -type f -printf '  %10s  %p\n' 2>/dev/null | sort -k2

( cd output/images && sha256sum ./* > SHA256SUMS 2>/dev/null && say "已写 output/images/SHA256SUMS" ) || true

cat <<EOF

[build] 完成。
  镜像目录: $FW/output/images/
  构建日志: $WORK/build.log
  密钥指纹: $(cat "$project/keys/PUBKEYS.txt" | grep -E 'fp ' | tr '\n' ' ')

刷机前务必核对 drone/gs 指纹一致，否则图传收到的是雪花。
EOF
