# AP 推流固件说明

这份文档对应**第二个产物**：`openipc.hi3518ev300-nor-apfpv-split.tgz`。

它和 FPV（wfb-ng）那份是**两个独立镜像**，同一块板子、同一颗 F23、同一套分区，
但工作方式完全不同：

| | FPV 镜像 (`..._fpv_wfbng`) | AP 镜像 (`..._apfpv`) |
|---|---|---|
| 无线角色 | 网卡注入原始 802.11 帧（monitor） | 网卡做 **AP 热点**（master） |
| 传输协议 | wfb-ng（自定义） | 标准 WiFi + RTSP / HTTP |
| 需要密钥 | **是**（`drone.key` + 地面端 `gs.key`） | **不要**任何密钥 |
| 客户端 | 地面站（wfb-ng 接收端） | 眼镜/手机/平板/电脑，任何能播 RTSP 的东西 |
| 传输距离 | 远（MCS1 + FEC 8:12，几公里） | 近（普通 WiFi，几十米到几百米） |
| 抗干扰 | 强（前向纠错 + 分片） | 弱（标准 802.11 重传机制） |
| 延迟 | 低且稳定 | 高一截，且随信号变差而抖动 |
| 一台设备同时看 | 多个地面站 | 多个客户端（共享热点带宽） |
| 用途 | 实际飞行 | 调试、近距离看画面、临时替代、把镜头当 IP 摄像头 |

> 一句话：**FPV 那份是飞出去用的，AP 这份是拿来看和调的。**

---

## 1. 为什么做成这个形态

原始需求里的 wfb-ng 方案需要地面端配合：一套 `gs.key`、一套接收程序，
还要飞机和地面站在同一信道、同一 MCS、同一 FEC 参数上对齐。任何一个不匹配就是雪花屏。

AP 模式把这些全绕开：热点的 SSID 和密码对上，手机就能看。
代价是距离和抗干扰 —— 这也是为什么它**不能替代** FPV 那份。

技术上它是「把这块板子变成一台 5.8GHz 的 WiFi 摄像机」：
`majestic` 编码 + RTSP 服务端，`hostapd` 提供热点，BusyBox `udhcpd` 分配地址。

---

## 2. 刷机

分区与刷写方式**和 FPV 那份完全一样**（同一块板子、同一套 U-Boot），
按 [`刷机与使用说明.md`](刷机与使用说明.md) §2 操作，只是把文件名换掉：

```bash
tftpboot 0x42000000 openipc.hi3518ev300-nor-apfpv-split.tgz
# 解包后得到 firmware.bin.hi3518ev300
tftp 0x42000000 firmware.bin.hi3518ev300
sf probe 0
sf erase 0x50000 ${filesize}
sf write 0x42000000 0x50000 ${filesize}
reset
```

**两份镜像不能交叉刷**：AP 那份里没有 `/etc/wfb.yaml`、没有 `wifibroadcast` 命令，
FPV 那份里没有 `apfpv` 命令。刷错了不会变砖，但没有对应功能 —— 重刷另一份即可。

用 `sysupgrade` 升级时它只认自己那套文件：

```bash
sysupgrade -k -r -n openipc.hi3518ev300-nor-apfpv-split.tgz
```

---

## 3. 首次启动做了什么

`/etc/init.d/S50apfpv` 在开机时调用 `/usr/bin/apfpv start`，顺序是：

1. 从 `/etc/apfpv.conf` 读热点参数
2. 按 USB VID:PID 认出网卡型号，只 `modprobe` 与它匹配的那一个驱动
   （两个驱动不会同时占住 USB 主机控制器）
3. 把 IP 配到接口上（默认 `192.168.4.1/24`）
4. **首次**启动时写一次视频剖面（`/etc/apfpv-video.conf`）并置 `/etc/system.ok`
5. 起 `hostapd`（热点）和 `udhcpd`（给客户端发地址）

第 4 步不能省：上游给 `.isp.sensorConfig` 拼的是 `<sensor>_<family>.bin`，
那是 SigmaStar 的命名，海思这边真名是 `jxf23_i2c_1080p.ini`。
不显式写就会指向一个不存在的文件，摄像头起不来。

---

## 4. 连上去看画面

开机约 20 秒后，用手机/电脑搜 WiFi：

```
SSID     : OpenIPC-AP
密码     : openipc12345
频段     : 5.8GHz（信道 161）
```

连上之后（客户端会自动拿到 `192.168.4.10–100` 的地址）：

| 方式 | 地址 | 说明 |
|---|---|---|
| 网页 | `http://192.168.4.1/` | majestic 的 WebUI，能看画面、调参数 |
| RTSP | `rtsp://192.168.4.1:554/` | VLC / ffplay / 眼镜；路径以 WebUI 显示的为准 |
| ONVIF | `192.168.4.1` | 支持 ONVIF 的客户端可自动发现 |
| mDNS | `http://openipc.local/` | 手机端支持 mDNS 时可用 |

命令行验一下：

```bash
ffplay -fflags nobuffer -flags low_delay rtsp://192.168.4.1:554/
```

**手机连不上 5.8GHz？** 有些地区的手机只允许 2.4GHz 热点。改
`/etc/apfpv.conf`：

```
CHANNEL=6
HW_MODE=g
```

然后 `apfpv restart`。（`HW_MODE` 写错也没关系 —— 脚本会按信道自动纠正并在日志里说明。）

---

## 5. 改配置

### 5.1 热点参数：`/etc/apfpv.conf`

```bash
vi /etc/apfpv.conf
apfpv restart
```

只认这几个键：

| 键 | 默认 | 说明 |
|---|---|---|
| `SSID` | `OpenIPC-AP` | 热点名字 |
| `PASSWORD` | `openipc12345` | WPA2 密码，8–63 位；**留空 = 开放网络** |
| `CHANNEL` | `161` | 信道；≥36 视为 5GHz |
| `HW_MODE` | `a` | `a`=5GHz，`g`=2.4GHz |
| `WIDTH` | `20` | 带宽 MHz |
| `AP_IP` | `192.168.4.1` | 本机地址；DHCP 池按最后一段推出 `.10–.100` |
| `AP_MASK` | `255.255.255.0` | 掩码 |

### 5.2 视频参数：`/etc/apfpv-video.conf`

只在**首次**启动生效一次（之后用 `/etc/system.ok` 做标记，
免得每次开机都覆盖你手改过的值）。改完想立刻生效：

```bash
rm -f /etc/system.ok
apfpv restart
```

或者直接改运行时配置：

```bash
cli -s .video0.size 1280x720
cli -s .video0.bitrate 4000
killall -1 majestic          # 让它重读配置
```

F23 只有 1080p30（见 [`网卡与传感器兼容性.md`](网卡与传感器兼容性.md) §1.1），
`VIDEO_FPS` 填 60 不会报错，但实际出不来 60 帧。

### 5.3 恢复出厂

```bash
apfpv reset
reboot
```

会把 `/etc/apfpv.conf`、`/etc/apfpv-video.conf` 换回 squashfs 里的原件，
并清掉 `/etc/system.ok`。

---

## 6. 状态与排障

```bash
apfpv status      # 配置摘要 + 接口 + 进程 + 已连客户端 + 取流地址
apfpv detect      # 只打印 USB ID → 驱动名，不动任何东西
apfpv start/stop/restart
logread -f | grep apfpv
```

### 6.1 `apfpv detect` 一条都没有

那不是驱动问题，是 **USB 主机口没起来**：

```bash
lsusb                        # 空 = USB 侧没枚举
ls /sys/bus/usb/devices/     # 只有 usb1（root hub）同样说明没有外设
```

本平台内核是 `CONFIG_USB_DWC3=y` + `CONFIG_USB_DWC3_DUAL_ROLE=y` ——
主机还是从机由设备树的 `dr_mode` 决定，不是内核配置。板子若配成 peripheral，
插什么卡都不会枚举。这是硬件层的事，固件改不了。
细节见 [`刷机与使用说明.md`](刷机与使用说明.md) §3.1。

### 6.2 有网卡但热点起不来

先看 `hostapd` 的原始报错：

```bash
hostapd -d /var/run/hostapd.conf
```

常见的两种：

- **`Could not set channel / invalid channel`** —— 信道与 `hw_mode` 不匹配，
  或网卡不支持该信道。5GHz 优先试 36/149/161，2.4GHz 试 1/6/11。
- **`driver initialization failed`** —— 换驱动后端。默认用 `driver=nl80211`；
  改成 `driver=rtw`（镜像里编了 Realtek 那个后端）再试。
  这一行是运行时生成的，改法：

  ```bash
  sed -i 's/^driver=.*/driver=rtw/' /var/run/hostapd.conf
  hostapd -B /var/run/hostapd.conf
  ```

  确认哪种能用了再决定要不要写进脚本。

### 6.3 连上了但没有画面

```bash
apfpv status        # 客户端有没有出现
cli -g .video0      # 分辨率/帧率/码率是否为期望值
curl -s localhost/api/v1/config.json | jsonfilter -e "@.video0"
dmesg | tail -30    # 传感器有没有起来
```

最常见是传感器 ini 指错（不是 `jxf23`）。核对：

```bash
cli -g .isp.sensorConfig     # 应指向 /etc/sensors/jxf23_i2c_1080p.ini
ls /etc/sensors/ | grep f23  # 文件是否存在
```

### 6.4 画面卡、花

- 热点和客户端在同一频段时，**客户端离得越远越糟** —— 这是标准 WiFi，
  没有 wfb-ng 的 FEC 保护
- 降码率：`cli -s .video0.bitrate 4000`
- 换 2.4GHz 往往更稳（穿墙好），代价是干扰多
- 客户端数量多时带宽是共享的，一台在下载会拖垮所有人

---

## 7. 安全提醒

两个独立的点：

1. **热点密码只保护 WiFi。** `openipc12345` 是写在镜像里的默认值，
   附近的人知道这个默认值就能连。正式用请改 `PASSWORD`，或者接受"近距离谁都能看"。
2. **SSH 沿用了上游默认：root 空密码。** AP 镜像里 dropbear 仍是 `-B` 启动，
   连上热点的人可以 `ssh root@192.168.4.1` 直接进。**刷完第一件事：**

   ```bash
   passwd root
   ```

   完整说明见 [`刷机与使用说明.md`](刷机与使用说明.md) §7.1。

---

## 8. 它不适合干什么

- **不要指望它做远距图传。** 几公里的活交给 FPV（wfb-ng）那份。
- **不要指望低延迟。** 标准 WiFi 的重传 + majestic 的编码缓冲，
  端到端通常比 wfb-ng 高几十到一百多毫秒，且不稳定。
- **不要同时刷两份。** 一块 flash 只有一份镜像，功能二选一。
- **不要在没改密码的情况下拿到公共场合开。** 见 §7。
