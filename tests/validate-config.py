#!/usr/bin/env python3
"""
需求回归测试：检查"交付的配置"是否仍然符合当初提的要求。

与 shell 测试的区别：那些测的是脚本行为，这个测的是**交付物内容**——
密钥、链路参数、视频参数、defconfig 关键项。

不依赖 PyYAML（wfb.yaml 结构固定，这里用极简的缩进解析）。

用法：
  python3 tests/validate-config.py
"""

import hashlib
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
fail = 0


def ok(m):
    print(f"PASS  {m}")


def bad(m):
    global fail
    fail += 1
    print(f"FAIL  {m}")


def path(*p):
    return os.path.join(ROOT, *p)


# ------------------------------------------------------------------ 极简 yaml
def parse_flat_yaml(text):
    """只支持两层：顶层 section + 两空格缩进的 key: value。够用于 wfb.yaml。"""
    out, cur = {}, None
    for raw in text.split("\n"):
        line = raw.rstrip()
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        if not line.startswith(" ") and line.rstrip().endswith(":"):
            cur = line.rstrip()[:-1].strip()
            out[cur] = {}
            continue
        m = re.match(r"^\s+([A-Za-z0-9_]+)\s*:\s*(.*)$", line)
        if m and cur:
            v = m.group(2).split("#", 1)[0].strip()
            out[cur][m.group(1)] = v
    return out


# ------------------------------------------------------------------ 1. 密钥
def check_keys():
    print("\n== 密钥 ==")
    dk, gk = path("keys", "drone.key"), path("keys", "gs.key")
    if not (os.path.isfile(dk) and os.path.isfile(gk)):
        bad("keys/drone.key 或 keys/gs.key 不存在")
        return

    d = open(dk, "rb").read()
    g = open(gk, "rb").read()

    # wfb-ng 的密钥文件是 64 字节：secret(32) ‖ 对端 public(32)
    if len(d) == 64 and len(g) == 64:
        ok("drone.key / gs.key 均为 64 字节（32B secret + 32B 对端公钥）")
    else:
        bad(f"密钥长度不对：drone={len(d)} gs={len(g)}")

    # 指纹表。注意：PUBKEYS.txt 里的 "pubkey" 是**公钥原始 32 字节的 hex**，
    # 不是摘要；"fp" 才是 sha256(pubkey) 的前 4 字节。
    pub, fp = {}, {}
    pf = path("keys", "PUBKEYS.txt")
    if os.path.isfile(pf):
        for line in open(pf, encoding="utf-8"):
            m = re.match(r"^\s*(drone|gs)\s+pubkey\s*:\s*([0-9a-f]{64})\s*$", line)
            if m:
                pub[m.group(1)] = bytes.fromhex(m.group(2))
            # 指纹每组 4 个十六进制字符，例如 fa71:3067:4df0:b754
            m = re.match(
                r"^\s*(drone|gs)\s+fp\s*:\s*"
                r"([0-9a-f]{4}:[0-9a-f]{4}:[0-9a-f]{4}:[0-9a-f]{4})\s*$", line)
            if m:
                fp[m.group(1)] = m.group(2)

    def fp_of(b):
        h = hashlib.sha256(b).hexdigest()[:16]
        return ":".join(h[i:i + 4] for i in range(0, 16, 4))

    if len(pub) == 2 and len(fp) == 2:
        # wfb-ng 的布局：drone.key = drone_secret ‖ gs_public
        #              gs.key    = gs_secret    ‖ drone_public
        if d[32:64] == pub["gs"]:
            ok("drone.key[32:64] 逐字节等于 GS 公钥")
        else:
            bad("drone.key[32:64] 不是 GS 公钥")
        if g[32:64] == pub["drone"]:
            ok("gs.key[32:64] 逐字节等于 drone 公钥")
        else:
            bad("gs.key[32:64] 不是 drone 公钥")

        # 指纹必须与公钥自洽
        if fp_of(pub["drone"]) == fp["drone"] and fp_of(pub["gs"]) == fp["gs"]:
            ok(f"指纹自洽：drone {fp['drone']} / gs {fp['gs']}")
        else:
            bad("PUBKEYS.txt 里的 fp 与 pubkey 对不上")

        # 两把私钥绝不能相同
        if d[0:32] != g[0:32]:
            ok("drone/gs 的 secret 不同（确实是一对，不是同一把）")
        else:
            bad("drone 与 gs 的 secret 相同！密钥生成有问题")
    else:
        bad("PUBKEYS.txt 里取不到 pubkey / fp 记录")

    # 打进镜像的那份必须与 keys/ 里的一致，否则刷进去的是旧密钥
    od = path("overlay", "general", "package", "wifibroadcast-ng", "files", "drone.key")
    if os.path.isfile(od):
        if open(od, "rb").read() == d:
            ok("overlay 里的 drone.key 与 keys/drone.key 完全一致")
        else:
            bad("overlay 里的 drone.key 与 keys/drone.key 不一致（会刷入旧密钥！）")
    else:
        bad("overlay 里没有 drone.key")


# ------------------------------------------------------------------ 2. 链路参数
def check_link():
    print("\n== 链路参数（wfb.yaml）==")
    p = path("overlay", "general", "package", "wifibroadcast-ng", "files", "wfb.yaml")
    if not os.path.isfile(p):
        bad("wfb.yaml 不存在")
        return
    y = parse_flat_yaml(open(p, encoding="utf-8").read())

    w, b = y.get("wireless", {}), y.get("broadcast", {})
    t = y.get("telemetry", {})

    # 5.8G 频段信道的常见取值
    ch = w.get("channel", "")
    if ch in ("149", "153", "157", "161", "165"):
        ok(f"channel={ch} 属于 5.8G 频段")
    else:
        bad(f"channel={ch!r} 不在 5.8G 常用信道里")

    if w.get("width") == "20":
        ok("width=20（20MHz）")
    else:
        bad(f"width={w.get('width')!r}，要求 20")

    if b.get("mcs_index") == "1":
        ok("mcs_index=1")
    else:
        bad(f"mcs_index={b.get('mcs_index')!r}，要求 1")

    if b.get("fec_k") == "8" and b.get("fec_n") == "12":
        ok("FEC 8:12")
    else:
        bad(f"FEC={b.get('fec_k')}:{b.get('fec_n')}，要求 8:12")

    if re.fullmatch(r"\d+", b.get("link_id", "")):
        ok(f"link_id={b['link_id']} 是整数")
    else:
        bad(f"link_id={b.get('link_id')!r} 不是整数")

    for k in ("stbc", "ldpc", "tun_index"):
        if k in b:
            ok(f"broadcast.{k}={b[k]} 存在")
        else:
            bad(f"broadcast.{k} 缺失")

    if t.get("router") in ("msposd", "mavfwd"):
        ok(f"telemetry.router={t['router']}")
    else:
        bad(f"telemetry.router={t.get('router')!r} 不是 msposd/mavfwd")

    if "serial" in t:
        ok(f"telemetry.serial={t['serial']}")
    else:
        bad("telemetry.serial 缺失（OSD 串口）")


# ------------------------------------------------------------------ 3. 视频参数
def check_video():
    print("\n== 视频参数（fpv-video.conf）==")
    p = path("overlay", "general", "overlay", "etc", "fpv-video.conf")
    if not os.path.isfile(p):
        bad("fpv-video.conf 不存在")
        return
    conf = {}
    for line in open(p, encoding="utf-8"):
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        k, v = line.split("=", 1)
        conf[k.strip()] = v.strip()

    if conf.get("VIDEO_CODEC") == "h264":
        ok("codec=h264（用户要求 H.264）")
    else:
        bad(f"codec={conf.get('VIDEO_CODEC')!r}，要求 h264")

    if conf.get("VIDEO_BITRATE") == "10000":
        ok("bitrate=10000 kbps（用户要求 10Mbps）")
    else:
        bad(f"bitrate={conf.get('VIDEO_BITRATE')!r}，要求 10000")

    ini = conf.get("SENSOR_INI", "")
    if ini == "/etc/sensors/jxf23_i2c_1080p.ini":
        ok("SENSOR_INI 指向 jxf23_i2c_1080p.ini（已核对上游会装到这里）")
    else:
        bad(f"SENSOR_INI={ini!r}，应为 /etc/sensors/jxf23_i2c_1080p.ini")

    # 720p60 交付不了，交付的是 1080p30；这里断言的是"实际交付值"，
    # 偏差已写在 README §1.1
    if conf.get("VIDEO_SIZE") == "1920x1080" and conf.get("VIDEO_FPS") == "30":
        ok("size=1920x1080 fps=30（F23 只有 1080p30，见 README §1.1）")
    else:
        bad(f"size/fps={conf.get('VIDEO_SIZE')}@{conf.get('VIDEO_FPS')}，与文档不一致")


# ------------------------------------------------------------------ 4. defconfig
def check_defconfig():
    print("\n== defconfig 关键项 ==")
    p = path("overlay", "br-ext-chip-hisilicon", "configs",
             "hi3518ev300_fpv_wfbng_defconfig")
    if not os.path.isfile(p):
        bad("defconfig 不存在")
        return
    txt = open(p, encoding="utf-8").read()

    def sym(name):
        m = re.search(rf'^{re.escape(name)}="?([^"\n]*)"?$', txt, re.M)
        return m.group(1) if m else None

    if sym("BR2_OPENIPC_SOC_MODEL") == "hi3518ev300":
        ok("SOC_MODEL=hi3518ev300")
    else:
        bad(f"SOC_MODEL={sym('BR2_OPENIPC_SOC_MODEL')!r}")

    if sym("BR2_OPENIPC_SNS_MODEL") == "f23":
        ok("SNS_MODEL=f23")
    else:
        bad(f"SNS_MODEL={sym('BR2_OPENIPC_SNS_MODEL')!r}")

    if sym("BR2_OPENIPC_FLASH_SIZE") == "16":
        ok("FLASH_SIZE=16（16MB SPI NOR）")
    else:
        bad(f"FLASH_SIZE={sym('BR2_OPENIPC_FLASH_SIZE')!r}")

    variant = sym("BR2_OPENIPC_VARIANT") or ""
    # 三条约束，任何一条踩了都会出问题：
    #   a) 上游 rtl8733bu-openipc.mk 用 $(findstring fpv,$(variant)) 选分支，
    #      不含 "fpv" 会拉到未打注入补丁的分支
    #   b) 它被直接拼进产物文件名（Makefile 三处 tar -czf），含斜杠会让 tar
    #      在构建最后一步失败
    #   c) hisilicon-opensdk / majestic-webui 用 $(filter fpv wfbng,...) 按词
    #      匹配，所以必须是单个词
    if "fpv" not in variant:
        bad(f"VARIANT={variant!r} 不含 'fpv'，rtl8733bu 会选错分支")
    elif "/" in variant or " " in variant:
        bad(f"VARIANT={variant!r} 含斜杠或空格："
            f"会被拼进 tar 文件名导致打包失败，且 filter 匹配不到")
    else:
        ok(f"VARIANT={variant!r} 是单个词、含 'fpv'（打包与分支选择都安全）")

    for pkg in ("RTL8812AU_OPENIPC", "RTL8733BU_OPENIPC",
                "WIFIBROADCAST_NG"):
        if f"BR2_PACKAGE_{pkg}=y" in txt:
            ok(f"{pkg}=y")
        else:
            bad(f"{pkg} 未启用")

    # RTL8812CU 已主动移除：唯一驱动只声明支持内核 6.12，本平台 4.9.37
    if "BR2_PACKAGE_RTL88X2CU_OPENIPC=y" in txt:
        bad("RTL88X2CU 又被启用了 —— 它没有 4.9 依据，且已从 overlay 删除")
    else:
        ok("RTL8812CU 未被启用（只有两个驱动：8812AU / 8733BU）")

    # RTL8814AU 同样已移除：4x4 卡在 16MB 方案上体积不划算。
    # 移除后 overlay 里没有任何自建驱动包，两个驱动都走上游现成的包。
    if "BR2_PACKAGE_RTL8814AU_OPENIPC=y" in txt:
        bad("RTL8814AU 又被启用了 —— 已从 overlay 删除")
    else:
        ok("RTL8814AU 未被启用")


def check_apfpv():
    """AP 推流镜像：与 FPV 那份是两个产物，必须各自自洽。"""
    print("\n== AP 推流 defconfig ==")
    p = path("overlay", "br-ext-chip-hisilicon", "configs",
             "hi3518ev300_apfpv_defconfig")
    if not os.path.isfile(p):
        bad("apfpv defconfig 不存在")
        return
    txt = open(p, encoding="utf-8").read()

    def sym(name):
        m = re.search(rf'^{re.escape(name)}="?([^"\n]*)"?$', txt, re.M)
        return m.group(1) if m else None

    if sym("BR2_OPENIPC_VARIANT") == "apfpv":
        ok("VARIANT=apfpv")
    else:
        bad(f"VARIANT={sym('BR2_OPENIPC_VARIANT')!r}")

    # apfpv 不是整词 fpv/wfbng，所以 hisilicon-opensdk 与 majestic-webui 的
    # $(filter fpv wfbng,...) 不命中；但 rtl8733bu 用 $(findstring fpv,...)，
    # 仍会选到 rtl8733bu_fpv 分支。这两条是主动选择，此处钉住其前提。
    if "fpv" in (sym("BR2_OPENIPC_VARIANT") or ""):
        ok("变体含 'fpv' 子串（rtl8733bu 仍选 _fpv 分支）")
    else:
        bad("变体不含 'fpv' —— rtl8733bu 会拿到未打注入补丁的分支")

    if sym("BR2_OPENIPC_SOC_MODEL") == "hi3518ev300" \
            and sym("BR2_OPENIPC_SNS_MODEL") == "f23" \
            and sym("BR2_OPENIPC_FLASH_SIZE") == "16":
        ok("SoC/传感器/flash 与 FPV 版一致（hi3518ev300 / f23 / 16MB）")
    else:
        bad("SoC/传感器/flash 与 FPV 版不一致")

    for pkg in ("APFPV", "RTW_HOSTAPD", "MAJESTIC",
                "RTL8812AU_OPENIPC", "RTL8733BU_OPENIPC"):
        if f"BR2_PACKAGE_{pkg}=y" in txt:
            ok(f"{pkg}=y")
        else:
            bad(f"{pkg} 未启用")

    # 纯 AP 推流不用 wfb-ng：选了它等于又把密钥和地面端依赖拖回来
    if "BR2_PACKAGE_WIFIBROADCAST_NG=y" in txt:
        bad("apfpv 镜像启用了 WIFIBROADCAST_NG —— 纯 AP 模式不需要 wfb-ng")
    else:
        ok("没有启用 WIFIBROADCAST_NG（纯 AP 模式）")

    # 不选 libopenssl 时 rtw-hostapd 用 CONFIG_TLS=internal，WPA2-PSK 够用，
    # 省掉约 1.3MB。若哪天被别的包拖进来，这条会提醒复核体积。
    if "BR2_PACKAGE_LIBOPENSSL=y" in txt:
        bad("显式选了 LIBOPENSSL —— 会让 hostapd 链 openssl，多吃约 1.3MB")
    else:
        ok("没有显式选 LIBOPENSSL（hostapd 走 internal TLS）")

    for f in ("Config.in", "apfpv.mk", "files/apfpv", "files/S50apfpv",
              "files/apfpv.conf", "files/apfpv-video.conf"):
        q = path("overlay", "general", "package", "apfpv", f)
        if os.path.isfile(q):
            ok(f"apfpv 包文件 {f}")
        else:
            bad(f"apfpv 包缺文件 {f}")

    # FPV 镜像不应装上 AP 的东西：apfpv 只在 apfpv 变体里被选中
    fp = path("overlay", "br-ext-chip-hisilicon", "configs",
              "hi3518ev300_fpv_wfbng_defconfig")
    if os.path.isfile(fp):
        ftxt = open(fp, encoding="utf-8").read()
        if "BR2_PACKAGE_APFPV=y" in ftxt:
            bad("FPV 镜像也选了 APFPV —— 两个产物会互相污染")
        else:
            ok("FPV 镜像没有选 APFPV（两个产物互不污染）")


def check_docs():
    """文档完整性：有些承诺必须写在交付物里，不能被后来改动悄悄删掉。"""
    print("\n== 文档承诺 ==")

    d = open(path("overlay", "br-ext-chip-hisilicon", "configs",
                  "hi3518ev300_fpv_wfbng_defconfig"), encoding="utf-8").read()
    if "允许空密码登录" in d or "空密码" in d:
        ok("defconfig 里保留了「root 空密码」的警告")
    else:
        bad("defconfig 里没有空密码警告 —— 这是上游默认，用户必须被提醒")

    doc = path("docs", "刷机与使用说明.md")
    if os.path.isfile(doc):
        t = open(doc, encoding="utf-8").read()
        if "passwd root" in t:
            ok("刷机文档给出了 passwd root 的处置办法")
        else:
            bad("刷机文档没提 passwd root")
        if "-B" in t and "空密码" in t:
            ok("刷机文档解释了 dropbear -B 的含义")
        else:
            bad("刷机文档没解释 dropbear -B")
        if "SENSOR_INI" in t and "jxf23_i2c_1080p.ini" in t:
            ok("刷机文档含传感器 ini 路径（排障用）")
        else:
            bad("刷机文档缺传感器 ini 路径")
        # 刷机命令的正确性：写死长度会把 RAM 垃圾烧进 flash
        if "${filesize}" in t:
            ok("刷机文档用 ${filesize} 而不是写死长度")
        else:
            bad("刷机文档没写 ${filesize} —— 写死长度会把 RAM 垃圾烧进 flash")
        if "-split.tgz" in t:
            ok("刷机文档提到 -split.tgz 安装包")
        else:
            bad("刷机文档没提 -split.tgz（CI 产出的正是这个包）")
        if "microsnander -l" in t:
            ok("编程器步骤让用户先列芯片型号，而不是照抄参数")
        else:
            bad("编程器步骤给了未经验证的具体参数")
        # 备份步骤必须提醒 /dev/mtd0 不是整片
        if "/proc/mtd" in t and "16777216" in t:
            ok("备份步骤说明了按分区读、并校验总大小 16 MiB")
        else:
            bad("备份步骤可能让用户以为 dd if=/dev/mtd0 就是整片备份")
        if "15808" in open(path("docs", "网卡与传感器兼容性.md"),
                           encoding="utf-8").read():
            ok("兼容性文档含 firmware.bin 的 15808 KiB 上限")
        else:
            bad("兼容性文档缺 15808 KiB 上限说明")
        compat = open(path("docs", "网卡与传感器兼容性.md"),
                      encoding="utf-8").read()
        if "MAJESTIC_DEPENDENCIES" in compat:
            ok("兼容性文档交代了 opus/libogg 为何裁不掉（majestic 硬依赖）")
        else:
            bad("兼容性文档没说明 opus/libogg 无法通过 kconfig 裁掉")

        rd = open(path("README.md"), encoding="utf-8").read()
        if "source-manifest.txt" in rd:
            ok("README 提到 source-manifest.txt（可复现性应对已交代）")
        else:
            bad("README 没提 source-manifest.txt —— 目标要求可复现，必须说明")
        if "hisilicon-hi3516ev200" in rd and "浮动" in rd:
            ok("README 交代了内核跟分支等浮动项")
        else:
            bad("README 没说明哪些包版本浮动")
    else:
        bad("缺 docs/刷机与使用说明.md")


def check_upstream_fixes():
    """上游缺陷的修正必须还在，否则构建会在下载阶段 404。"""
    print("\n== 上游缺陷修正 ==")

    mk = path("overlay", "general", "package", "yaml-cli-multi", "yaml-cli-multi.mk")
    if not os.path.isfile(mk):
        bad("overlay 里没有 yaml-cli-multi.mk（上游那份带引号的 VERSION 会 404）")
        return
    txt = open(mk, encoding="utf-8").read()
    m = re.search(r"^YAML_CLI_MULTI_VERSION\s*=\s*(\S+)\s*$", txt, re.M)
    if not m:
        bad("yaml-cli-multi.mk 里找不到 VERSION 赋值")
        return
    ver = m.group(1)
    if "'" in ver or '"' in ver:
        bad(f"VERSION 仍带引号（{ver}）—— 下载地址会 404")
    elif re.fullmatch(r"[0-9a-f]{40}", ver):
        ok(f"yaml-cli-multi VERSION 是干净的 40 位 SHA（{ver[:8]}…）")
    else:
        bad(f"VERSION={ver!r} 既不带引号也不是 40 位 SHA")

    # 上游的 Config.in 存在于 general/package/yaml-cli-multi/，缺的是
    # general/package/Config.in 里那行 source —— 由 patch-config-in.py 插入。
    # 注意它不在 overlay 里：overlay 只放上游没有的文件。
    patcher = path("scripts", "patch-config-in.py")
    if os.path.isfile(patcher):
        body = open(patcher, encoding="utf-8").read()
        if "yaml-cli-multi" in body:
            ok("patch-config-in.py 里有 yaml-cli-multi 的 source 规则")
        else:
            bad("patch-config-in.py 里没有 yaml-cli-multi 规则（包不会被注册）")
    else:
        bad("缺 scripts/patch-config-in.py")


def check_module_names():
    """运行期 modprobe 的名字必须与驱动实际产出的 .ko 一致。

    这里锁的是具体事实：OpenIPC 的 rtl8812au_fpv 分支里
    HAL_RTL8812A 段的 MODULE_NAME 无条件等于 8812au（aircrack 的 fork
    才叫 88XXau）。名字错了 modprobe 就找不到模块，表现为「没有图传」。
    """
    print("\n== 模块名一致性 ==")
    sc = path("overlay", "general", "package", "wifibroadcast-ng",
              "files", "wifibroadcast")
    if not os.path.isfile(sc):
        bad("找不到运行期脚本")
        return
    t = open(sc, encoding="utf-8").read()

    m = re.search(r"ALL_DRIVERS=\"([^\"]+)\"", t)
    if not m:
        bad("脚本里找不到 ALL_DRIVERS")
        return
    drivers = m.group(1).split()

    expect = {
        "8812au": "openipc/realtek-wlan rtl8812au_fpv",
        "8733bu": "openipc/realtek-wlan rtl8733bu_fpv",
    }
    for name, src in expect.items():
        if name in drivers:
            ok(f"{name} 在 ALL_DRIVERS 里（{src}）")
        else:
            bad(f"{name} 不在 ALL_DRIVERS 里 —— 驱动卸载不干净")

    # driver_of_pid 对 0bda:8812 必须返回 8812au
    blk = re.search(r"0bda:8812\|[^\n]*\n\s*echo (\S+)", t)
    if blk:
        got = blk.group(1)
        if got == "8812au":
            ok("driver_of_pid 把 0bda:8812 映射到 8812au")
        else:
            bad(f"driver_of_pid 把 0bda:8812 映射到 {got}，应为 8812au")
    else:
        bad("找不到 0bda:8812 的映射")

    if "88XXau) alt_name=88XXau" in t or "8812au) alt_name=88XXau" in t:
        ok("8812au → 88XXau 有回退名")
    else:
        bad("8812au 没有回退名")

    compat = open(path("docs", "网卡与传感器兼容性.md"), encoding="utf-8").read()
    if "两个分支各叫一个名" in compat:
        ok("文档解释了 8812au / 88XXau 的差别")
    else:
        bad("文档没说清 8812au 与 88XXau 的来源差异")


def check_runtime_deps():
    """运行期脚本用到的每个外部命令，都必须有明确的提供者。

    这类缺失不会让构建失败，只会让板子上「什么都不工作」，且日志里往往
    只有一句 command not found。所以逐个把来源钉住：

      busybox applet  <- 上游 general/package/busybox/busybox.config
                         （已核对 CONFIG_LSUSB=y / CONFIG_MODPROBE=y /
                           CONFIG_IFCONFIG=y / CONFIG_IP=y）
      固件 overlay    <- general/overlay/usr/sbin/cli
      包 select       <- wifibroadcast-ng 的 Config.in
      自身            <- wfb_tx / wfb_rx / wfb_tun 由 wifibroadcast-ng 产出
    """
    print("\n== 运行期命令的来源 ==")
    # 这些事实在上游树里（本仓库是 overlay，不复制上游文件）。
    # 设 UPSTREAM_TREE=<openipc-firmware 检出> 才做完整核对；否则明确 SKIP。
    up = os.environ.get("UPSTREAM_TREE", "")
    cfg = os.path.join(up, "general", "package", "wifibroadcast-ng", "Config.in")
    bb = os.path.join(up, "general", "package", "busybox", "busybox.config")
    cli = os.path.join(up, "general", "overlay", "usr", "sbin", "cli")
    if not up or not os.path.isfile(cfg):
        print("  SKIP  未设 UPSTREAM_TREE（或其中没有上游树），跳过")
        print("        用 UPSTREAM_TREE=/path/to/openipc-firmware 可完整核对")
        return
    t = open(cfg, encoding="utf-8").read()

    need_select = {
        "BR2_PACKAGE_IW": "iw（设 monitor / 信道 / 功率）",
        "BR2_PACKAGE_JSONFILTER": "jsonfilter（读 majestic 的视频尺寸）",
        "BR2_PACKAGE_YAML_CLI": "yaml-cli（读写 wfb.yaml）",
        "BR2_PACKAGE_YAML_CLI_MULTI": "yaml-cli-multi（写入 wlan_adapter）",
        "BR2_PACKAGE_LIBCURL_OPENIPC_CURL": "curl 二进制（不是仅库）",
        "BR2_PACKAGE_MAVFWD": "mavfwd（MAVLink 转发）",
        "BR2_PACKAGE_MSPOSD": "msposd（OSD）",
    }
    for sym, why in need_select.items():
        if f"select {sym}" in t:
            ok(f"{sym} 被 select（{why}）")
        else:
            bad(f"{sym} 没被 select —— {why} 会缺")

    # busybox 真的编了这些 applet 吗
    if os.path.isfile(bb):
        b = open(bb, encoding="utf-8").read()
        for sym, cmd in (("CONFIG_LSUSB", "lsusb"),
                         ("CONFIG_MODPROBE", "modprobe"),
                         ("CONFIG_IFCONFIG", "ifconfig"),
                         ("CONFIG_KILLALL", "killall"),
                         ("CONFIG_PIDOF", "pidof")):
            if re.search(rf"^{sym}=y$", b, re.M):
                ok(f"{cmd} 由 busybox 提供（{sym}=y）")
            else:
                bad(f"{sym} 没开 —— 脚本里的 {cmd} 会 command not found")

    # cli 由固件 overlay 提供
    if os.path.isfile(cli):
        ok("cli 由上游 overlay 的 /usr/sbin/cli 提供")
    else:
        bad("上游 overlay 里没有 /usr/sbin/cli，而脚本要用它设 naluSize")


def check_posix_shell():
    """#!/bin/sh 的脚本里不能有 bash 专有写法。

    `sh -n` 只查语法，查不出 ${var:0:7} 这类「语法合法但 dash 运行时直接
    Bad substitution」的写法 —— apply-overlay.sh 就栽在这上面，而 CI 里
    /bin/sh 正是 dash，会在铺 overlay 的第一步挂掉。

    检测前必须先剥掉整行注释和单引号串，否则 '^keys/gs\\.key$' 里的
    「行尾锚点 $ + 收尾引号」会被误判成 bash 的 $'...' 语法。
    """

    def strip_for_check(text):
        kept = []
        for line in text.split("\n"):
            if line.lstrip().startswith("#"):
                continue
            kept.append(re.sub(r"'[^']*'", "''", line))
        return "\n".join(kept)

    print("\n== POSIX sh 兼容性 ==")
    targets = []
    for d in ("scripts", "tests"):
        for f in sorted(os.listdir(path(d))):
            if not f.endswith(".sh"):
                continue
            p = path(d, f)
            with open(p, encoding="utf-8") as fh:
                first = fh.readline()
            if first.startswith("#!") and "/bin/sh" in first and "bash" not in first:
                targets.append((f"{d}/{f}", open(p, encoding="utf-8").read()))

    wf = path("overlay", "general", "package", "wifibroadcast-ng", "files",
              "wifibroadcast")
    if os.path.isfile(wf):
        targets.append(("wifibroadcast", open(wf, encoding="utf-8").read()))

    bad_patterns = [
        (r"\$\{[A-Za-z_][A-Za-z0-9_]*:[0-9]", "${var:N} 子串截取（bash 专有）"),
        (r"\$\{[A-Za-z_][A-Za-z0-9_]*//", "${var//x/y} 替换（bash 专有）"),
        (r"\[\[", "[[ ]] 测试（bash 专有）"),
        (r"^\s*function\s+\w+", "function 关键字（bash 专有）"),
        (r"\bdeclare\s", "declare（bash 专有）"),
        (r"\$\{[A-Za-z_][A-Za-z0-9_]*\[@\]", "数组展开（bash 专有）"),
    ]
    for name, text in targets:
        body = strip_for_check(text)
        hits = []
        for pat, why in bad_patterns:
            for m in re.finditer(pat, body, re.M):
                line = body[:m.start()].count("\n") + 1
                hits.append(f"{name}:{line} {why}")
        if hits:
            for h in hits:
                bad(f"POSIX 违规 {h}")
        else:
            ok(f"{name} 无 bash 专有写法")


def main():
    check_keys()
    check_link()
    check_video()
    check_defconfig()
    check_apfpv()
    check_upstream_fixes()
    check_module_names()
    check_runtime_deps()
    check_posix_shell()
    check_docs()
    print()
    if fail:
        print(f"失败 {fail} 项")
        return 1
    print("全部通过")
    return 0


if __name__ == "__main__":
    sys.exit(main())
