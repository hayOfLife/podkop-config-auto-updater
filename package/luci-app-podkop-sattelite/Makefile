include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-podkop-sattelite
PKG_VERSION:=0.1.0
PKG_RELEASE:=1
PKG_LICENSE:=MIT
PKG_MAINTAINER:=hayOfLife

LUCI_TITLE:=podkop sattelite
LUCI_DEPENDS:=+luci-base +ucode +ucode-mod-fs +ucode-mod-uci +curl +ca-bundle +flock
LUCI_PKGARCH:=all

define Package/$(PKG_NAME)/conffiles
/etc/config/podkop_sattelite
endef

include $(TOPDIR)/feeds/luci/luci.mk

# Подключение через feed использует стандартные правила упаковки LuCI
