#!/bin/sh
#
# 网卡识别逻辑的离线测试。
#
# 不需要真实硬件、不需要 root：用一个假的 lsusb 喂 VID:PID 进去，
# 验证 wifibroadcast 的 usb_ids / driver_of_pid 分支是否把每张卡
# 映射到正确的驱动模块名。
#
# 用法：  sh tests/detect-test.sh
#
set -u

here=$(cd "$(dirname "$0")" && pwd)
target="$here/../overlay/general/package/wifibroadcast-ng/files/wifibroadcast"

[ -f "$target" ] || { echo "找不到 $target" >&2; exit 1; }

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin"

# 假的 lsusb：把 $FAKE_IDS 里每个 ID 打成一行真实格式
cat > "$tmp/bin/lsusb" <<'EOF'
#!/bin/sh
i=0
for id in $FAKE_IDS; do
	i=$((i + 1))
	echo "Bus 001 Device 00$i: ID $id Fake Device Corp."
done
EOF
chmod +x "$tmp/bin/lsusb"

# 假 logger，避免污染输出
cat > "$tmp/bin/logger" <<'EOF'
#!/bin/sh
cat > /dev/null
EOF
chmod +x "$tmp/bin/logger"

fail=0
pass=0

ok()  { printf 'PASS  %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf 'FAIL  %s\n' "$1"; fail=$((fail + 1)); }

# 跑一遍 detect，输出全部行
run_detect() {
	PATH="$tmp/bin:$PATH" FAKE_IDS="$1" sh "$target" detect 2>/dev/null | grep -v '^$'
}

# 断言输出里存在某一整行
has_line() {
	desc=$1; ids=$2; want=$3
	if run_detect "$ids" | grep -Fxq "$want"; then
		ok "$desc"
	else
		bad "$desc  (期望包含 [$want])"
		run_detect "$ids" | sed 's/^/        实得: /'
	fi
}

# 断言输出里不存在某个 ID 的行
not_id() {
	desc=$1; ids=$2; unwanted=$3
	if run_detect "$ids" | grep -q "^$unwanted "; then
		bad "$desc  (不应出现 [$unwanted])"
	else
		ok "$desc"
	fi
}

echo "== 单卡识别 =="
has_line "8812AU  0bda:8812" "0bda:8812" "0bda:8812 -> 8812au"
has_line "8812AU  0bda:881a" "0bda:881a" "0bda:881a -> 8812au"
has_line "8812AU  0b05:17d2" "0b05:17d2" "0b05:17d2 -> 8812au"
has_line "8814AU（已移除）应报未知" "0bda:8813" "0bda:8813 -> 未知"
has_line "8814AU 2357:0106 应报未知" "2357:0106" "2357:0106 -> 未知"
has_line "8814AU 0846:9054 应报未知" "0846:9054" "0846:9054 -> 未知"
has_line "8812CU（已移除）应报未知" "0bda:c812" "0bda:c812 -> 未知"
has_line "8822CU（已移除）应报未知" "0bda:c82c" "0bda:c82c -> 未知"
has_line "8733BU  0bda:f72b" "0bda:f72b" "0bda:f72b -> 8733bu"
has_line "8733BU  0bda:b733" "0bda:b733" "0bda:b733 -> 8733bu"

echo
echo "== 大小写 =="
has_line "大写 0BDA:8812 应归一为小写" "0BDA:8812" "0bda:8812 -> 8812au"

echo
echo "== 混插：hub/未知设备不应影响已识别网卡 =="
has_line "hub 在前，网卡仍能认出" "1d6b:0002 0bda:f72b" "0bda:f72b -> 8733bu"
has_line "双卡并存，各自识别" "0bda:8812 0bda:f72b" "0bda:8812 -> 8812au"
has_line "双卡并存（第二张）" "0bda:8812 0bda:f72b" "0bda:f72b -> 8733bu"

echo
echo "== 未识别 =="
has_line "MT7921AU 应报未知" "0e8d:7961" "0e8d:7961 -> 未知"
has_line "hub 应报未知" "1d6b:0002" "1d6b:0002 -> 未知"

echo
echo "== 顺序：detect_driver 取第一个匹配（决定实际加载哪个驱动）=="
# 这条是 load_modules() 的真实行为：遍历 lsusb，第一个能映射到驱动的即胜出。
# 用 8812au 在前、8733bu 在后，期望先命中 8812au。
first=$(run_detect "0bda:8812 0bda:f72b" | grep -v '未知' | sed -n '1p')
case "$first" in
	"0bda:8812 -> 8812au") ok "首张受支持网卡优先: $first" ;;
	*)                     bad "首张受支持网卡优先，实得 [$first]" ;;
esac

echo
echo "----------------------------------------"
echo "通过 $pass 项，失败 $fail 项"
[ "$fail" -eq 0 ] || exit 1
