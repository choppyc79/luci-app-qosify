include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-qosify
PKG_VERSION:=$(shell sed -n 's/^VERSION="\(.*\)"/\1/p' $(CURDIR)/qosify-luci.sh)
PKG_RELEASE:=1

PKG_MAINTAINER:=choppyc79
PKG_LICENSE:=GPL-2.0-only

PKG_BUILD_DIR:=$(BUILD_DIR)/$(PKG_NAME)-$(PKG_VERSION)

include $(INCLUDE_DIR)/package.mk

define Package/luci-app-qosify
  SECTION:=luci
  CATEGORY:=LuCI
  SUBMENU:=3. Applications
  TITLE:=LuCI interface for qosify
  DEPENDS:=+qosify +luci-base
  PKGARCH:=all
endef

define Package/luci-app-qosify/description
  Modern JavaScript LuCI web interface for the qosify CAKE/eBPF
  traffic shaping daemon. Config files are owned by the qosify package.
endef

define Build/Prepare
	mkdir -p $(PKG_BUILD_DIR)
	$(CP) ./qosify-luci.sh $(PKG_BUILD_DIR)/
endef

define Build/Configure
endef

# Extract the embedded app files by sourcing the installer with
# its target directories redirected into a staging root.
define Build/Compile
	( set -e; cd $(PKG_BUILD_DIR); \
	  R=$(PKG_BUILD_DIR)/root; rm -rf $$R; \
	  . ./qosify-luci.sh >/dev/null; \
	  MENU_DIR=$$R/usr/share/luci/menu.d; \
	  ACL_DIR=$$R/usr/share/rpcd/acl.d; \
	  VIEW_DIR=$$R/www/luci-static/resources/view/qosify; \
	  TPL_DIR=$$R/usr/share/qosify-luci; \
	  install_templates >/dev/null; \
	  install_menu >/dev/null; \
	  install_acl >/dev/null; \
	  install_view >/dev/null )
endef

define Package/luci-app-qosify/install
	$(INSTALL_DIR) $(1)/usr/share/luci/menu.d $(1)/usr/share/rpcd/acl.d \
		$(1)/usr/share/qosify-luci $(1)/www/luci-static/resources/view/qosify
	$(INSTALL_DATA) $(PKG_BUILD_DIR)/root/usr/share/luci/menu.d/luci-app-qosify.json $(1)/usr/share/luci/menu.d/
	$(INSTALL_DATA) $(PKG_BUILD_DIR)/root/usr/share/rpcd/acl.d/luci-app-qosify.json $(1)/usr/share/rpcd/acl.d/
	$(INSTALL_DATA) $(PKG_BUILD_DIR)/root/usr/share/qosify-luci/qosify $(1)/usr/share/qosify-luci/
	$(INSTALL_DATA) $(PKG_BUILD_DIR)/root/usr/share/qosify-luci/00-defaults.conf $(1)/usr/share/qosify-luci/
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/root/usr/share/qosify-luci/cleanup $(1)/usr/share/qosify-luci/
	$(INSTALL_DATA) $(PKG_BUILD_DIR)/root/www/luci-static/resources/view/qosify/main.js $(1)/www/luci-static/resources/view/qosify/
endef

define Package/luci-app-qosify/postinst
#!/bin/sh
[ -n "$${IPKG_INSTROOT}" ] || {
	rm -f /tmp/luci-indexcache /tmp/luci-indexcache.* 2>/dev/null
	rm -rf /tmp/luci-modulecache 2>/dev/null
	killall -HUP rpcd 2>/dev/null
}
exit 0
endef

define Package/luci-app-qosify/postrm
#!/bin/sh
[ -n "$${IPKG_INSTROOT}" ] || {
	rm -f /tmp/luci-indexcache /tmp/luci-indexcache.* 2>/dev/null
	rm -rf /tmp/luci-modulecache 2>/dev/null
	killall -HUP rpcd 2>/dev/null
}
exit 0
endef

$(eval $(call BuildPackage,luci-app-qosify))
