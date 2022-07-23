# SPDX-License-Identifier: GPL-2.0-only

include $(TOPDIR)/rules.mk

PKG_NAME:=usteer
PKG_SOURCE_DATE:=2022-08-18
PKG_SOURCE_VERSION:=7d2b17c91baf67419c0ce63dc6c65a7659ab6a5c
PKG_RELEASE:=1
PKG_VERSION:=20220819

PKG_SOURCE_URL:=https://codeload.github.com/fakemesh/usteer/tar.gz/$(PKG_VERSION)?
PKG_HASH:=5672f881ab9c52e0c07d757b33425f1664d1e9febf639405a2634dfd2514465c
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
