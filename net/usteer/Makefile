# SPDX-License-Identifier: GPL-2.0-only

include $(TOPDIR)/rules.mk

PKG_NAME:=usteer
PKG_SOURCE_DATE:=2025-10-04
PKG_SOURCE_VERSION:=1d6524c6e6b58853f053c7816249a8f68ad9b0e8
PKG_RELEASE:=1
PKG_VERSION:=20251009

PKG_SOURCE_URL:=https://codeload.github.com/fakemesh/usteer/tar.gz/$(PKG_VERSION)?
PKG_HASH:=40e83474eda801ecda55c08164e9ccca04c8488608c1c8f9d44910bff540ea49
PKG_SOURCE:=$(PKG_NAME)-$(PKG_VERSION).tar.gz

PKG_MAINTAINER:=David Bauer <mail@david-bauer.net>
PKG_LICENSE:=GPL-2.0-only

PKG_BUILD_DEPENDS:=libpcap

include $(INCLUDE_DIR)/package.mk
include $(INCLUDE_DIR)/cmake.mk

define Package/usteer
  SECTION:=net
  CATEGORY:=Network
  DEPENDS:=+libubox +libubus +libblobmsg-json +libnl-tiny
  TITLE:=OpenWrt AP roaming assist daemon
endef

define Package/usteer/conffiles
/etc/config/usteer
endef

define Package/usteer/install
	$(INSTALL_DIR) $(1)/sbin $(1)/etc/init.d $(1)/etc/config

	$(CP) $(PKG_BUILD_DIR)/openwrt/usteer/files/etc/config/usteer $(1)/etc/config/usteer

	$(INSTALL_BIN) $(PKG_BUILD_DIR)/openwrt/usteer/files/etc/init.d/usteer $(1)/etc/init.d/usteer
	$(INSTALL_BIN) $(PKG_INSTALL_DIR)/usr/sbin/usteerd $(1)/sbin/usteerd
endef

$(eval $(call BuildPackage,usteer))
