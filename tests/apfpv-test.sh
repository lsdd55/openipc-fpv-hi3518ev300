#!/bin/sh
#
# apfpv 冒烟测试：用桩程序跑完整的 start 路径，验证控制流与生成的配置。
#
# 重点覆盖三处容易出错的地方：
#   1. USB ID → 驱动名 的映射（含未识别的情形）
#   2. 信道与 hw_mode 必须匹配，否则 hostapd 直接退出
#   3. 首次启动写视频剖面时**不能出现空值** —— FPV 那份脚本
#      的 reset 分支就在这里出过事（变量没赋值就写进 majestic）
#
# 用法：  sh tests/apfpv-test.sh
#
set -u

here=$(cd "$(dirname "$0")" && pwd)
proj="$here/.."
src="$proj/overlay/general/package/apfpv/files/apfpv"
[ -f "$src" ] || { echo "找不到 $src" >&2; exit 1; }

T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/etc" "$T/var/run" "$T/rom/etc" "$T/log" "$T/sys/net/wlan9"

fail=0
pass=0
ok()  { printf 'PASS  %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf 'FAIL  %s\n' "$1"; fail=$((fail + 1)); }

# ---- 1. 路径重定向 ---------------------------------------------------------
sed -e 's|/rom|@ROM@|g' \
    -e 's|/var/run|@RUNDIR@|g' \
    -e 's|/sys/class/net|@SYSNET@|g' \
    -e "s|/etc/|$T/etc/|g" \
    -e "s|@ROM@|$T/rom|g" \
    -e "s|@RUNDIR@|$T/var/run|g" \
    -e "s|@SYSNET@|$T/sys/net|g" \
	"$src" > "$T/apfpv"
chmod +x "$T/apfpv"

# ---- 2. 桩程序 -------------------------------------------------------------
mkstub() {
	name=$1
	cat > "$T/bin/$name" <<EOF
#!/bin/sh
echo "$name \$*" >> "$T/log/calls.log"
exit 0
EOF
	chmod +x "$T/bin/$name"
}

for n in modprobe ifconfig hostapd udhcpd killall iw pidof; do
	mkstub "$n"
done

# cli 单独一个桩：参数原样写进 cli.log（不带程序名前缀），
# 这样断言能直接匹配 "-s .video0.size 1920x1080"。
# 若混在 calls.log 里带上 "cli " 前缀，针对空值的正则 ^-s ... 会一条都匹配不到，
# 于是「没有空值」永远成立 —— 那种假通过比失败更糟。
cat > "$T/bin/cli" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >> "$T/log/cli.log"
echo "cli \$*" >> "$T/log/calls.log"
exit 0
EOF
chmod +x "$T/bin/cli"

# hostapd 桩要额外记录它收到的配置文件内容（-B <conf>）
cat > "$T/bin/hostapd" <<EOF
#!/bin/sh
echo "hostapd \$*" >> "$T/log/calls.log"
for a in "\$@"; do
	case "\$a" in
		-B) ;;
		-*) ;;
		*) [ -f "\$a" ] && cp "\$a" "$T/log/used-hostapd.conf" ;;
	esac
done
exit 0
EOF
chmod +x "$T/bin/hostapd"

cat > "$T/bin/logger" <<EOF
#!/bin/sh
msg=\$(cat)
printf '%s\n' "\$msg" >> "$T/log/messages.log"
printf '%s\n' "\$msg" >&2
exit 0
EOF
chmod +x "$T/bin/logger"

# lsusb：默认插着一张 RTL8812AU
cat > "$T/bin/lsusb" <<'EOF'
#!/bin/sh
echo "Bus 001 Device 001: ID 1d6b:0002 Linux Foundation 2.0 root hub"
echo "Bus 001 Device 002: ID 0bda:8812 Realtek 802.11ac NIC"
EOF
chmod +x "$T/bin/lsusb"

# ---- 3. 输入配置 -----------------------------------------------------------
cp "$proj/overlay/general/package/apfpv/files/apfpv.conf" "$T/etc/apfpv.conf"
# apfpv-video.conf 里 SENSOR_INI 是绝对路径，必须一并重定向到临时目录，
# 否则脚本的 [ -f ] 判断打在真实的 /etc 上，会静默走"自动探测"分支
sed -e "s|/etc/|$T/etc/|g" \
	"$proj/overlay/general/package/apfpv/files/apfpv-video.conf" > "$T/etc/apfpv-video.conf"
mkdir -p "$T/etc/sensors"
: > "$T/etc/sensors/jxf23_i2c_1080p.ini"

run() { PATH="$T/bin:$PATH" sh "$T/apfpv" "$@"; }

# ---------------------------------------------------------------- 识别
echo "== USB ID → 驱动名 =="
out=$(run detect 2>/dev/null)
case "$out" in
	*"0bda:8812 -> 8812au"*) ok "0bda:8812 -> 8812au" ;;
	*) bad "0bda:8812 未识别为 8812au：[$out]" ;;
esac

mk_lsusb() {
	cat > "$T/bin/lsusb" <<EOF
#!/bin/sh
printf '%s\n' "$1"
EOF
	chmod +x "$T/bin/lsusb"
}

mk_lsusb "Bus 001 Device 002: ID 0bda:f72b Realtek 802.11ac NIC"
out=$(run detect 2>/dev/null)
case "$out" in
	*"0bda:f72b -> 8733bu"*) ok "0bda:f72b -> 8733bu" ;;
	*) bad "0bda:f72b 未识别为 8733bu：[$out]" ;;
esac

mk_lsusb "Bus 001 Device 002: ID 0bda:c812 Realtek 802.11ac NIC"
out=$(run detect 2>/dev/null)
case "$out" in
	*"未知"*) ok "0bda:c812（8812CU，本固件不含）报未知" ;;
	*) bad "0bda:c812 竟被识别：[$out]" ;;
esac

mk_lsusb "Bus 001 Device 002: ID 0BDA:881A Realtek 802.11ac NIC"
out=$(run detect 2>/dev/null)
case "$out" in
	*"0bda:881a -> 8812au"*) ok "大写 0BDA:881A 归一为小写并识别" ;;
	*) bad "大写未归一：[$out]" ;;
esac

# ---------------------------------------------------------------- start
echo
echo "== start 全流程 =="
mk_lsusb "Bus 001 Device 002: ID 0bda:8812 Realtek 802.11ac NIC"
: > "$T/log/calls.log"
: > "$T/log/messages.log"
rm -f "$T/etc/system.ok"
run start > "$T/log/stdout.log" 2>&1
rc=$?
sleep 1

if [ "$rc" -eq 0 ]; then ok "start 退出码 0"; else
	bad "start 退出码 $rc"; sed 's/^/        /' "$T/log/stdout.log"
fi

LOG="$T/log/calls.log"
if grep -q '^modprobe -r 8812au' "$LOG"; then ok "先卸载候选驱动"; else bad "没有先卸载候选驱动"; fi
if grep -q '^modprobe 8812au' "$LOG"; then ok "按 VID:PID 加载 8812au"; else
	bad "未加载 8812au"; grep '^modprobe' "$LOG" | sed 's/^/        /'
fi
if grep -q '^ifconfig .* 192\.168\.4\.1 netmask 255\.255\.255\.0 up' "$LOG"; then
	ok "把热点地址配到接口上"
else
	bad "没有配 AP 地址"; grep '^ifconfig' "$LOG" | sed 's/^/        /'
fi

echo
echo "== 生成的 hostapd.conf =="
H="$T/log/used-hostapd.conf"
if [ -f "$H" ]; then
	ok "hostapd 收到了配置文件"
	grep -qx 'ssid=OpenIPC-AP' "$H" && ok "ssid 正确" || bad "ssid 不对"
	grep -qx 'channel=161' "$H" && ok "信道 161" || bad "信道不对"
	grep -qx 'hw_mode=a' "$H" && ok "hw_mode=a（5GHz）" || bad "hw_mode 不对"
	grep -qx 'wpa=2' "$H" && ok "WPA2 已开启" || bad "没有 WPA2"
	grep -q '^wpa_passphrase=' "$H" && ok "密码已写入" || bad "密码没写"
	grep -qx 'ieee80211ac=1' "$H" && ok "5GHz 下开了 11ac" || bad "5GHz 没开 11ac"
	grep -qx 'driver=nl80211' "$H" && ok "driver=nl80211" || bad "driver 不对"
else
	bad "hostapd 没收到配置文件"
fi

echo
echo "== DHCP 配置 =="
D=$(ls "$T"/var/run/udhcpd.conf 2>/dev/null)
if [ -n "$D" ]; then
	ok "生成了 udhcpd.conf"
	grep -qx 'start 192.168.4.10' "$D" && ok "地址池起点由 AP_IP 推得" || bad "地址池起点不对"
	grep -qx 'end 192.168.4.100' "$D" && ok "地址池终点正确" || bad "地址池终点不对"
	grep -qx 'interface wlan9' "$D" && ok "绑定到探测到的接口" || bad "接口绑定不对"
	grep -qx 'option router 192.168.4.1' "$D" && ok "下发了默认网关" || bad "没下发网关"
else
	bad "没生成 udhcpd.conf"
fi

echo
echo "== 视频剖面（首次启动必须写成具体值，不能为空）=="
CLI="$T/log/cli.log"
touch "$CLI"
# 先证明 cli 真的被调用过，否则下面针对空值的断言会在「一条都没有」时假通过
if [ -s "$CLI" ]; then ok "cli 被调用过（$(wc -l < "$CLI") 次）"; else bad "cli 一次都没被调用"; fi
if grep -qE '^-s \.video0\.(size|fps|codec|bitrate|rcMode) $' "$CLI"; then
	bad "有空的视频参数被写进 majestic："
	grep -E '^-s \.video0\.' "$CLI" | sed 's/^/        /'
else
	ok "没有空值"
fi
grep -qx -- '-s .video0.size 1920x1080' "$CLI" && ok "分辨率 1920x1080" || bad "分辨率没写"
grep -qx -- '-s .video0.fps 30' "$CLI" && ok "帧率 30" || bad "帧率没写"
grep -qx -- '-s .video0.codec h264' "$CLI" && ok "编码 h264" || bad "编码没写"
grep -q 'sensorConfig .*jxf23_i2c_1080p\.ini' "$CLI" && ok "写了 F23 传感器 ini" || bad "没写传感器 ini"
if [ -e "$T/etc/system.ok" ]; then ok "置了 system.ok（下次启动不再覆盖）"; else bad "没置 system.ok"; fi

echo
echo "== 第二次 start 不应重写视频剖面 =="
: > "$CLI"
run start > /dev/null 2>&1
sleep 1
if grep -q 'sensorConfig' "$CLI"; then
	bad "第二次启动又写了视频配置（system.ok 没起作用）"
else
	ok "第二次启动没有重写视频配置"
fi

echo
echo "== 信道与 hw_mode 不一致时自动纠正 =="
printf 'SSID=T\nPASSWORD=\nCHANNEL=6\nHW_MODE=a\nAP_IP=10.0.0.1\n' > "$T/etc/apfpv.conf"
: > "$CLI"
: > "$LOG"
rm -f "$T/log/used-hostapd.conf"
run start > /dev/null 2>&1
sleep 1
H="$T/log/used-hostapd.conf"
grep -qx 'channel=6' "$H" 2>/dev/null && ok "信道 6" || bad "信道没生效"
grep -qx 'hw_mode=g' "$H" 2>/dev/null && ok "hw_mode 被纠正为 g" || bad "hw_mode 没纠正"
grep -q '^wpa=' "$H" 2>/dev/null && bad "密码为空却仍有 wpa 行" || ok "密码为空 → 开放网络"
grep -qx 'start 10.0.0.10' "$T/var/run/udhcpd.conf" 2>/dev/null \
	&& ok "换了 AP_IP 后地址池跟着变" || bad "地址池没跟着 AP_IP 变"

echo
echo "----------------------------------------"
echo "通过 $pass 项，失败 $fail 项"
[ "$fail" -eq 0 ] || exit 1
