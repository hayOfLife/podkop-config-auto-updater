#!/bin/sh
set -eu
version="$1"
directory="$2"
case "$version" in 24.10.7|25.12.5) ;; *) exit 2 ;; esac
mkdir -p "$directory"
path="releases/$version/targets/bcm27xx/bcm2710"
base="https://downloads.openwrt.org/$path"
curl -fsSL --connect-timeout 15 --max-time 60 "$base/sha256sums" -o "$directory/sha256sums"
name="$(awk '/sdk-.*Linux-x86_64\.tar/ {print $2; exit}' "$directory/sha256sums" | tr -d '*')"
case "$name" in openwrt-sdk-*.Linux-x86_64.tar.zst) ;; *) exit 1 ;; esac
curl -fsSL --connect-timeout 15 --max-time 60 --range 0-0 -D "$directory/headers" -o /dev/null "$base/$name"
size="$(tr -d '\r' < "$directory/headers" | sed -n 's/^[Cc]ontent-[Rr]ange: bytes [0-9-]*\/\([0-9]*\)$/\1/p' | tail -1)"
case "$size" in ''|*[!0-9]*) exit 1 ;; esac
[ "$size" -gt 0 ] && [ "$size" -le 1073741824 ]
start=0
: > "$directory/$name"
while [ "$start" -lt "$size" ]; do
	end=$((start + 10485759))
	[ "$end" -lt "$size" ] || end=$((size - 1))
	curl -fsSL --connect-timeout 15 --max-time 120 --retry 2 --range "$start-$end" -o "$directory/chunk" "$base/$name"
	[ "$(wc -c < "$directory/chunk")" -eq $((end - start + 1)) ]
	cat "$directory/chunk" >> "$directory/$name"
	start=$((end + 1))
	printf 'SDK %s: %s/%s bytes\n' "$version" "$start" "$size"
done
(cd "$directory" && grep -F "*$name" sha256sums | sha256sum -c -)
