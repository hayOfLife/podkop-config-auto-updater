#!/bin/sh
set -eu
series="${1:-25.12}"
case "$series" in
	24.10) ucode_revision=3f64c8089bf3ea4847c96b91df09fbfcaec19e1d ;;
	25.12) ucode_revision=85922056ef7abeace3cca3ab28bc1ac2d88e31b1 ;;
	*) printf 'Unsupported OpenWrt test series: %s\n' "$series" >&2; exit 2 ;;
esac
tools_dir="${RUNNER_TEMP:-/tmp}/podkop-config-auto-updater-tools-$series"
mkdir -p "$tools_dir"
build_source() {
	name="$1"; url="$2"; revision="$3"; shift 3
	git clone --quiet "$url" "$tools_dir/$name"
	git -C "$tools_dir/$name" checkout --quiet "$revision"
	cmake -S "$tools_dir/$name" -B "$tools_dir/$name/out" \
		-DCMAKE_INSTALL_PREFIX="$tools_dir/install" -DCMAKE_PREFIX_PATH="$tools_dir/install" "$@"
	cmake --build "$tools_dir/$name/out" -j2
	cmake --install "$tools_dir/$name/out"
}
build_source libubox https://github.com/openwrt/libubox.git da2d205a5cf3e877c45a2eec488218cbaf452e7d -DBUILD_LUA=OFF -DBUILD_EXAMPLES=OFF
build_source uci https://github.com/openwrt/uci.git 74f6277aabffc943d026f406df57c22595134c42 -DBUILD_LUA=OFF
build_source ucode https://github.com/jow-/ucode.git "$ucode_revision" -DUBUS_SUPPORT=OFF -DULOOP_SUPPORT=OFF -DUCI_SUPPORT=ON
export LD_LIBRARY_PATH="$tools_dir/install/lib"
export PATH="$tools_dir/install/bin:$PATH"
sh -n install.sh
for worker in worker software; do
	ucode -L "$tools_dir/install/lib/ucode" -L "$PWD/package/luci-app-podkop-config-auto-updater/root/usr/share/podkop-config-auto-updater" -c -o "$tools_dir/$worker.ucb" "package/luci-app-podkop-config-auto-updater/root/usr/share/podkop-config-auto-updater/$worker.uc"
done
for script in package/luci-app-podkop-config-auto-updater/root/usr/libexec/podkop-config-auto-updater/* package/luci-app-podkop-config-auto-updater/root/etc/init.d/* package/luci-app-podkop-config-auto-updater/root/etc/uci-defaults/*; do
	sh -n "$script"
done
ucode -L "$tools_dir/install/lib/ucode" -L "$PWD/package/luci-app-podkop-config-auto-updater/root/usr/share/podkop-config-auto-updater" tests/coreTest.uc
ucode -L "$tools_dir/install/lib/ucode" -L "$PWD/package/luci-app-podkop-config-auto-updater/root/usr/share/podkop-config-auto-updater" tests/configTest.uc
if [ -f tests/integrationTest.uc ]; then
	integration_dir="$(mktemp -d /tmp/podkop-integration.XXXXXX)"
	ucode -L "$tools_dir/install/lib/ucode" -L "$PWD/package/luci-app-podkop-config-auto-updater/root/usr/share/podkop-config-auto-updater" tests/integrationTest.uc "$integration_dir"
fi
sudo python3 tests/routerActionsTest.py "$tools_dir/install"
