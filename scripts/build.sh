#!/bin/sh
set -eu

root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
release="$root/.build/release"
mkdir -p "$release/bin" "$release/libexec" "$release/licenses" "$root/.build/module-cache"
sdk=$(/usr/bin/xcrun --sdk macosx --show-sdk-path)
swift=$(/usr/bin/xcrun --find swiftc)
clang=$(/usr/bin/xcrun --find clang)
"$clang" -target arm64-apple-macosx13.0 -isysroot "$sdk" -O2 -c \
    "$root/Sources/CLI/terminal_support.c" -o "$root/.build/terminal_support.o"
"$swift" -O -target arm64-apple-macosx13.0 -sdk "$sdk" -module-cache-path "$root/.build/module-cache" \
    -ledit "$root"/Sources/CLI/*.swift "$root"/Sources/Host/*.swift "$root"/Sources/Profiles/*.swift \
    "$root/.build/terminal_support.o" \
    -o "$release/bin/proxyctl"
upstream=$(sh "$root/scripts/fetch-core.sh" "${1:-}")
/usr/bin/install -m 755 "$upstream/sing-box" "$release/libexec/sing-box"
/usr/bin/install -m 644 "$root/LICENSE" "$release/licenses/proxyctl.txt"
/usr/bin/install -m 644 "$upstream/LICENSE" "$release/licenses/sing-box.txt"
/usr/bin/install -m 644 "$root/licenses/GPL-3.0.txt" "$release/licenses/GPL-3.0.txt"
/usr/bin/install -m 644 "$root/docs/distribution.md" "$release/licenses/sing-box-source.md"
/usr/bin/install -m 755 "$root/scripts/install.sh" "$release/install.sh"
printf '安装包已生成 %s\n' "$release"
