include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-podkop-config-auto-updater
PKG_VERSION:=0.1.3
PKG_RELEASE:=1
PKG_LICENSE:=MIT
PKG_MAINTAINER:=hayOfLife

LUCI_TITLE:=Podkop config auto updater
LUCI_DEPENDS:=+luci-base +ucode +ucode-mod-fs +ucode-mod-uci +curl +ca-bundle +flock
LUCI_PKGARCH:=all

define Package/$(PKG_NAME)/conffiles
/etc/config/podkop_config_auto_updater
endef

define Package/$(PKG_NAME)/prerm
#!/bin/sh
[ -n "$${IPKG_INSTROOT}" ] && exit 0
[ "$${PKG_UPGRADE:-0}" = 1 ] && exit 0
[ "$${1:-remove}" = upgrade ] && exit 0
/etc/init.d/podkop_config_auto_updater stop
/usr/libexec/podkop-config-auto-updater/ipv6 release || exit 1
exit 0
endef

include $(TOPDIR)/feeds/luci/luci.mk

# call BuildPackage - OpenWrt buildroot signature
