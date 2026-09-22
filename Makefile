include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-qosify
PKG_VERSION:=$(shell sed -n 's/^VERSION="\(.*\)"/\1/p' $(CURDIR)/qosify-luci.sh)
PKG_RELEASE:=1

PKG_MAINTAINER:=Ash Clarke <clarkeaj@hotmail.co.uk>
PKG_LICENSE:=MIT

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
  Web UI for the qosify CAKE/eBPF traffic shaping daemon.
  Config files are owned by the qosify package.
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
	$(INSTALL_DATA) $(PKG_BUILD_DIR)/root/www/luci-static/resources/view/qosify/qosify.css $(1)/www/luci-static/resources/view/qosify/
endef

define Package/luci-app-qosify/postinst
#!/bin/sh
[ -n "$${IPKG_INSTROOT}" ] || {
	rm -f /tmp/luci-indexcache.*
	rm -rf /tmp/luci-modulecache/
	/etc/init.d/rpcd reload 2>/dev/null
}
exit 0
endef

# qosify leaves clsact and ifb-dns behind when it stops, and its own prerm may
# run after this one, so a copy of cleanup waits in the background for qosify to
# exit. If qosify stays installed and running it touches nothing.
define Package/luci-app-qosify/prerm
#!/bin/sh
[ -n "$${IPKG_INSTROOT}" ] || [ "$${PKG_UPGRADE}" = 1 ] || {
	cp /usr/share/qosify-luci/cleanup /tmp/qosify-luci-cleanup &&
	( /tmp/qosify-luci-cleanup wait; rm -f /tmp/qosify-luci-cleanup ) \
		</dev/null >/dev/null 2>&1 &
}
exit 0
endef

define Package/luci-app-qosify/postrm
#!/bin/sh
[ -n "$${IPKG_INSTROOT}" ] || {
	rm -f /tmp/luci-indexcache.*
	rm -rf /tmp/luci-modulecache/
	/etc/init.d/rpcd reload 2>/dev/null
}
exit 0
endef

$(eval $(call BuildPackage,luci-app-qosify))
