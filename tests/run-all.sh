#!/bin/sh
#
# 跑全部离线测试。不需要硬件、不需要 root、不需要联网。
#
#   sh tests/run-all.sh
#
# 覆盖：
#   detect-test.sh        网卡 VID:PID -> 驱动名映射（FPV 镜像）
#   start-smoke-test.sh   FPV 整条启动路径的桩测试
#   apfpv-test.sh         AP 推流镜像的桩测试（热点/DHCP/视频剖面）
#   apply-overlay-test.sh overlay 铺设与 Kconfig 注册
#
set -u

here=$(cd "$(dirname "$0")" && pwd)
fail=0

for t in detect-test.sh start-smoke-test.sh apfpv-test.sh apply-overlay-test.sh; do
	printf '\n================ %s ================\n' "$t"
	if sh "$here/$t"; then
		printf -- '---- %s OK\n' "$t"
	else
		printf -- '---- %s FAILED\n' "$t"
		fail=$((fail + 1))
	fi
done

printf '\n================================================\n'
if [ "$fail" -eq 0 ]; then
	printf '全部测试通过\n'
else
	printf '%d 个测试套件失败\n' "$fail"
fi

# 发布安全：用真实 git 验证 gs.key 不会入库、publish.sh 的闸门是硬性的
printf '\n================ gitignore-test.sh ================\n'
if sh "$here/gitignore-test.sh"; then
	printf -- '---- gitignore-test.sh OK\n'
else
	printf -- '---- gitignore-test.sh FAILED\n'
	fail=$((fail + 1))
fi

# 交付物内容回归测试：密钥 / 链路参数 / 视频参数 / defconfig
# 纯 python3 标准库，无外部依赖
if command -v python3 >/dev/null 2>&1; then
	printf '\n================ validate-config.py ================\n'
	if python3 "$here/validate-config.py"; then
		printf -- '---- validate-config.py OK\n'
	else
		printf -- '---- validate-config.py FAILED\n'
		fail=$((fail + 1))
	fi
fi

# 文档一致性：交叉引用能否落地、README 自称的断言数是否自洽、有无过时说法
if command -v python3 >/dev/null 2>&1; then
	printf '\n================ validate-docs.py ================\n'
	if python3 "$here/validate-docs.py"; then
		printf -- '---- validate-docs.py OK\n'
	else
		printf -- '---- validate-docs.py FAILED\n'
		fail=$((fail + 1))
	fi
fi

# 工作流校验需要 PyYAML；没装就 SKIP 并返回 0，不算失败
if command -v python3 >/dev/null 2>&1; then
	printf '\n================ validate-workflow.py ================\n'
	if python3 "$here/validate-workflow.py"; then
		printf -- '---- validate-workflow.py OK\n'
	else
		printf -- '---- validate-workflow.py FAILED\n'
		fail=$((fail + 1))
	fi
fi

[ "$fail" -eq 0 ] && exit 0
exit 1
