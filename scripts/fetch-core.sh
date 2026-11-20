#!/bin/sh
set -eu

root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
version=1.14.4
asset="sing-box-$version-darwin-arm64"
sha=0d8c7f5ed5d587b0f1a5e9772a708ec3bfa4ac4c9329604b01d8d9c2ba406838
archive="$root/.build/sing-box-darwin-arm64.tar.gz"
mkdir -p "$root/.build"

case "$(uname -s)-$(uname -m)" in
    Darwin-arm64) ;;
    *) printf '%s\n' '此版本支持 Apple Silicon Mac。' >&2; exit 1 ;;
esac

verify() {
    actual=$(/usr/bin/shasum -a 256 "$1" | /usr/bin/awk '{print $1}')
    [ "$actual" = "$sha" ]
}

if [ -n "${1:-}" ]; then
    verify "$1" || { printf '%s\n' 'sing-box 安装包校验失败。' >&2; exit 1; }
    cp "$1" "$archive"
elif [ ! -f "$archive" ]; then
    candidate=$(mktemp "$root/.build/upstream.XXXXXX")
    trap 'rm -f "$candidate"' EXIT HUP INT TERM
    /usr/bin/curl -q --proto '=https' -fLSs --retry 1 --max-time 120 \
        -o "$candidate" "https://github.com/SagerNet/sing-box/releases/download/v$version/$asset.tar.gz"
    verify "$candidate" || { printf '%s\n' 'sing-box 安装包校验失败。' >&2; exit 1; }
    mv "$candidate" "$archive"
fi
verify "$archive" || { printf '%s\n' '已有安装包的 SHA-256 不匹配。' >&2; exit 1; }
mkdir -p "$root/.build/upstream"
/usr/bin/tar -xzf "$archive" -C "$root/.build/upstream" "$asset/sing-box" "$asset/LICENSE"
printf '%s\n' "$root/.build/upstream/$asset"
