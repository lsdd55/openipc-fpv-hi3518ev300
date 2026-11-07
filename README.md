# OpenIPC 固件 · Hi3518EV300 / F23 / 16MB · 两个产物

> **产物一**：`hi3518ev300_fpv_wfbng` —— wfb-ng 空中端（飞出去用）
> **产物二**：`hi3518ev300_apfpv` —— 纯 AP 推流（热点 + RTSP，看和调）
>
> 用途、差异与取舍见 [`docs/AP推流说明.md`](docs/AP推流说明.md)。

一套可直接构建的 OpenIPC FPV 机载（drone / TX）固件工程，基础是上游
[OpenIPC/firmware](https://github.com/OpenIPC/firmware)，
用 overlay 方式叠加定制内容，不改上游代码。

---

## 1. 先说两件做不到的事

你在需求里指定的两项参数，在 Hi3518EV300 + F23 这个硬件组合上**物理不可行**。
我在动手前做了核实，证据如下，替代方案也一并给出。

### 1.1 720p60 做不到 —— F23 传感器只有 1080p30

`/usr/lib/sensors/libsns_f23.so` 里只有两个模式入口：

```
soi_sensor_linear_1080p30_init
soi_sensor_2wdr1_1080p30_init
```

并且带拒绝分支：`Not support Fps: %f`、`Not support! Width:%d, Height:%d, Fps:%f`。
配套的 `/etc/sensors/jxf23_i2c_1080p.ini` 也是单一 1080p 模式
（`Isp_FrameRate=25`，`Timingblank_VsyncVact=1080`）。

**没有任何 60fps 模式可以选。** 编码器侧 720p60 是够用的
（55 Mpixel/s < SoC 上限 62 Mpixel/s），瓶颈完全在传感器。

→ 本工程默认给 **1080p30 H.264 10Mbps CBR**：保留你指定的编码和码率，
只把帧率降到传感器真实能力。参数在 `/etc/fpv-video.conf`，可随时改。

→ 如果 60fps 是必须项，只能换传感器。同一块板子同一颗 SoC 上，
上游已经备好了 60fps 档位：

| 传感器 | 配置 | 效果 |
|---|---|---|
| IMX307 | `/etc/sensors/high-fps/imx307_1280x720_60fps.ini` | 720p60 |
| IMX307 | `/etc/sensors/high-fps/imx307_1920x1080_60fps.ini` | 1080p60 |
| IMX335 | `/etc/sensors/high-fps/imx335_1920x1080_55fps.ini` | 1080p55 |
| IMX335 | `/etc/sensors/high-fps/imx335_1296x972_64fps.ini` | 1296x972@64 |

### 1.2 MT7921AU 做不到 —— 驱动要求内核 ≥ 6.12

MT7921AU 唯一可用的驱动是 mt76 的 `mt7921u`。现存的独立发布版
[morrownr/mt76](https://github.com/morrownr/mt76) 自述：

> Build, install, and manage MediaTek mt76 WiFi drivers as out-of-tree kernel
> modules. Supports DKMS, non-DKMS, Secure Boot, and **kernels 6.12 through 7.4**.

Hi3518EV300 的内核被海思 SDK 锁死在 **4.9.37**（2017 年）。
mt76 依赖 5.x 之后才有的 cfg80211/mac80211 API，往 4.9 上回移不是改几行
的事，是把整个无线子系统搬过来 —— 不具工程可行性。

→ 本工程**不含** MT7921AU 支持，`docs/网卡与传感器兼容性.md` 记录了完整
证据链和可选路径（换 SoC 平台 / 换用受支持的网卡）。

→ 剩下两个网卡（8812AU / 8733BU）已全部实现，且都是上游现成的包。

---

## 2. 需求对照

| 你的要求 | 状态 | 落地方式 |
|---|---|---|
| SoC Hi3518EV300 | ✅ | `BR2_OPENIPC_SOC_MODEL="hi3518ev300"`，家族走 `hi3516ev200`（上游就是这么归类的） |
| 感光元件 F23 | ✅ 原生支持 | `jxf23_i2c_1080p.ini` + `iq/f23.ini` + `libsns_f23.so` 上游已带；脚本显式指定 ini 路径 |
| 16MB SPI Flash | ✅ | `BR2_OPENIPC_FLASH_SIZE="16"`，NOR split 布局，固件分区从 `0x50000` 起 |
| 自有 wfb-ng 密钥对 | ✅ 已生成 | `keys/drone.key` / `keys/gs.key`，Curve25519，经 RFC 7748 向量与 ECDH 对称性自检 |
| RTL8812AU | ✅ | 上游 `rtl8812au-openipc`，`rtl8812au_fpv` 分支（含注入补丁） |
| RTL8814AU | ❌ **不编入** | 4x4 卡，体积在 16MB 方案上不划算，8812AU 覆盖同样场景。移除后本工程**没有任何自建驱动包** |
| RTL8812CU | ❌ **不编入** | 唯一的驱动 `libc0607/rtl88x2cu` 只声明支持内核 6.12，本平台 4.9.37 无实证。两张里都有 4.9 依据，砍掉省 ~0.6 MB |
| RTL8733BU | ✅ | 上游 `rtl8733bu-openipc`，`rtl8733bu_fpv` 分支 |
| MT7921AU | ❌ 不可行 | 见 1.2 |
| 全部编入、运行时单卡 | ✅ | 四个 `.ko` 全在镜像里，脚本按 VID:PID 只 insmod 匹配的那一个，并先清空其余 |
| 720p60 H.264 10Mbps | ⚠️ 改为 1080p30 | 见 1.1 |
| 5.8G / 20MHz / MCS1 / FEC 8:12 / 32B 密钥 | ✅ | `overlay/.../files/wfb.yaml` |
| GitHub Actions 构建 | ✅ | `.github/workflows/build.yml`，不需要 PAT |
| 可刷 .bin + 脚本 + 密钥 + 中文说明 | ✅ | 本仓库 + Actions artifact |

---

### 2.1 一次构建出两个镜像

两个 defconfig 共用同一套 SoC/内核/工具链/分区，但装的包完全不同：

| | FPV 镜像 | AP 镜像 |
|---|---|---|
| defconfig | `hi3518ev300_fpv_wfbng` | `hi3518ev300_apfpv` |
| 变体名 | `fpv` | `apfpv` |
| 网卡角色 | monitor 注入 | **AP 热点** |
| 传输 | wfb-ng | WiFi + RTSP / HTTP |
| 需要密钥 | 是（`drone.key`） | **否** |
| 关键包 | `wifibroadcast-ng` | `apfpv` + `rtw-hostapd` |
| 产物 | `...nor-fpv-split.tgz` | `...nor-apfpv-split.tgz` |

CI 里是一个矩阵，两个 job 并行各出一份，互不影响（`fail-fast: false`）。
两份**不会互相污染**：`BR2_PACKAGE_APFPV` 只在 apfpv 变体里选中，
`WIFIBROADCAST_NG` 只在 FPV 变体里选中 —— 有断言钉住这一点。

关于变体名的两个已知后果（都是主动选择）：

- `rtl8733bu-openipc.mk` 用 `$(findstring fpv,...)` 选分支，`apfpv` 含 `fpv`
  子串 → 仍拿上游验证过的 `rtl8733bu_fpv` 分支
- `hisilicon-opensdk.mk` / `majestic-webui.mk` 用 `$(filter fpv wfbng,...)`
  整词匹配 → `apfpv` 不命中，于是不装 IMX307/IMX335 高帧率库（F23 用不上）、
  网页用 STANDARD 页面（纯 AP 场景更合适）

## 3. 目录结构

```
.
├── overlay/                       # 按 firmware 仓库根目录结构铺进去
│   ├── br-ext-chip-hisilicon/
│   │   └── configs/
│   │       ├── hi3518ev300_fpv_wfbng_defconfig   # 产物一：wfb-ng 空中端
│   │       └── hi3518ev300_apfpv_defconfig       # 产物二：纯 AP 推流
│   └── general/
│       ├── overlay/etc/           # -> 设备上的 /etc/
│       │   ├── fpv-video.conf     #    视频剖面（FPV 镜像）
│       │   └── fpv-usb-ids.txt    #    网卡对照表
│       └── package/
│           ├── wifibroadcast-ng/files/
│           │   ├── drone.key      # 你的机载私钥（0600）
│           │   ├── wfb.yaml       # 链路参数
│           │   └── wifibroadcast  # 定制运行时脚本
│           └── apfpv/files/       # AP 镜像专用（只在 apfpv 变体里被选中）
│               ├── apfpv          #   热点/DHCP 控制脚本
│               ├── S50apfpv       #   开机启动
│               ├── apfpv.conf     #   SSID/密码/信道
│               └── apfpv-video.conf
├── keys/
│   ├── drone.key                  # 机载端（上面那份的母本）
│   ├── gs.key                     # 地面端 —— 自己收好，别进仓库
│   ├── PUBKEYS.txt                # 公钥 + 指纹（可公开，用于核对）
│   └── gen-keys.py                # 可复现地重新生成
├── scripts/
│   ├── apply-overlay.sh
│   ├── patch-config-in.py
│   ├── build.sh                   # 本地/WSL 整链构建
│   └── publish.sh                 # 发布前检查密钥 + 本地提交（不替你 push）
├── tests/                         # 见 §7.1（206 项）
│   ├── detect-test.sh
│   ├── start-smoke-test.sh
│   ├── apply-overlay-test.sh
│   ├── gitignore-test.sh          # 用真实 git 验证 gs.key 不会入库
│   ├── validate-config.py
│   ├── validate-docs.py
│   ├── validate-workflow.py
│   └── run-all.sh
├── docs/
│   ├── 刷机与使用说明.md
│   └── 网卡与传感器兼容性.md
└── .github/workflows/build.yml
```

---

## 4. 构建

### 方式 A：GitHub Actions（推荐，不需要 Docker，不占本地磁盘）

```bash
git init && git add -A && git commit -m "fpv firmware"
git remote add origin git@github.com:<你>/<仓库>.git
git push -u origin main
```

推上去后进 Actions → `build-fpv-hi3518ev300` → Run workflow。
约 40~80 分钟，产物在 run 页面的 artifact 里（`.bin` + `SHA256SUMS`）。

> **不需要 Personal Access Token。** 工作流只做三件事：读本仓库、克隆公开的
> 上游仓库、用自己的 `GITHUB_TOKEN` 上传 artifact。任何情况下都不要把 PAT
> 写进仓库或贴到聊天里 —— 你之前贴出的那个请务必确认已撤销。

### 方式 B：本地 Linux / WSL

```bash
# WSL 里，构建根目录放 D 盘（C 盘空间不够）
cd /mnt/d/Downloads/FPV/openipc-fpv-hi3518ev300
./scripts/build.sh --deps
```

磁盘约需 12~15 GB。产物在 `work/firmware/output/images/`。

> ⚠️ **在本开发机上跑不通**：需要下载 98.5 MB 的预编译工具链和上百 MB 的
> 内核源码，而本机网络在 15–20 MB 处切断且不支持 Range 续传。
> 换一台网络正常的机器，或先把这些文件放进 `BR2_DL_DIR`。详见
> `docs/网卡与传感器兼容性.md` §5。

---

## 5. 密钥

| 文件 | 给谁 | 内容 |
|---|---|---|
| `keys/drone.key` | 机载（已打进镜像 `/etc/drone.key`） | drone 私钥(32B) ‖ gs 公钥(32B) |
| `keys/gs.key` | 地面站 | gs 私钥(32B) ‖ drone 公钥(32B) |

指纹（两边都要核对）：

```
drone pubkey : f529ccc9c938f38e2226af35bad25d46cc7cfdf029c7d336d008cb77c7f9de60
drone fp     : fa71:3067:4df0:b754
gs    pubkey : a9411f5e42281bceb0c72dfe0f61791fa58de68bcf3c8117e00f2bcd96598713
gs    fp     : 5a19:3e63:c546:0e84
```

`gen-keys.py` 的自检覆盖：RFC 7748 §5.2 测试向量、§6.1 Alice/Bob 共享密钥、
以及本项目两把密钥的 DH 对称性 —— 任一项不过就拒绝落盘。

重新生成（换了就两边都得换）：

```bash
cd keys && python3 gen-keys.py .
cp drone.key ../overlay/general/package/wifibroadcast-ng/files/drone.key
```

> `keys/gs.key` 请放进密码管理器，**不要提交到公开仓库**。本仓库的
> `.gitignore` 已排除（`tests/gitignore-test.sh` 用真实 git 验证过），
> 但 `drone.key` 必须提交 —— CI 要靠它核对镜像里的密钥。

### 5.1 为什么仓库必须是私有的

`keys/drone.key` 一个文件里就同时有 **drone 私钥**和 **GS 公钥**。而会话密钥
正是 `X25519(drone_私钥, gs_公钥)` —— 这两样凑齐，就能算出会话密钥。也就是说：

**拿到 `drone.key`，就等于拿到解密你的图传、并往链路里注入画面的能力。**

而它为了构建必须提交。所以：

- **仓库必须私有。** 公开仓库 = 公开你的链路。
- 编出来的 `.bin` 里也烤着同一份 `drone.key`，**固件同样不能公开发布**。
  要分享固件，先 `keys/gen-keys.py` 重生成一套再构建，旧固件对应的密钥即作废。
- `keys/PUBKEYS.txt` 只含公钥与指纹，可以安全分享 —— 用它来核对两边是不是同一对。

发布前跑一次 `scripts/publish.sh`：它会用真实 `git` 检查 `gs.key` 确实被忽略、
暂存区里没有 `gs.key`，然后在本地做好提交，把 `--private` 的建仓命令摆给你。
它**不会**替你 push（那需要你的凭据，而且推错仓库不可撤销）。

---

## 6. 已知风险（请按顺序验证）

| # | 风险 | 影响 | 怎么确认 |
|---|---|---|---|
| 1 | 两个驱动都是**上游现成的包**，本工程没有自建的驱动源码包 | 风险已降到最低：包的 `.mk` 由上游维护，无需自己适配 4.9 | 若仍失败，CI 的「失败诊断」会点名具体包 |
| 2 | RTL8812AU 也没被上游海思 defconfig 直接验证过（海思只用 8188fu/8189fs） | 构建可能失败 | 同上。两张卡里 **RTL8733BU 最稳**（上游 ssc338q 4.9 在用） |
| 3 | 8812AU 与已移除的 88x2CU 的 USB ID 表曾重叠（`0bda:8812/881a`） | 插错卡时驱动抢绑（现已无此驱动） | 已用「先卸载全部再装一个」规避；`wifibroadcast detect` 可查 |
| 4 | 16MB flash 装不装得下两个驱动？ | `firmware.bin` 上限 **15808 KiB**（=16×1024−320−256），uImage 另有 **2048 KiB** 上限；估测总量 11–13 MB，余量不宽 | CI 的「体积报告」步骤直接给出实测值与余量；超了它会列出按序裁剪清单。详见 `docs/网卡与传感器兼容性.md` §6 |
| 5 | `serial: ttyS2` 是按上游默认值写的 | 飞控 OSD 收不到数据 | 板上试 `ttyS1`/`ttyS0` |
| 6 | 海思工具链与内核是上游 release 资产，非本地编译 | 上游改了地址就会失败 | 构建日志的下载 URL |

> **镜像必须在 CI 出。** 本开发环境的网络在 15–20 MB 处切断、服务端不支持
> Range 续传、绕过代理直连完全不通；而构建要拉 **98.5 MB** 的预编译工具链
> 加上百 MB 内核源码。实测数据见 `docs/网卡与传感器兼容性.md` §5。
> 你原本选的就是 GitHub Actions，那边网络正常，不受影响。

> **重试很便宜。** 工作流用 `actions/cache` 把 `work/dl` 存下来，并通过
> `BR2_DL_DIR` 指给 Buildroot。第一次跑完（成功或失败都会存），之后任何一次
> 重试都直接命中 —— 不用重下 98.5 MB 工具链和内核源码。本地
> `scripts/build.sh` 也用同一个变量（默认 `work/dl`），所以改完驱动重跑
> 只编增量。

---

## 7. 验证情况

分两层：**离线单元/集成测试**（随时可跑）和**真实 Buildroot 配置层验证**
（已跑过一次，结论如下）。

### 7.1 离线测试：206 项断言

不需要硬件、不需要 root、不需要联网：

```bash
sh tests/run-all.sh
```

| 套件 | 覆盖 | 断言数 |
|---|---|---|
| `detect-test.sh` | 三个网卡家族的 VID:PID → 驱动名映射，含大写 ID、hub 混插、双卡并存、MT7921AU 应判为未知 | 17 |
| `start-smoke-test.sh` | 用桩程序跑完整 `start`：驱动卸载/加载 → MTU/信道/功率 → 视频剖面 → wfb_tx/rx/tun/msposd 参数 → 幂等标记 → naluSize 跟随真实 MTU → 按卡种调 stbc/ldpc → 88x2CU 模块名回退 | 30 |
| `apfpv-test.sh` | **AP 推流镜像**的桩测试：USB ID → 驱动名（含未识别、大写归一）、先卸后装的加载顺序、热点地址、生成的 `hostapd.conf`（ssid/信道/hw_mode/WPA2/11ac/driver）、DHCP 池随 `AP_IP` 推导、**首次启动写视频剖面时不许出现空值**（FPV 那份的 `reset` 在这里翻过车）、第二次启动不重写、信道与 `hw_mode` 不一致时自动纠正、空密码 → 开放网络 | 33 |
| `apply-overlay-test.sh` | overlay 铺设、Kconfig 注册恰好一次、插入位置保持字母序、重复执行不产生重复行 | 7 |
| `gitignore-test.sh` | 用**真实 git** 验证 `gs.key` 不会入库、两个 `drone.key` 会入库、构建产物不混入；`publish.sh` 在 `gs.key` 未被忽略时**拒绝执行**（负向测试）；以及 **`gs.key` 在任何路径下都必须被忽略**（gen-keys 写错目录时兜底） | 14 |
| `validate-config.py` | **交付物内容**回归：密钥 64B 且互换公钥逐字节相符、指纹自洽、两把 secret 不同、overlay 里的 drone.key 与 keys/ 一致；wfb.yaml 的 5.8G/20MHz/MCS1/FEC8:12/link_id；视频 h264/10Mbps/传感器 ini；defconfig 的 SOC/SNS/FLASH/VARIANT 与两个驱动；两处上游缺陷修正；以及文档里必须保留的安全承诺、可复现性交代、刷机命令与备份步骤的正确性；flash 预算里「裁不掉项」的交代；以及**两个驱动的模块名**与上游 Makefile 一致；以及 **apfpv 那份 defconfig 的自洽**（变体名含 fpv 子串、不含 wifibroadcast-ng、不拉 libopenssl、包文件齐全、两个产物互不污染）。另：设 `UPSTREAM_TREE=<上游检出>` 时会再核对 **13 项运行期命令来源**（iw / cli / lsusb / modprobe / curl / jsonfilter / yaml-cli… 各自谁提供）；以及 **`#!/bin/sh` 脚本的 POSIX 兼容性**（不许出现 `${var:N}`、`[[` 等 bash 专有写法 —— CI 的 /bin/sh 是 dash） | 87 |
| `validate-docs.py` | 文档一致性：全部交叉引用能否落地、README §7.1 的断言数（标题 / 正文 / 分项之和）是否自洽、有无残留的过时说法 | 4 |
| `validate-workflow.py` | 工作流：13 个 `run` 块的 shell 语法、步骤顺序、`if: failure()` / `if: always()`、产物不含 `keys/`、**含 `*.tgz` 与 `*.bin`**、无硬编码凭据、`BR2_DL_DIR` 与缓存路径一致、以及**任何步骤都不得去读被忽略的 `keys/gs.key`**（仓库里没有这个文件，配 `set -e` 会让 job 必然失败 —— 真踩过一次） | 14 |

**这 206 项在两种 shell 下都跑过**：WSL 的 `dash`，以及 **busybox 1.37 的真实
`ash`**（设备上跑的就是它）—— 用 `sh -> busybox` 的 shim 让脚本内部所有
`sh xxx` 也走 ash。8 个 shell 脚本另经 `dash -n` 与 `bash -n` 语法检查，全过。

`start-smoke-test.sh` 会断言 `wfb_tx` 的实际参数是
`-M 1 -B 20 -k 8 -n 12 -i 7669206`，即你要求的
5.8G / 20MHz / MCS1 / FEC 8:12 / 链路 ID —— 参数写错立刻红。

### 7.2 真实 Buildroot 配置层验证：已通过

用 173 个逐文件下载的上游文件重建了够跑 kconfig 的最小树，真跑：

```
make BOARD=hi3518ev300_fpv_wfbng defconfig   ->  rc=0
```

18 个关键符号全部正确解析，kconfig **零未定义符号告警**，并与上游
`hi3518ev300_ultimate_defconfig` 做了差分：新增项恰好是预期的，
删除项恰好是主动裁掉的。细节见 `docs/网卡与传感器兼容性.md` §5.3。

**这一层证明了**：defconfig 语法与语义正确、两个新包已被 Kconfig 正确注册、
`wifibroadcast-ng` 的全部 `select` 依赖都落地了。

**这一层没证明**：两个新驱动在 4.9.37 上能否编译 —— 那需要真实工具链
（98.5 MB）与内核源码，本环境下载不到（见 §6 风险表下方说明）。

### 7.3 真实 Buildroot 包解析验证：已通过

把上游 164 个 `general/package/**/*.mk` 全部取齐后，让真实 Buildroot 做
**完整包解析**：

```
make BOARD=hi3518ev300_fpv_wfbng br-show-info     ->  rc=0
```

解析出 86 个包，两个新包都被正确登记：

| 包名 | version（= 固定的提交） | 依赖链 |
|---|---|---|

这个依赖链正是 `$(eval $(kernel-module))` + `$(eval $(generic-package))`
应有的形状 —— 说明两个 `.mk` 被正确解析、包名从文件名推导正确、
内核模块基础设施挂上了。`yaml-cli-multi` 也在登记表里（修之前根本不会出现）。

下载地址也逐个验过（`HTTP 200` + gzip 魔数）：

```
```

> ⚠️ 坑：`show-info` 的 `uris` 字段只显示 `…/archive/<sha>`（不带
> `<repo>-<ver>.tar.gz` 后缀），直接 curl 那个形式会 **404**。
> Buildroot 的 `github` 宏实际用的是带后缀的完整形式，已验证 200。
> 别被 show-info 的显示骗了 —— 我一开始就被骗了一次。

**这一层证明了**：两个 `.mk` 语法正确、包名推导正确、版本与下载地址有效。

**仍未证明**：编译能否通过（需要工具链，本环境拿不到）。

### 7.4 验证过程中抓到并修掉的问题

| # | 问题 | 性质 |
|---|---|---|
| 1 | `morrownr/8814au` 要求内核 5.4–6.18，在 4.9.37 上编不过 | 选源错误 → 换成 `aircrack-ng/rtl8814au` v5.8.5.1（该驱动最终**未编入**，见 §2） |
| 2 | 两个驱动 Makefile 都有 `ARCH ?= $(SUBARCH)`，交叉编译会变 x86_64 | 静默错架构 → 显式传 `ARCH=arm CROSS_COMPILE=$(TARGET_CROSS)` |
| 3 | **上游缺陷**：`yaml-cli-multi` 的 `Config.in` 存在且被 `select`，但上游 `Config.in` 从没 `source` 它 | 该二进制永远不进镜像，kconfig 不报警 → overlay 补上 `source` 行 |
| 4 | `detect_driver()` 在 `$( )` 里既打日志又返回值 | 日志污染驱动名 → 改为只输出驱动名 |
| 5 | `apply-overlay.sh` 用 `${BASH_SOURCE[0]}` | `sh`/dash 下 Bad substitution 且静默把路径解析错 → 改 `$0` 并整体 POSIX 化 |
| 6 | `ifconfig mtu 3994` 被驱动静默拒绝时，`naluSize` 仍按 3994 算 | 两者错配导致二次分片 → 设完回读 `/sys/class/net/*/mtu` 反推 naluSize |
| 7 | 打包的 `wfb.yaml` 把 `stbc`/`ldpc` 固定成 `0/0`，丢掉了上游按卡种的调优 | 8812au 本可 `1/1` → 按卡种写 yaml 并**立即刷新**变量（上游要等重启才生效） |
| 8 | `BR2_OPENIPC_VARIANT="fpv/wfbng"` 含斜杠 | ① 被直接拼进 tar 文件名，构建**最后一步**打包失败；② `$(filter fpv wfbng,…)` 按词匹配不到，静默丢掉 IMX307/IMX335 高帧率传感器库 → 改成 `"fpv"` |
| 9 | **上游默认 root 空密码 + dropbear `-B`（允许空密码登录）+ 板子有 `HISI_FEMAC` 以太网** | 出厂即免密可登录 → 代码层面不改上游行为，但在 defconfig、刷机文档 §7.1、本表三处明确警告，并给出「改成只认公钥」的命令 |
| 10 | **上游缺陷（与第 3 条叠加）**：`yaml-cli-multi.mk` 的 `VERSION` 两侧带字面单引号 | 修好 `source` 后它会真的构建，而下载地址变成 `.../archive/'sha'` → **HTTP 404**，构建在下载阶段失败 → overlay 里覆盖了一份去掉引号的 `.mk` |
| 11 | 镜像**不是逐字节可复现**：6 类包版本浮动（内核跟分支、majestic 滚动、四个包跟 HEAD） | 重建可能拿到不同内容，极端情况下行为或体积会变 | 工作流每次生成 `source-manifest.txt`（下载文件的 SHA-256 清单）；详见 §6.1 |
| 12 | **自己写错的上传路径**：固件 artifact 写的是 `*.tar` / `*.img` | 上游 `REPACK_NOR_SPLIT` 打出来的包是 `openipc.<soc>-nor-<variant>-split.tgz`，后缀 `.tgz` 不匹配 `*.tar` → 带 md5sum 的安装包根本不会进 artifact；`*.img` 更是一个文件都没有 → 已改为 `*.bin` + `*.tgz`，并加断言锁住 |

另外把上游脚本里的 `&> /dev/null` 改成 `>/dev/null 2>&1` ——
前者不是 POSIX，在部分 busybox ash 上不成立，后者到处都能用。

### 6.1 关于「可复现」的一点保留

目标里要求"可复现"。工程本身是可复现的（33 个文件、固定的 overlay、固定的
上游提交 `9f0639eb`），但**构建出的镜像不是逐字节可复现**，因为镜像里有若干
包的版本是浮动的。这是上游的设计，不是我引入的：

| 包 | 来源 | 为什么浮动 |
|---|---|---|
| `linux` | `openipc/linux` **分支** `hisilicon-hi3516ev200` | 跟分支不跟 SHA |
| `toolchain-external-custom` | release 资产 `toolchain.hisilicon-hi3516ev200.tgz` | 固定文件名，上游可覆盖 |
| `majestic` | S3 上的 `majestic.*.master.tar.bz2` | 文件名里就写着 master |
| `majestic-webui` | `releases/download/dist` | tag 固定但资产可替换 |
| `ipctool` / `mavfwd` / `msposd` / `yaml-cli` | GitHub `archive/HEAD` | 跟 HEAD |
| `cpu-models` | `releases/download/v2` | tag 固定但资产可替换 |

本工程自己新增或修改的三个包**都固定到了具体 SHA**：

`yaml-cli-multi` @ `a633865…`。上游的 `wifibroadcast-ng`、`hisilicon-opensdk`、
`jsonfilter` 等也已是 SHA 固定。

**能做的应对**（工作流已实现）：每次构建都生成 `source-manifest.txt`，记录
`work/dl` 里每个下载文件的 SHA-256，随构建日志一起作为 artifact 保存。用途是：

- 重建时与旧清单比对，知道哪些内容变了；
- 想彻底固定时，照着清单把对应的 `*_VERSION` 改成具体提交。

上游 `Makefile` 的 `prepare` 目标里也有一段注释，解释它为什么主动删除超过
24 小时的 `majestic` 缓存 —— 就是因为那两个是滚动资产。

第 3 条值得单独说：它是上游的真 bug，会让 `yaml-cli-multi` 在**任何** OpenIPC
镜像里都缺失，而 FPV 启动脚本正需要它。本工程修掉了。

第 10 条是第 3 条的**连带后果**，也是这一轮才发现的：正因为上游从没构建过
这个包，它 `.mk` 里 `VERSION` 两侧的字面单引号才一直没人碰到。修好 `source`
之后它会真的去下载，而地址会多出两个引号 —— 实测 404，构建在下载阶段就失败。
所以 overlay 里同时覆盖了一份去掉引号的 `.mk`。

---

## 8. 协议

叠加的脚本与配置沿用上游（GPL-2.0 / GPL-3.0）；本工程不含自建的驱动源码包 ——
两个驱动（`rtl8812au`、`rtl8733bu`）都用上游 `openipc/realtek-wlan` 的 FPV 分支，
由上游的 `rtl8812au-openipc` / `rtl8733bu-openipc` 包负责构建，协议随上游（GPL-2.0）。

评估过但未编入的两个：
- [libc0607/rtl88x2cu](https://github.com/libc0607/rtl88x2cu-20230728) —— 只声明支持内核 6.12，本平台 4.9.37 无依据
- [aircrack-ng/rtl8814au](https://github.com/aircrack-ng/rtl8814au) —— 4x4 卡，16MB 方案上体积不划算
见 `docs/网卡与传感器兼容性.md` §2 的驱动对照表。
