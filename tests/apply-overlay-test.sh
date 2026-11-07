#!/bin/sh
#
# apply-overlay.sh 的集成测试。
#
# 用一个"假的上游树"（只放脚本断言会检查的那几个文件）跑一遍，
# 验证：文件铺设、Kconfig 注册、以及全部断言。
#
# 真实构建前先跑这个，能在几秒内排掉"包没进 Kconfig"这类静默失败。
#
# 用法：  sh tests/apply-overlay-test.sh
#
set -u

here=$(cd "$(dirname "$0")" && pwd)
proj="$here/.."

fail=0
pass=0
ok()  { printf 'PASS  %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf 'FAIL  %s\n' "$1"; fail=$((fail + 1)); }

command -v python3 >/dev/null || { echo "需要 python3" >&2; exit 1; }

T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
FW="$T/firmware"

echo "== 构造假上游树 =="
mkdir -p "$FW/general/package" "$FW/br-ext-chip-hisilicon/configs"

# 模拟上游真实存在的包目录：patch-config-in.py 会检查目标 Config.in 是否存在，
# 不存在就拒绝插入悬空 source（这是防止上游重构后留下坏 Kconfig 的保护）。
# yaml-cli-multi 是上游真实存在的目录，也正是本项目要修的那个缺陷所在，
# 所以必须造出来，否则测的不是真实场景。
mkdir -p "$FW/general/package/yaml-cli-multi" "$FW/general/package/yaml-cli"
printf 'config BR2_PACKAGE_YAML_CLI_MULTI\n\tbool "Yaml parser"\n' \
	> "$FW/general/package/yaml-cli-multi/Config.in"
printf 'config BR2_PACKAGE_YAML_CLI\n\tbool "yaml-cli"\n' \
	> "$FW/general/package/yaml-cli/Config.in"

# 拿真实的上游 Config.in 作锚点（从上游仓库取；取不到就用最小替身）
CFG_IN="$proj/tests/fixtures/package-Config.in.min"
[ -f "$CFG_IN" ] || CFG_IN=""
if [ -n "$CFG_IN" ]; then
	cp "$CFG_IN" "$FW/general/package/Config.in"
	ok "使用 fixtures 里的上游 Config.in 样本"
else
	# 只保留 patch-config-in.py 需要的那一行锚点
	cat > "$FW/general/package/Config.in" <<'EOF'
source "$BR2_EXTERNAL_GENERAL_PATH/package/rtl8733bu-openipc/Config.in"
source "$BR2_EXTERNAL_GENERAL_PATH/package/rtl8811cu-openipc/Config.in"
source "$BR2_EXTERNAL_GENERAL_PATH/package/rtl8812au-openipc/Config.in"
source "$BR2_EXTERNAL_GENERAL_PATH/package/rtl88x2eu-openipc/Config.in"
source "$BR2_EXTERNAL_GENERAL_PATH/package/wifibroadcast-ng/Config.in"
EOF
	ok "使用最小替身 Config.in"
fi

echo
echo "== 跑 apply-overlay.sh =="
if sh "$proj/scripts/apply-overlay.sh" "$FW" > "$T/apply.log" 2>&1; then
	ok "apply-overlay.sh 退出码 0"
else
	bad "apply-overlay.sh 失败"
	sed 's/^/        /' "$T/apply.log"
fi

echo
echo "== 独立复核（不看脚本自己的输出）=="
chk() {
	desc=$1; shift
	if "$@" >/dev/null 2>&1; then ok "$desc"; else bad "$desc"; fi
}

chk "defconfig 已就位" \
	test -f "$FW/br-ext-chip-hisilicon/configs/hi3518ev300_fpv_wfbng_defconfig"
chk "wifibroadcast 运行时脚本已替换" \
	grep -q 'driver_of_pid' "$FW/general/package/wifibroadcast-ng/files/wifibroadcast"
chk "drone.key 为 64 字节" \
	test "$(wc -c < "$FW/general/package/wifibroadcast-ng/files/drone.key")" -eq 64
chk "fpv-video.conf 进了 rootfs overlay" \
	test -f "$FW/general/overlay/etc/fpv-video.conf"

# Kconfig 注册：各出现且仅出现一次
n3=$(grep -c 'yaml-cli-multi/Config.in' "$FW/general/package/Config.in")
[ "$n3" -eq 1 ] && ok "yaml-cli-multi 在 Kconfig 中恰好 1 次（修上游缺陷）" || bad "yaml-cli-multi 在 Kconfig 中出现 $n3 次"

echo
echo "== 幂等：再跑一次不应产生重复行 =="
sh "$proj/scripts/apply-overlay.sh" "$FW" > "$T/apply2.log" 2>&1 || true

echo
echo "----------------------------------------"
echo "通过 $pass 项，失败 $fail 项"
[ "$fail" -eq 0 ] || exit 1
