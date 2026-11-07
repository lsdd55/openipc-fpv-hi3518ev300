#!/usr/bin/env python3
"""
在 OpenIPC 的 general/package/Config.in 里补齐缺失的 source 行。

为什么需要它：Buildroot 只承认从某个 Config.in 里 source 进来的包，
新包目录光放进去不会出现在 Kconfig 里。

当前处理两类条目：

  1) apfpv —— 本项目自己写的包（AP 推流模式的脚本与配置），上游没有，
     必须注册。插入位置保持字母序：apfpv 排在 atbm-wifi 之前。

  2) yaml-cli-multi —— **上游缺陷**。general/package/yaml-cli-multi/Config.in
     存在且定义了 BR2_PACKAGE_YAML_CLI_MULTI，
     wifibroadcast-ng/Config.in 与 adaptive-link/Config.in 都在
     select BR2_PACKAGE_YAML_CLI_MULTI，但 general/package/Config.in
     里没有对应的 source 行（实测上游 9f0639e 的 Config.in 共 165 行，
     'yaml-cli-multi' 出现 0 次）。
     后果：该符号永远不进 .config，yaml-cli-multi 二进制不会被编进任何镜像，
     而 FPV 启动脚本要用它把 wlan_adapter 写进 /etc/wfb.yaml。
     kconfig 不会对此报警，所以是个静默失败。

设计取向：
  - 幂等：已在就跳过，重复执行不产生重复行
  - 有锚点校验：锚点行不存在就报错退出，不静默跳过
    （上游改了 Config.in 结构时，我们要立刻知道，而不是编译到一半
     才发现包没进 Kconfig）
  - 插入位置保持字母序
  - 若被指向的 Config.in 不存在，拒绝插入（避免制造悬空 source）
"""

import os
import sys

# (插入行, 锚点行, 'before'|'after', 被指向的文件路径, 说明)
RULES = [
    (
        'source "$BR2_EXTERNAL_GENERAL_PATH/package/apfpv/Config.in"',
        'source "$BR2_EXTERNAL_GENERAL_PATH/package/atbm-wifi/Config.in"',
        'before',
        'apfpv/Config.in',
        '新增包：apfpv（AP 推流模式，仅 apfpv 变体选中）',
    ),
    (
        'source "$BR2_EXTERNAL_GENERAL_PATH/package/yaml-cli-multi/Config.in"',
        'source "$BR2_EXTERNAL_GENERAL_PATH/package/yaml-cli/Config.in"',
        'after',
        'yaml-cli-multi/Config.in',
        '修复上游缺陷：yaml-cli-multi 被 select 却从没被 source',
    ),
]


def main() -> int:
    if len(sys.argv) != 2:
        print(f"usage: {sys.argv[0]} <path/to/general/package/Config.in>",
              file=sys.stderr)
        return 2

    path = sys.argv[1]
    if not os.path.isfile(path):
        print(f"ERROR: 找不到 {path}", file=sys.stderr)
        return 1

    pkgdir = os.path.dirname(path)

    with open(path, "r", encoding="utf-8") as f:
        lines = f.read().split("\n")

    rc = 0
    for insert, anchor, where, target, why in RULES:
        if insert in lines:
            print(f"[config.in] 已存在，跳过：{why}")
            continue

        if anchor not in lines:
            print(f"ERROR: 锚点行不在 {path} 里：\n  {anchor}\n"
                  f"（规则：{why}）\n"
                  f"上游改了结构，请更新 patch-config-in.py 的 RULES。",
                  file=sys.stderr)
            rc = 1
            continue

        if not os.path.isfile(os.path.join(pkgdir, target)):
            print(f"ERROR: 目标 Config.in 不存在，拒绝插入悬空 source：\n"
                  f"  {os.path.join(pkgdir, target)}",
                  file=sys.stderr)
            rc = 1
            continue

        idx = lines.index(anchor)
        pos = idx if where == 'before' else idx + 1
        lines.insert(pos, insert)
        print(f"[config.in] 已插入（{why}）:\n  {insert}")

    if rc == 0:
        with open(path, "w", encoding="utf-8") as f:
            f.write("\n".join(lines))

    return rc


if __name__ == "__main__":
    raise SystemExit(main())
