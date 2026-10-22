#!/bin/sh
set -eu
umask 077
root="${CONFIG_UPDATER_TEST_ROOT:-}"
repository='hayOfLife/podkop-config-auto-updater'
package='luci-app-podkop-config-auto-updater'
fail() { printf 'Ошибка: %s\n' "$1" >&2; exit 1; }

[ "$(id -u)" = 0 ] || fail 'Запустите установщик от root на роутере.'
[ -r "$root/etc/openwrt_release" ] || fail 'Нужен роутер с OpenWrt.'
. "$root/etc/openwrt_release"
case "${DISTRIB_RELEASE:-}" in
	24.10.*) series=24.10; format=ipk; manager=opkg ;;
	25.12.*) series=25.12; format=apk; manager=apk ;;
	*) fail 'Поддерживаются OpenWrt 24.10 и 25.12; snapshot не поддерживается.' ;;
esac
command -v "$manager" >/dev/null 2>&1 || fail 'Не найден пакетный менеджер этой версии OpenWrt.'
[ -x "$root/etc/init.d/podkop" ] || fail 'Сначала установите Podkop.'
command -v jsonfilter >/dev/null 2>&1 || fail 'Не найден штатный jsonfilter OpenWrt.'
command -v sha256sum >/dev/null 2>&1 || fail 'Не найден sha256sum.'

download() {
	if command -v curl >/dev/null 2>&1; then
		curl --disable --fail --location --silent --show-error --proto '=https' --proto-redir '=https' \
			--connect-timeout 15 --max-time 120 -o "$2" -- "$1"
	elif command -v uclient-fetch >/dev/null 2>&1; then
		uclient-fetch -q -O "$2" "$1"
	else
		fail 'Нужен curl или штатный uclient-fetch с поддержкой HTTPS.'
	fi
}

work="$(mktemp -d /tmp/podkop-config-auto-updater-install.XXXXXX)"
trap 'rm -rf -- "$work"' EXIT HUP INT TERM
download "https://api.github.com/repos/$repository/releases/latest" "$work/release.json" || fail 'Не удалось получить опубликованный релиз.'
tag="$(jsonfilter -i "$work/release.json" -e '@.tag_name')"
case "$tag" in v[0-9]*.[0-9]*.[0-9]*) ;; *) fail 'Недопустимая версия релиза.' ;; esac
case "$tag" in *[!A-Za-z0-9._-]*) fail 'Недопустимое имя релиза.' ;; esac
asset="$package-openwrt-$series.$format"
base="https://github.com/$repository/releases/download/$tag"
download "$base/$asset" "$work/$asset" || fail 'Не удалось скачать пакет.'
download "$base/SHA256SUMS" "$work/SHA256SUMS" || fail 'Не удалось скачать контрольные суммы.'
awk -v file="$asset" '$2 == file { print }' "$work/SHA256SUMS" > "$work/expected"
[ "$(wc -l < "$work/expected")" -eq 1 ] || fail 'В релизе нет единственной контрольной суммы пакета.'
(cd "$work" && sha256sum -c expected) || fail 'Контрольная сумма пакета не совпала.'

if [ -f "$root/etc/config/podkop_config_auto_updater" ]; then
	mkdir -p "$root/etc/podkop-config-auto-updater"
	cp "$root/etc/config/podkop_config_auto_updater" "$root/etc/podkop-config-auto-updater/before-install-config"
	chmod 600 "$root/etc/podkop-config-auto-updater/before-install-config"
fi
printf 'Установка %s для OpenWrt %s (%s)\n' "$tag" "$series" "$format"
"$manager" update
if [ "$manager" = opkg ]; then opkg install "$work/$asset";
else apk add --allow-untrusted "$work/$asset"; fi
printf '%s\n' 'Готово. Откройте Службы → Podkop config auto updater и укажите ссылку на конфиг и токен.'
