#!/bin/sh
set -eu
version="$1"
directory="$2"
case "$version" in 24.10.7|25.12.5) ;; *) exit 2 ;; esac
mkdir -p "$directory"
path="releases/$version/targets/bcm27xx/bcm2710"
base="https://downloads.openwrt.org/$path"
curl -fsSL --http1.1 --connect-timeout 15 --max-time 60 --retry 3 --retry-all-errors "$base/sha256sums" -o "$directory/sha256sums"
name="$(awk '/sdk-.*Linux-x86_64\.tar/ {print $2; exit}' "$directory/sha256sums" | tr -d '*')"
case "$name" in openwrt-sdk-*.Linux-x86_64.tar.zst) ;; *) exit 1 ;; esac
curl -fsSL --http1.1 --connect-timeout 15 --max-time 60 --retry 3 --retry-all-errors --range 0-0 -D "$directory/headers" -o /dev/null "$base/$name"
size="$(tr -d '\r' < "$directory/headers" | sed -n 's/^[Cc]ontent-[Rr]ange: bytes [0-9-]*\/\([0-9]*\)$/\1/p' | tail -1)"
case "$size" in ''|*[!0-9]*) exit 1 ;; esac
[ "$size" -gt 0 ] && [ "$size" -le 1073741824 ]
start=0
index=0
pids=''
count=0
wait_chunks() {
	failed=0
	for pid in $pids; do wait "$pid" || failed=1; done
	[ "$failed" = 0 ] || return 1
	pids=''
	count=0
}
while [ "$start" -lt "$size" ]; do
	end=$((start + 4194303))
	[ "$end" -lt "$size" ] || end=$((size - 1))
	chunk="$directory/chunk-$(printf '%05d' "$index")"
	(
		curl -fsSL --http1.1 --connect-timeout 15 --max-time 90 --retry 5 --retry-all-errors --retry-delay 2 --range "$start-$end" -o "$chunk" "$base/$name"
		[ "$(wc -c < "$chunk")" -eq $((end - start + 1)) ]
		printf 'SDK %s: bytes %s-%s/%s\n' "$version" "$start" "$end" "$size"
	) &
	pids="$pids $!"
	count=$((count + 1))
	[ "$count" -lt 4 ] || wait_chunks
	start=$((end + 1))
	index=$((index + 1))
done
[ "$count" -eq 0 ] || wait_chunks
cat "$directory"/chunk-* > "$directory/$name"
(cd "$directory" && grep -F "*$name" sha256sums | sha256sum -c -)
