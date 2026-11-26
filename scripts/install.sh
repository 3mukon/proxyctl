#!/bin/sh
set -eu
umask 077

bundle=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
test "$(id -u)" != 0 || { printf '%s\n' '请以普通账户安装。' >&2; exit 1; }
macos=$(/usr/bin/sw_vers -productVersion 2>/dev/null) || macos=0
if [ "$(uname -m)" != arm64 ] || [ "${macos%%.*}" -lt 26 ]; then
    printf '%s\n' '此发布包需要运行 macOS 26 或更新版本的 Apple Silicon Mac。' >&2
    exit 1
fi
test -x "$bundle/libexec/sing-box" || { printf '%s\n' '请在完整的 Proxyctl 发布包中运行此脚本。' >&2; exit 1; }
version=$("$bundle/bin/proxyctl" --version)
case "$version" in ''|*[!0-9.]* ) exit 1 ;; esac

install_root=${PROXYCTL_INSTALL_ROOT:-"$HOME"}
bin="$install_root/.local/bin"
store="$install_root/.local/share/proxyctl/versions"
dest="$store/$version"
mkdir -p "$bin" "$store"

owns_link() {
    test -L "$1" || return 1
    case "$(/usr/bin/readlink "$1")" in "$store/"*/bin/proxyctl) return 0 ;; *) return 1 ;; esac
}

target="$bin/proxyctl"
if { test -e "$target" || test -L "$target"; } && ! owns_link "$target"; then
    printf '已有同名命令 %s\n' "$target" >&2
    exit 1
fi

if test -e "$dest" || test -L "$dest"; then
    test ! -L "$dest" && /usr/bin/cmp -s "$bundle/bin/proxyctl" "$dest/bin/proxyctl" && \
        /usr/bin/cmp -s "$bundle/libexec/sing-box" "$dest/libexec/sing-box" || {
        printf '%s\n' '同版本安装目录已有不同文件，请构建一个新版本。' >&2
        exit 1
    }
else
    scratch=$(mktemp -d "$store/staging.XXXXXX")
    trap 'rm -rf "$scratch"' EXIT HUP INT TERM
    cp -R "$bundle/bin" "$bundle/libexec" "$bundle/licenses" "$scratch/"
    mv "$scratch" "$dest"
fi

link_command() {
    entry="$bin/$1"
    if { test -e "$entry" || test -L "$entry"; } && ! owns_link "$entry"; then
        printf '已存在的命令保留 %s\n' "$entry"
        return
    fi
    temporary=$(mktemp -d "$bin/.proxyctl.XXXXXX")
    ln -s "$dest/bin/proxyctl" "$temporary/command"
    /bin/mv -f -h "$temporary/command" "$entry"
    rmdir "$temporary"
}

link_command proxyctl
case ":$PATH:" in
    *":$bin:"*) ;;
    *)
        if [ "$install_root" = "$HOME" ] && [ "${SHELL##*/}" = zsh ]; then
            profile="${ZDOTDIR:-$HOME}/.zprofile"
            line='export PATH="$HOME/.local/bin:$PATH"'
            if ! /usr/bin/grep -Fqx "$line" "$profile" 2>/dev/null; then
                printf '\n%s\n' "$line" >> "$profile"
            fi
            printf '%s\n' '打开新终端后即可运行 proxyctl。'
        else
            printf '%s\n' '将 ~/.local/bin 加入当前 shell 的 PATH 后运行 proxyctl。'
        fi
        ;;
esac
printf '%s\n' 'Proxyctl 已安装。输入 proxyctl 打开控制台。'
