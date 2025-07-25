#
# Copyright (C) 2007-2020 OpenWrt.org
#
# This is free software, licensed under the GNU General Public License v2.
# See /LICENSE for more information.
#

include $(TOPDIR)/rules.mk
include $(INCLUDE_DIR)/nls.mk

PKG_NAME:=curl
PKG_VERSION:=8.12.1
PKG_RELEASE:=2

PKG_SOURCE:=$(PKG_NAME)-$(PKG_VERSION).tar.xz
PKG_SOURCE_URL:=https://github.com/curl/curl/releases/download/curl-$(subst .,_,$(PKG_VERSION))/ \
	https://curl.se/download/
PKG_HASH:=0341f1ed97a26c811abaebd37d62b833956792b7607ea3f15d001613c76de202

PKG_LICENSE:=MIT
PKG_LICENSE_FILES:=COPYING
PKG_CPE_ID:=cpe:/a:haxx:libcurl

PKG_FIXUP:=autoreconf
PKG_INSTALL:=1
PKG_BUILD_PARALLEL:=1

PKG_CONFIG_DEPENDS:= \
  CONFIG_IPV6 \
  \
  CONFIG_LIBCURL_WOLFSSL \
  CONFIG_LIBCURL_GNUTLS \
  CONFIG_LIBCURL_OPENSSL \
  CONFIG_LIBCURL_MBEDTLS \
  CONFIG_LIBCURL_NOSSL \
  \
  CONFIG_LIBCURL_LIBIDN2 \
  CONFIG_LIBCURL_SSH2 \
  CONFIG_LIBCURL_ZLIB \
  CONFIG_LIBCURL_ZSTD \
  \
  CONFIG_LIBCURL_DICT \
  CONFIG_LIBCURL_FILE \
  CONFIG_LIBCURL_FTP \
  CONFIG_LIBCURL_GOPHER \
  CONFIG_LIBCURL_HTTP \
  CONFIG_LIBCURL_WEBSOCKETS \
  CONFIG_LIBCURL_IMAP \
  CONFIG_LIBCURL_LDAP \
  CONFIG_LIBCURL_LDAPS \
  CONFIG_LIBCURL_POP3 \
  CONFIG_LIBCURL_RTSP \
  CONFIG_LIBCURL_NO_RTSP \
  CONFIG_LIBCURL_SMB \
  CONFIG_LIBCURL_NO_SMB \
  CONFIG_LIBCURL_SMTP \
  CONFIG_LIBCURL_TELNET \
  CONFIG_LIBCURL_TFTP \
  CONFIG_LIBCURL_NGHTTP2 \
  CONFIG_LIBCURL_NGHTTP3 \
  CONFIG_LIBCURL_NGTCP2 \
  \
  CONFIG_LIBCURL_COOKIES \
  CONFIG_LIBCURL_CRYPTO_AUTH \
  CONFIG_LIBCURL_HTTP_AUTH \
  CONFIG_LIBCURL_LIBCURL_OPTION \
  CONFIG_LIBCURL_PROXY \
  CONFIG_LIBCURL_THREADED_RESOLVER \
  CONFIG_LIBCURL_TLS_SRP \
  CONFIG_LIBCURL_UNIX_SOCKETS \
  CONFIG_LIBCURL_VERBOSE \
  CONFIG_LIBCURL_NTLM \
  $(if $(CONFIG_LIBCURL_OPENSSL), \
	CONFIG_OPENSSL_ENGINE \
	CONFIG_OPENSSL_WITH_COMPRESSION \
	CONFIG_OPENSSL_WITH_NPN)

include $(INCLUDE_DIR)/package.mk

define Package/curl/Default
  SECTION:=net
  CATEGORY:=Network
  URL:=https://curl.se/
  MAINTAINER:=Aleksey Vasilenko <aleksey.vasilenko@gmail.com>
endef

define Package/curl
  $(call Package/curl/Default)
  SUBMENU:=File Transfer
  DEPENDS:=+libcurl
  TITLE:=A client-side URL transfer utility
endef

define Package/libcurl
  $(call Package/curl/Default)
  SECTION:=libs
  CATEGORY:=Libraries
  DEPENDS:= +LIBCURL_WOLFSSL:libwolfssl +LIBCURL_OPENSSL:libopenssl +LIBCURL_GNUTLS:libgnutls +LIBCURL_MBEDTLS:libmbedtls
  DEPENDS += +LIBCURL_ZLIB:zlib +LIBCURL_ZSTD:libzstd +LIBCURL_THREADED_RESOLVER:libpthread +LIBCURL_LDAP:libopenldap
  DEPENDS += +LIBCURL_LIBIDN2:libidn2 +LIBCURL_SSH2:libssh2 +LIBCURL_NGHTTP2:libnghttp2 +LIBCURL_NGHTTP3:libnghttp3 +LIBCURL_NGTCP2:libngtcp2 +ca-bundle
  TITLE:=A client-side URL transfer library
  MENU:=1
  ABI_VERSION:=4
endef

define Package/libcurl/config
  source "$(SOURCE)/Config.in"
endef

TARGET_CFLAGS += $(FPIC)
TARGET_CPPFLAGS += $(if $(CONFIG_LIBCURL_NTLM),,-DCURL_DISABLE_NTLM)
TARGET_LDFLAGS += -Wl,--gc-sections

CONFIGURE_ARGS += \
	--disable-debug \
	--disable-docs \
	--disable-ares \
	--enable-shared \
	--enable-static \
	--disable-manual \
	--without-brotli \
	--without-nss \
	--without-librtmp \
	--without-ca-path \
	--without-libpsl \
	--without-zstd \
	--with-ca-bundle=/etc/ssl/certs/ca-certificates.crt \
	\
	$(call autoconf_bool,CONFIG_IPV6,ipv6) \
	\
	$(if $(CONFIG_LIBCURL_WOLFSSL)$(CONFIG_LIBCURL_GNUTLS)$(CONFIG_LIBCURL_OPENSSL)$(CONFIG_LIBCURL_MBEDTLS),,--without-ssl) \
	$(if $(CONFIG_LIBCURL_WOLFSSL),--with-wolfssl="$(STAGING_DIR)/usr",--without-wolfssl) \
	$(if $(CONFIG_LIBCURL_GNUTLS),--with-gnutls="$(STAGING_DIR)/usr",--without-gnutls) \
	$(if $(CONFIG_LIBCURL_OPENSSL),--with-openssl="$(STAGING_DIR)/usr",--without-openssl) \
	$(if $(CONFIG_LIBCURL_MBEDTLS),--with-mbedtls="$(STAGING_DIR)/usr",--without-mbedtls) \
	\
	$(if $(CONFIG_LIBCURL_LIBIDN2),--with-libidn2="$(STAGING_DIR)/usr",--without-libidn2) \
	$(if $(CONFIG_LIBCURL_SSH2),--with-libssh2="$(STAGING_DIR)/usr",--without-libssh2) \
	$(if $(CONFIG_LIBCURL_ZLIB),--with-zlib="$(STAGING_DIR)/usr",--without-zlib) \
	$(if $(CONFIG_LIBCURL_ZSTD),--with-zstd="$(STAGING_DIR)/usr",--without-zstd) \
	$(if $(CONFIG_LIBCURL_NGHTTP2),--with-nghttp2="$(STAGING_DIR)/usr",--without-nghttp2) \
	$(if $(CONFIG_LIBCURL_NGHTTP3),--with-nghttp3="$(STAGING_DIR)/usr",--without-nghttp3) \
	$(if $(CONFIG_LIBCURL_NGTCP2),--with-ngtcp2="$(STAGING_DIR)/usr",--without-ngtcp2) \
	\
	$(call autoconf_bool,CONFIG_LIBCURL_DICT,dict) \
	$(call autoconf_bool,CONFIG_LIBCURL_FILE,file) \
	$(call autoconf_bool,CONFIG_LIBCURL_FTP,ftp) \
	$(call autoconf_bool,CONFIG_LIBCURL_GOPHER,gopher) \
	$(call autoconf_bool,CONFIG_LIBCURL_HTTP,http) \
	$(call autoconf_bool,CONFIG_LIBCURL_IMAP,imap) \
	$(call autoconf_bool,CONFIG_LIBCURL_LDAP,ldap) \
	$(call autoconf_bool,CONFIG_LIBCURL_LDAPS,ldaps) \
	$(call autoconf_bool,CONFIG_LIBCURL_POP3,pop3) \
	$(call autoconf_bool,CONFIG_LIBCURL_RTSP,rtsp) \
	$(call autoconf_bool,CONFIG_LIBCURL_SMB,smb) \
	$(call autoconf_bool,CONFIG_LIBCURL_SMTP,smtp) \
	$(call autoconf_bool,CONFIG_LIBCURL_TELNET,telnet) \
	$(call autoconf_bool,CONFIG_LIBCURL_TFTP,tftp) \
	$(call autoconf_bool,CONFIG_LIBCURL_WEBSOCKETS,websockets) \
	\
	$(call autoconf_bool,CONFIG_LIBCURL_COOKIES,cookies) \
	$(call autoconf_bool,CONFIG_LIBCURL_CRYPTO_AUTH,crypto-auth) \
	$(call autoconf_bool,CONFIG_LIBCURL_HTTP_AUTH,http-auth) \
	$(call autoconf_bool,CONFIG_LIBCURL_LIBCURL_OPTION,libcurl-option) \
	$(call autoconf_bool,CONFIG_LIBCURL_PROXY,proxy) \
	$(call autoconf_bool,CONFIG_LIBCURL_THREADED_RESOLVER,threaded-resolver) \
	$(call autoconf_bool,CONFIG_LIBCURL_TLS_SRP,tls-srp) \
	$(call autoconf_bool,CONFIG_LIBCURL_UNIX_SOCKETS,unix-sockets) \
	$(call autoconf_bool,CONFIG_LIBCURL_VERBOSE,verbose) \

define Build/InstallDev
	$(INSTALL_DIR) $(2)/bin $(1)/usr/bin $(1)/usr/include $(1)/usr/lib $(1)/usr/lib/pkgconfig
	$(INSTALL_BIN) $(PKG_INSTALL_DIR)/usr/bin/curl-config $(1)/usr/bin/
	$(CP) $(PKG_INSTALL_DIR)/usr/include/curl $(1)/usr/include/
	$(CP) $(PKG_INSTALL_DIR)/usr/lib/libcurl.{a,so*} $(1)/usr/lib/
	$(CP) $(PKG_BUILD_DIR)/libcurl.pc $(1)/usr/lib/pkgconfig/
	$(SED) 's,^\(prefix\|exec_prefix\)=.*,\1=$(STAGING_DIR)/usr,g' $(1)/usr/bin/curl-config
	[ -n "$(TARGET_LDFLAGS)" ] && $(SED) 's#$(TARGET_LDFLAGS)##g' $(1)/usr/lib/pkgconfig/libcurl.pc || true
	$(LN) $(STAGING_DIR)/usr/bin/curl-config $(2)/bin/
endef

define Package/curl/install
	$(INSTALL_DIR) $(1)/usr/bin
	$(INSTALL_BIN) $(PKG_INSTALL_DIR)/usr/bin/curl $(1)/usr/bin/
endef

define Package/libcurl/install
	$(INSTALL_DIR) $(1)/usr/lib
	$(CP) $(PKG_INSTALL_DIR)/usr/lib/libcurl.so.* $(1)/usr/lib/
endef

$(eval $(call BuildPackage,libcurl))
$(eval $(call BuildPackage,curl))
