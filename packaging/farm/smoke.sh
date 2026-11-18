#!/bin/sh
# Tries the packages packaging/farm/build.sh made: installs each into a clean container of its
# own system (the package manager pulling in its dependencies), checks that every library the
# program needs is found, and starts Signet under Xvfb until its window appears. A screenshot
# and the program's output go in dist/smoke/<target>.png and .log.
#
#   packaging/farm/smoke.sh                       # every target
#   packaging/farm/smoke.sh fedora-45
#   VERSION=0.8 packaging/farm/smoke.sh
set -eu

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
cd "$ROOT"

VERSION=${VERSION:-$(packaging/version.sh)}
[ $# -gt 0 ] || set -- debian-13 ubuntu-2604 fedora-45 arch
mkdir -p dist/smoke

failed=
for target in "$@"; do
    case "$target" in
        debian-13|ubuntu-*)
            [ "$target" = debian-13 ] && image=debian:13 || image="ubuntu:$(echo "${target#ubuntu-}" | sed 's/../&./')"
            pkg="signet-gtk_${VERSION}_amd64.deb"
            install="export DEBIAN_FRONTEND=noninteractive; apt-get update -qq &&
                apt-get install -y -qq /pkgs/$pkg xvfb xdotool imagemagick dbus-daemon fonts-dejavu-core >/dev/null" ;;
        fedora-*)
            image="fedora:${target#fedora-}"
            pkg="signet-gtk-$VERSION-1.x86_64.rpm"
            install="dnf install -y -q /pkgs/$pkg xorg-x11-server-Xvfb xdotool ImageMagick dbus-daemon dejavu-sans-fonts >/dev/null" ;;
        arch)
            image=archlinux:latest
            pkg="signet-gtk-bin-$VERSION-1-x86_64.pkg.tar.zst"
            install="pacman -Syu --noconfirm -q xorg-server-xvfb xdotool imagemagick ttf-dejavu >/dev/null &&
                pacman -U --noconfirm /pkgs/$pkg >/dev/null" ;;
        *) echo "unknown target $target" >&2; exit 1 ;;
    esac
    [ -f "dist/$target/$pkg" ] || { echo "dist/$target/$pkg is missing: run packaging/farm/build.sh $target" >&2; exit 1; }

    echo "==> $target: $pkg"
    if docker run --rm -v "$ROOT/dist/$target:/pkgs:ro" -v "$ROOT/dist/smoke:/out" "$image" sh -euc "
        $install
        if ldd /usr/lib/signet-gtk/signet-gtk | grep 'not found'; then exit 1; fi
        export HOME=/tmp/home XDG_CONFIG_HOME=/tmp/home/.config DISPLAY=:99
        mkdir -p \$HOME && chmod 700 \$HOME
        Xvfb :99 -screen 0 1280x1000x24 -nolisten tcp 2>/dev/null &
        sleep 2
        dbus-run-session -- signet-gtk >/out/$target.log 2>&1 &
        pid=\$!
        for i in \$(seq 60); do
            xdotool search --name '^Signet\$' >/dev/null 2>&1 && break
            kill -0 \$pid 2>/dev/null || { echo 'signet-gtk exited' >&2; cat /out/$target.log >&2; exit 1; }
            sleep 1
        done
        xdotool search --name '^Signet\$' >/dev/null || { echo 'no Signet window' >&2; exit 1; }
        sleep 5
        kill -0 \$pid || { echo 'signet-gtk exited' >&2; exit 1; }
        import -window root /out/$target.png
        chown $(id -u):$(id -g) /out/$target.png /out/$target.log
    "; then
        echo "==> $target: ok (dist/smoke/$target.png)"
    else
        echo "==> $target: FAILED" >&2
        failed="$failed $target"
    fi
done
[ -z "$failed" ] || { echo "failed:$failed" >&2; exit 1; }
