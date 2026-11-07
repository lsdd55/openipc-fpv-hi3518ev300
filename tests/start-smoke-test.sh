#!/bin/sh
#
# 端到端冒烟测试：用桩程序模拟整条启动路径。
#
# 目的不是验证硬件，而是验证脚本的控制流与变量传递：
#   load_config -> load_modules -> load_mlink -> load_interface
#   -> video_settings -> start_broadcast / start_tunnel / start_telemetry
#
# 做法：
#   1. 把脚本里所有绝对路径 /etc、/rom 重定向到临时目录
#   2. 用桩程序替代 lsusb / modprobe / iw / ifconfig / cli / wfb_* 等
#   3. 跑 `wifibroadcast start`，断言调用序列与参数是否正确
#
# 用法：  sh tests/start-smoke-test.sh
#
set -u

here=$(cd "$(dirname "$0")" && pwd)
proj="$here/.."
src="$proj/overlay/general/package/wifibroadcast-ng/files/wifibroadcast"
[ -f "$src" ] || { echo "找不到 $src" >&2; exit 1; }

T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/etc" "$T/etc/sensors" "$T/rom/etc" "$T/log" "$T/sys/net/wlan0"

fail=0
pass=0
ok()  { printf 'PASS  %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf 'FAIL  %s\n' "$1"; fail=$((fail + 1)); }

# ---- 1. 路径重定向 ---------------------------------------------------------
# 分三步做，避免 /rom/etc 被 /etc 的替换重复命中。
# /sys/class/net 也要重定向：真实设备上驱动加载后才会出现 wlan0，
# 这里用一个空目录假装接口已经起来了。
sed -e 's|/rom|@ROM@|g' \
    -e 's|/sys/class/net|@SYSNET@|g' \
    -e "s|/etc/|$T/etc/|g" \
    -e "s|@ROM@|$T/rom|g" \
    -e "s|@SYSNET@|$T/sys/net|g" \
	"$src" > "$T/wifibroadcast"
chmod +x "$T/wifibroadcast"

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

# lsusb：模拟插着一张 RTL8812AU
cat > "$T/bin/lsusb" <<'EOF'
#!/bin/sh
echo "Bus 001 Device 001: ID 1d6b:0002 Linux Foundation 2.0 root hub"
echo "Bus 001 Device 002: ID 0bda:8812 Realtek 802.11ac NIC"
EOF
chmod +x "$T/bin/lsusb"

for n in modprobe ifconfig iw killall wfb_tx wfb_rx wfb_tun msposd mavfwd \
         yaml-cli yaml-cli-multi; do
	mkstub "$n"
done

# logger：模拟 busybox `logger -s` 的行为 —— -s 会把它收到的东西回显到
# stderr。桩必须照做，否则 echo_log 的输出在测试里完全消失，就永远无法
# 断言"某条告警有没有打出来"。同时留一份到 messages.log 便于 grep，
# 并在 calls.log 里记一笔以证明 logger 被调用过。
cat > "$T/bin/logger" <<EOF
#!/bin/sh
msg=\$(cat)
printf '%s\n' "\$msg" >> "$T/log/messages.log"
printf '%s\n' "\$msg" >&2
echo "logger" >> "$T/log/calls.log"
exit 0
EOF
chmod +x "$T/bin/logger"

# cli：记录每一次 -s 设置，便于断言视频参数
cat > "$T/bin/cli" <<EOF
#!/bin/sh
echo "\$*" >> "$T/log/cli.log"
exit 0
EOF
chmod +x "$T/bin/cli"

# jsonfilter：给 msposd 的 -z 参数提供分辨率
cat > "$T/bin/jsonfilter" <<'JEOF'
#!/bin/sh
echo "1920x1080"
JEOF
chmod +x "$T/bin/jsonfilter"

# curl：返回一段假 config.json 给 jsonfilter
cat > "$T/bin/curl" <<'EOF'
#!/bin/sh
echo '{"video0":{"size":"1920x1080"}}'
EOF
chmod +x "$T/bin/curl"

# touch/rm 等都是真的，不需要桩

# ---- 3. 输入文件 -----------------------------------------------------------
cp "$proj/overlay/general/package/wifibroadcast-ng/files/wfb.yaml" "$T/etc/wfb.yaml"
cp "$proj/overlay/general/package/wifibroadcast-ng/files/drone.key" "$T/etc/drone.key"
# fpv-video.conf 里的 SENSOR_INI 也是绝对路径，同样要重定向到临时目录
sed -e "s|/etc/|$T/etc/|g" \
	"$proj/overlay/general/overlay/etc/fpv-video.conf" > "$T/etc/fpv-video.conf"

# 传感器 ini 必须存在，否则脚本会走"自动探测"分支（这是设计行为，
# 这里要测的是存在时的分支）
: > "$T/etc/sensors/jxf23_i2c_1080p.ini"

# ---- 4. 跑 -----------------------------------------------------------------
PATH="$T/bin:$PATH" sh "$T/wifibroadcast" start > "$T/log/stdout.log" 2>&1
rc=$?

# 后台任务给一点时间落盘
sleep 1

echo "== 退出码 =="
# 脚本用了 & 后台，退出码应为 0
if [ "$rc" -eq 0 ]; then ok "start 退出码 0"; else
	bad "start 退出码 $rc"; sed 's/^/        /' "$T/log/stdout.log"
fi

LOG="$T/log/calls.log"
touch "$LOG"

echo
echo "== 驱动加载 =="
if grep -q "^modprobe -r 8812au" "$LOG"; then
	ok "先卸载候选驱动（避免 mdev 抢绑）"
else
	bad "没有先卸载候选驱动"
fi
if grep -q "^modprobe 8812au .*MaxTxBufLen=32" "$LOG"; then
	ok "按 PID 加载了 8812au（0bda:8812）"
else
	bad "未按 PID 加载 8812au"; grep '^modprobe' "$LOG" | sed 's/^/        /'
fi

echo
echo "== 接口配置 =="
if grep -q "^ifconfig wlan0 mtu 3994" "$LOG"; then
	ok "MTU 设为 3994（来自 wfb.yaml mlink）"
else
	bad "MTU 未按 wfb.yaml 设置"; grep '^ifconfig' "$LOG" | sed 's/^/        /'
fi
if grep -q "^iw wlan0 set channel 161 HT20" "$LOG"; then
	ok "信道 161 / HT20（来自 wfb.yaml）"
else
	bad "信道/带宽不正确"; grep 'set channel' "$LOG" | sed 's/^/        /'
fi
if grep -q "^iw wlan0 set txpower fixed -2000" "$LOG"; then
	ok "发射功率 20dBm 换算正确（txpower 20 -> -2000）"
else
	bad "功率换算不对"; grep 'txpower' "$LOG" | sed 's/^/        /'
fi

echo
echo "== 按卡种调 stbc/ldpc（8812AU 支持，应为 1/1）=="
# 8812au 是 2x2，支持 STBC/LDPC；上游对 8812au 正是给 1/1。
# 8733bu 是 1T1R 用不了，保持 0/0。
if grep -q "^yaml-cli .* -s \.broadcast\.stbc 1" "$LOG"; then
	ok "8812AU 写入了 stbc=1"
else
	bad "没有按卡种写入 stbc"; grep 'stbc' "$LOG" | sed 's/^/        /'
fi
if grep -q "^yaml-cli .* -s \.broadcast\.ldpc 1" "$LOG"; then
	ok "8812AU 写入了 ldpc=1"
else
	bad "没有按卡种写入 ldpc"; grep 'ldpc' "$LOG" | sed 's/^/        /'
fi
# 关键：写完必须当次生效，否则 wfb_tx 仍是 -S 0 -L 0（上游就是这个问题）
if grep -q "^wfb_tx .* -S 1 -L 1 " "$LOG"; then
	ok "写完立即刷新变量，本次 wfb_tx 已是 -S 1 -L 1（不必等重启）"
else
	bad "stbc/ldpc 未当次生效"; grep '^wfb_tx' "$LOG" | sed 's/^/        /'
fi

echo
echo "== 视频剖面 =="
CLI="$T/log/cli.log"
if grep -qxF -- "-s .video0.size 1920x1080" "$CLI"; then
	ok "分辨率 1920x1080（F23 能力上限）"
else
	bad "分辨率未写入"; grep 'size' "$CLI" | sed 's/^/        /'
fi
if grep -qxF -- "-s .video0.fps 30" "$CLI"; then
	ok "帧率 30（F23 无 60fps 模式）"
else
	bad "帧率未写入"; grep 'fps' "$CLI" | sed 's/^/        /'
fi
if grep -qxF -- "-s .video0.codec h264" "$CLI"; then
	ok "编码 h264"
else
	bad "编码未写入"
fi
if grep -qxF -- "-s .video0.bitrate 10000" "$CLI"; then
	ok "码率 10000kbps"
else
	bad "码率未写入"
fi
if grep -qxF -- "-s .isp.sensorConfig $T/etc/sensors/jxf23_i2c_1080p.ini" "$CLI"; then
	ok "传感器 ini 指向 jxf23（不是 jxf23 不存在的 .bin）"
else
	bad "传感器 ini 路径不对"; grep 'sensorConfig' "$CLI" | sed 's/^/        /'
fi

echo
echo "== wfb 进程 =="
if grep -q "^wfb_tx -K .* -M 1 -B 20 -k 8 -n 12 .* -i 7669206 " "$LOG"; then
	ok "wfb_tx 参数符合 5.8G/20MHz/MCS1/FEC8:12/link_id"
else
	bad "wfb_tx 参数不对"; grep '^wfb_tx' "$LOG" | sed 's/^/        /'
fi
if grep -q "^wfb_tun -a 10.5.0.10/24" "$LOG"; then
	ok "wfb_tun 已启动"
else
	bad "wfb_tun 未启动"
fi
if grep -q "^msposd -b 115200" "$LOG"; then
	ok "msposd 已启动（telemetry.router）"
else
	bad "msposd 未启动"
fi

echo
echo "== 幂等保护 =="
if [ -f "$T/etc/system.ok" ]; then
	ok "/etc/system.ok 已生成（下次启动不再重写视频配置）"
else
	bad "/etc/system.ok 未生成"
fi

echo
echo "== 8812au 模块名回退（主名 8812au 加载失败时改用 88XXau）=="
# 换一张 RTL8812AU 的卡
cat > "$T/bin/lsusb" <<'EOF'
#!/bin/sh
echo "Bus 001 Device 002: ID 0bda:8812 Realtek 802.11ac NIC"
EOF
chmod +x "$T/bin/lsusb"
# 让 modprobe 对主名 8812au 失败、对备用名 88XXau 成功 ——
# 模拟镜像里装的是 aircrack 分支那个叫法的模块
cat > "$T/bin/modprobe" <<EOF
#!/bin/sh
echo "modprobe \$*" >> "$T/log/calls.log"
[ "\$1" = "8812au" ] && exit 1
exit 0
EOF
chmod +x "$T/bin/modprobe"
: > "$LOG"
: > "$T/log/messages.log"
PATH="$T/bin:$PATH" sh "$T/wifibroadcast" start > "$T/log/stdout3.log" 2>&1
sleep 1
if grep -q '^modprobe 8812au ' "$LOG"; then
	ok "先按主名 8812au 加载"
else
	bad "没有先试主名 8812au"
fi
if grep -q '^modprobe 88XXau ' "$LOG"; then
	ok "主名失败后回退到 88XXau"
else
	bad "没有回退到 88XXau"; grep '^modprobe' "$LOG" | sed 's/^/        /'
fi
if grep -q '改用 88XXau 成功' "$T/log/messages.log"; then
	ok "回退时打了日志（现场可查）"
else
	bad "回退没有日志"
fi
# 第一次跑时 /sys 下没有 mtu 文件（模拟读不到），应按配置值 3994 算
if grep -qx -- "-s .rtsp.naluSize 3894" "$CLI"; then
	ok "读不到真实 MTU 时按 mlink=3994 算 naluSize=3894"
else
	bad "naluSize 未按 mlink 计算"; grep 'naluSize' "$CLI" | sed 's/^/        /'
fi

# 现在让 /sys 报 1500：模拟驱动只接受 1500（ifconfig 却不一定报错）
echo 1500 > "$T/sys/net/wlan0/mtu"
: > "$CLI"
PATH="$T/bin:$PATH" sh "$T/wifibroadcast" start > "$T/log/stdout2.log" 2>&1
sleep 1
if grep -qx -- "-s .rtsp.naluSize 1400" "$CLI"; then
	ok "驱动只接受 MTU 1500 时，naluSize 自动降到 1400（不会错配）"
else
	bad "MTU 被拒时未回退 naluSize"; grep 'naluSize' "$CLI" | sed 's/^/        /'
fi
if grep -q '驱动只接受 MTU 1500' "$T/log/messages.log"; then
	ok "回退时有明确日志（logger -s 能看见）"
else
	bad "回退没有日志，现场无法察觉"
	sed 's/^/        /' "$T/log/messages.log" 2>/dev/null
fi

echo
echo "== reset（恢复出厂）=="
# 这一组来自一个真实缺陷：reset 分支原先没调 load_config，
# 于是 VIDEO_SIZE / FPS / CODEC / BITRATE / RCMODE / SENSOR_INI 全是空字符串，
# video_settings 会把 majestic 配置写成空值 —— 而出问题想复位时正是要跑它。
: > "$T/log/cli.log"
rm -f "$T/etc/system.ok" 2>/dev/null
PATH="$T/bin:$PATH" sh "$T/wifibroadcast" reset > "$T/log/stdout-reset.log" 2>&1
rc_r=$?
sleep 1

if [ "$rc_r" -eq 0 ]; then
	ok "reset 退出码 0"
else
	bad "reset 退出码 $rc_r"; sed 's/^/        /' "$T/log/stdout-reset.log"
fi

# 关键断言：绝不能出现空值
if grep -qE '^-s \.video0\.(size|fps|codec|bitrate|rcMode) $' "$T/log/cli.log"; then
	bad "reset 把空值写进了视频配置："; grep -E '^-s ' "$T/log/cli.log" | sed 's/^/        /'
else
	ok "reset 没有写入空值"
fi
if grep -qx -- '-s .video0.size 1920x1080' "$T/log/cli.log"; then
	ok "reset 用了 /etc/fpv-video.conf 的分辨率"
else
	bad "reset 的分辨率不对"; grep 'video0.size' "$T/log/cli.log" | sed 's/^/        /'
fi
if grep -qx -- '-s .video0.fps 30' "$T/log/cli.log"; then
	ok "reset 用了配置里的 fps"
else
	bad "reset 的 fps 不对"
fi
if grep -q 'sensorConfig .*jxf23_i2c_1080p\.ini' "$T/log/cli.log"; then
	ok "reset 写回了传感器 ini 路径"
else
	bad "reset 没写传感器 ini"; grep 'sensorConfig' "$T/log/cli.log" | sed 's/^/        /'
fi
if [ -e "$T/etc/system.ok" ]; then
	bad "reset 之后 /etc/system.ok 还在（下次启动不会重新写视频配置）"
else
	ok "reset 清掉了 /etc/system.ok"
fi

echo
echo "----------------------------------------"
echo "通过 $pass 项，失败 $fail 项"
if [ "$fail" -ne 0 ]; then
	echo
	echo "--- calls.log ---"
	sed 's/^/  /' "$LOG"
	exit 1
fi
