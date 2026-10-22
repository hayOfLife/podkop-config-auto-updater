#!/bin/sh
set -eu
tools_dir="${RUNNER_TEMP:-/tmp}/podkop-sattelite-tools"
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
build_source ucode https://github.com/jow-/ucode.git 4a28662538275b67a0bcf11de25c365c1ec7a99d -DUBUS_SUPPORT=OFF -DULOOP_SUPPORT=OFF -DUCI_SUPPORT=ON
export LD_LIBRARY_PATH="$tools_dir/install/lib"
export PATH="$tools_dir/install/bin:$PATH"
ucode -L "$tools_dir/install/lib/ucode" -L "$PWD/package/luci-app-podkop-sattelite/root/usr/share/podkop-sattelite" -c -o "$tools_dir/worker.ucb" package/luci-app-podkop-sattelite/root/usr/share/podkop-sattelite/worker.uc
for script in package/luci-app-podkop-sattelite/root/usr/libexec/podkop-sattelite/* package/luci-app-podkop-sattelite/root/etc/init.d/* package/luci-app-podkop-sattelite/root/etc/uci-defaults/*; do
	sh -n "$script"
done
ucode -L "$tools_dir/install/lib/ucode" -L "$PWD/package/luci-app-podkop-sattelite/root/usr/share/podkop-sattelite" tests/coreTest.uc
if [ -f tests/integrationTest.uc ]; then
	ucode -L "$tools_dir/install/lib/ucode" -L "$PWD/package/luci-app-podkop-sattelite/root/usr/share/podkop-sattelite" tests/integrationTest.uc
fi
