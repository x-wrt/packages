#
# This software is licensed under the Public Domain.
#

include $(TOPDIR)/rules.mk

PKG_NAME:=dawn
PKG_SOURCE_DATE:=2023-09-11
PKG_VERSION:=20230911

PKG_SOURCE_URL:=https://codeload.github.com/fakemesh/dawn/tar.gz/$(PKG_VERSION)?
PKG_HASH:=decf5920ad6f394ea9034591b658f4174a99ff2063dab7249220a41f79babf96
PKG_SOURCE:=$(PKG_NAME)-$(PKG_VERSION).tar.gz

PKG_MAINTAINER:=Nick Hainke <vincent@systemli.org>
PKG_LICENSE:=GPL-2.0-only
PKG_LICENSE_FILES:=LICENSE

PKG_BUILD_FLAGS:=no-lto

include $(INCLUDE_DIR)/package.mk
include $(INCLUDE_DIR)/cmake.mk

define Package/dawn
  SECTION:=net
  CATEGORY:=Network
  TITLE:=Decentralized wifi controller
  URL:=https://github.com/berlin-open-wireless-lab/DAWN.git
  DEPENDS:=$(DRV_DEPENDS) +libubus +libubox +libblobmsg-json +libuci +libgcrypt +libiwinfo +umdns
endef

define Package/dawn/description
  This package implements a decentralized wireless daemon.
endef

define Package/dawn/conffiles
/etc/config/dawn
endef

define Package/dawn/install
	$(INSTALL_DIR) $(1)/usr/sbin
	$(INSTALL_BIN) $(PKG_INSTALL_DIR)/usr/sbin/dawn $(1)/usr/sbin/dawn
	$(INSTALL_DIR) $(1)/etc/init.d
	$(INSTALL_BIN) ./files/dawn.init $(1)/etc/init.d/dawn
	$(INSTALL_DIR) $(1)/etc/config
	$(INSTALL_CONF) ./files/dawn.config $(1)/etc/config/dawn
endef

$(eval $(call BuildPackage,dawn))
