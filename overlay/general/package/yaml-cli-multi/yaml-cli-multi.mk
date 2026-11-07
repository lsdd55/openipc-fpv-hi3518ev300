################################################################################
#
# yaml-cli-multi —— OpenIPC 上游包的修正版
#
# 本文件覆盖 general/package/yaml-cli-multi/yaml-cli-multi.mk，只改一处：
#
#   上游：  YAML_CLI_MULTI_VERSION = 'a633865b5202dcd1f4f548e8486d3a334c79c03c'
#   本工程：YAML_CLI_MULTI_VERSION = a633865b5202dcd1f4f548e8486d3a334c79c03c
#
# 即去掉 SHA 两侧的字面单引号。make 不剥单引号，值会原样进入 $(call github,…)
# 拼出的下载地址：
#
#   https://github.com/vertexodessa/yaml-cli-multi/archive/'a633865…'   -> HTTP 404
#   https://github.com/vertexodessa/yaml-cli-multi/archive/a633865…     -> HTTP 200 + gzip
#
# 为什么上游一直没暴露：general/package/Config.in 从来没有 source 这个包的
# Config.in，所以它永远不进 .config、永远不会被构建，那个坏 URL 也就没人碰。
# 本工程为了让 wifibroadcast-ng 的 select 真正生效，在 overlay 里补了 source
# 行（见同目录 Config.in 的说明）—— 一旦它会真的构建，这个引号就必须一起修，
# 否则构建会在下载阶段 404 失败。
#
# 其余内容与上游一致，不做任何功能改动。
#
################################################################################

YAML_CLI_MULTI_SITE = $(call github,vertexodessa,yaml-cli-multi,$(YAML_CLI_MULTI_VERSION))
YAML_CLI_MULTI_VERSION = a633865b5202dcd1f4f548e8486d3a334c79c03c

YAML_CLI_MULTI_LICENSE = GPL-3.0
YAML_CLI_MULTI_LICENSE_FILES = LICENSE


ifeq ($(BR2_TOOLCHAIN_USES_GLIBC),y)
	YAML_CLI_MULTI_OPTIONS = "-rdynamic -s -Os -lm"
else
	YAML_CLI_MULTI_OPTIONS = "-rdynamic -s -Os"
endif

define YAML_CLI_MULTI_BUILD_CMDS
	@echo "Building yaml-cli-multi"
	$(MAKE) CC=$(TARGET_CC) OPT=$(YAML_CLI_MULTI_OPTIONS) -C $(@D)
endef

define YAML_CLI_MULTI_INSTALL_TARGET_CMDS
	$(INSTALL) -m 755 -d $(TARGET_DIR)/usr/bin

	$(INSTALL) -m 755 -t $(TARGET_DIR)/usr/bin $(@D)/yaml-cli-multi
endef

$(eval $(generic-package))
