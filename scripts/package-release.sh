#!/bin/sh
set -eu

root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
release="$root/.build/release"
version=$("$release/bin/proxyctl" --version)
case "$version" in
    ''|*[!0-9.]* ) printf '%s\n' 'Unexpected Proxyctl version.' >&2; exit 1 ;;
esac
name="proxyctl-$version-macos-arm64"
target="$root/.build/$name.tar.gz"
scratch=$(mktemp -d "$root/.build/package.XXXXXX")
trap 'rm -rf "$scratch"' EXIT HUP INT TERM

package="$scratch/$name"
mkdir -p "$package/bin" "$package/libexec" "$package/licenses"
for path in install.sh bin/proxyctl libexec/sing-box; do
    test -f "$release/$path" && test ! -L "$release/$path"
    /usr/bin/install -m 755 "$release/$path" "$package/$path"
done
for name_in_package in proxyctl.txt GPL-3.0.txt sing-box.txt sing-box-source.md; do
    file="licenses/$name_in_package"
    test -f "$release/$file" && test ! -L "$release/$file"
    /usr/bin/install -m 644 "$release/$file" "$package/$file"
done

# Public archives may include the notices assembled from the pinned source companion.
if [ -n "\${1:-}" ]; then
    test -f "$1" && test ! -L "$1"
    /usr/bin/install -m 644 "$1" "$package/licenses/THIRD-PARTY-NOTICES.txt"
fi

/usr/bin/tar -czf "$scratch/archive.tar.gz" --format ustar --no-mac-metadata \
    --no-xattrs --no-acls --uid 0 --gid 0 --uname root --gname wheel \
    -C "$scratch" "$name"
/bin/mv -f "$scratch/archive.tar.gz" "$target"
printf '%s\n' "$target"
