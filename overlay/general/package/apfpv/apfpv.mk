################################################################################
#
# apfpv
#
# 纯本地包：没有上游可下载，内容就是 files/ 里那几个文件。
# 用 SITE_METHOD = local 让 Buildroot 把它们 rsync 到 $(@D)，
# 与上游 majestic-fonts 的做法一致。
#
################################################################################

APFPV_VERSION = 1.0
APFPV_LICENSE = MIT
APFPV_SITE = $(APFPV_PKGDIR)/files
APFPV_SITE_METHOD = local

define APFPV_INSTALL_TARGET_CMDS
	$(INSTALL) -D -m 0755 $(@D)/apfpv $(TARGET_DIR)/usr/bin/apfpv
	$(INSTALL) -D -m 0755 $(@D)/S50apfpv $(TARGET_DIR)/etc/init.d/S50apfpv
	$(INSTALL) -D -m 0644 $(@D)/apfpv.conf $(TARGET_DIR)/etc/apfpv.conf
	$(INSTALL) -D -m 0644 $(@D)/apfpv-video.conf $(TARGET_DIR)/etc/apfpv-video.conf
endef

$(eval $(generic-package))
