#
# Copyright (C) 2021 Jianhui Zhao <zhaojh329@gmail.com>
#
# This is free software, licensed under the GNU General Public License v2.
# See /LICENSE for more information.
#

include $(TOPDIR)/rules.mk
include $(INCLUDE_DIR)/kernel.mk

PKG_NAME:=ovpn-backports
PKG_VERSION:=7.3.0.2026100801
PKG_RELEASE:=2

PKG_SOURCE:=$(PKG_NAME)-$(PKG_VERSION).tar.gz
PKG_SOURCE_URL:= \
	https://build.openvpn.net/downloads/releases \
	https://swupdate.openvpn.net/community/releases
PKG_HASH:=6edfd684c0339f605820eb52c808b948624ff2bcf4733d24ab97c8ea188931b8
PKG_BUILD_PARALLEL:=1

PKG_MAINTAINER:=Jianhui Zhao <zhaojh329@gmail.com>
PKG_LICENSE:=GPL-2.0-only


include $(INCLUDE_DIR)/package.mk

define KernelPackage/ovpn-backports
  SUBMENU:=Network Support
  TITLE:=OpenVPN data channel offload
  DEPENDS:= \
	+kmod-udptunnel4 +IPV6:kmod-udptunnel6 \
	+kmod-crypto-chacha20poly1305 +kmod-crypto-lib-chacha20 +kmod-crypto-lib-poly1305
  # Note: TCP requires STREAM_PARSER but it can't be selected by out-of-tree
  # modules, so pull in AF_KCM for now. This needs to be patched on kernel
  # side.
  #KCONFIG:=CONFIG_STREAM_PARSER=y
  KCONFIG:=CONFIG_STREAM_PARSER=y
  FILES:=$(PKG_BUILD_DIR)/drivers/net/ovpn/ovpn.ko
  AUTOLOAD:=$(call AutoLoad,30,ovpn)
endef

define KernelPackage/ovpn-backports/description
  This module enhances the performance of the OpenVPN userspace software
  by offloading the data channel processing to kernelspace.
endef

define Build/Compile
	+$(KERNEL_MAKE) $(PKG_JOBS) \
		M="$(PKG_BUILD_DIR)" \
		PWD="$(PKG_BUILD_DIR)" \
		KERNEL_SRC="$(LINUX_DIR)" \
		CONFIG_OVPN=m \
		modules
endef

$(eval $(call KernelPackage,ovpn-backports))
