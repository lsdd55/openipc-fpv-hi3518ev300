#!/bin/sh
#
# 把本项目的 overlay 铺到一份 OpenIPC/firmware 检出上。
#
#   ./scripts/apply-overlay.sh /path/to/openipc-firmware
#
# 幂等：重复执行结果一致。任何一步不符合预期都会非零退出，
# 不会留下「看起来成功了但包没进 Kconfig」的半成品。
#
# 刻意写成 POSIX sh（不用 BASH_SOURCE、不用 pipefail），
# 这样 dash / busybox ash / bash 都能跑，CI 的 shell 测试也能直接跑它。
#
set -eu

self=$0
here=$(cd "$(dirname "$self")" && pwd)
project=$(cd "$here/.." && pwd)
overlay="$project/overlay"

[ -d "$overlay" ] || { echo "ERROR: 找不到 overlay 目录 $overlay" >&2; exit 1; }

# 上游提交，与 build.sh / .github/workflows/build.yml 保持一致
PINNED_SHA="9f0639eb9f5ad7cdc4380135cbcf658f345038f6"
BOARD="hi3518ev300_fpv_wfbng"

die() { echo "ERROR: $*" >&2; exit 1; }
say() { echo "[apply] $*"; }

fw=${1:-}
[ -n "$fw" ] || die "用法: $0 <openipc-firmware 目录>"
[ -d "$fw" ] || die "目录不存在: $fw"

# ---- 0. 确认这是一份 OpenIPC 固件树 ----------------------------------------
[ -f "$fw/general/package/Config.in" ] \
	|| die "$fw 不像 OpenIPC/firmware 检出（缺 general/package/Config.in）"
[ -d "$fw/br-ext-chip-hisilicon/configs" ] \
	|| die "$fw 缺 br-ext-chip-hisilicon/configs"

# ---- 1. 版本校验（只警告，不阻断）------------------------------------------
# 注意：这里不能用 ${var:0:7} —— 那是 bash 专有的子串展开，本脚本是
# #!/bin/sh，在 dash / busybox ash 下会直接 "Bad substitution" 退出。
# `sh -n` 只查语法，查不出这种运行时才炸的写法。用 printf 截前 7 位。
if have=$(git -C "$fw" rev-parse HEAD 2>/dev/null); then
	if [ "$have" = "$PINNED_SHA" ]; then
		say "上游提交匹配: $(printf '%.7s' "$have")"
	else
		say "警告: 上游提交为 $(printf '%.7s' "$have")，本项目按 $(printf '%.7s' "$PINNED_SHA") 验证"
		say "      若构建报错，先执行 git -C $fw checkout $PINNED_SHA 再看"
	fi
else
	say "警告: $fw 不是 git 仓库，无法校验版本"
fi

# ---- 2. 铺文件 -------------------------------------------------------------
# overlay/ 的目录结构直接对应 firmware 仓库根目录
say "复制 overlay ..."
cp -a "$overlay/." "$fw/"

# ---- 3. 注册新包到 Kconfig ------------------------------------------------
say "修补 general/package/Config.in（上游缺陷：yaml-cli-multi 未被 source）..."
python3 "$here/patch-config-in.py" "$fw/general/package/Config.in"

# ---- 4. 断言 ---------------------------------------------------------------
fail=0
chk() { if eval "$2"; then say "OK   $1"; else echo "FAIL $1" >&2; fail=1; fi; }

chk "defconfig hi3518ev300_fpv_wfbng" \
	"test -f '$fw/br-ext-chip-hisilicon/configs/${BOARD}_defconfig'"
chk "defconfig hi3518ev300_apfpv（AP 推流）" \
	"test -f '$fw/br-ext-chip-hisilicon/configs/hi3518ev300_apfpv_defconfig'"
chk "apfpv 包已就位" \
	"test -f '$fw/general/package/apfpv/apfpv.mk'"
chk "apfpv 已进 Kconfig（恰好 1 次）" \
	"test \$(grep -c 'apfpv/Config.in' '$fw/general/package/Config.in') -eq 1"
# 上游缺陷修复：yaml-cli-multi 的 Config.in 存在且被 wifibroadcast-ng select，
# 但上游 general/package/Config.in 里没有 source 行，导致该二进制从不进镜像。
chk "yaml-cli-multi 已注册（修上游缺陷）" \
	"test \$(grep -c 'yaml-cli-multi/Config.in' '$fw/general/package/Config.in') -eq 1"
chk "drone.key 为 64 字节" \
	"test \$(stat -c %s '$fw/general/package/wifibroadcast-ng/files/drone.key') -eq 64"
chk "wfb.yaml 含 mcs_index: 1" \
	"grep -q 'mcs_index: 1$' '$fw/general/package/wifibroadcast-ng/files/wfb.yaml'"
chk "视频剖面进了 rootfs overlay" \
	"test -f '$fw/general/overlay/etc/fpv-video.conf'"
chk "defconfig 里 variant 含 fpv" \
	"grep -q 'BR2_OPENIPC_VARIANT=\"fpv\"' '$fw/br-ext-chip-hisilicon/configs/${BOARD}_defconfig'"

[ "$fail" -eq 0 ] || die "断言失败，见上方 FAIL 行"

# ---- 5. 提示 ---------------------------------------------------------------
cat <<EOF

[apply] 完成。下一步：

    cd $fw
    make BOARD=$BOARD            # 或先 make deps 装宿主依赖
    产物: output/images/

drone.key / gs.key 的指纹见本项目 keys/PUBKEYS.txt，请核对后再飞。
EOF
