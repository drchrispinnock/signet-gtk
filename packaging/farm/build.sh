#!/bin/sh
# The build farm: builds each package on its own system, in a container, into
# dist/<platform>/ (the names packaging/distdir.sh gives there).
#
#   packaging/farm/build.sh                       # every target
#   packaging/farm/build.sh fedora-45 arch        # some
#   VERSION=0.8 packaging/farm/build.sh debian-13
#
# Targets:
#   debian-13     the .deb and the release tarball
#   ubuntu-2604   the .deb
#   fedora-NN     the RPM (fedora-44, fedora-45, …: the image is fedora:NN)
#   arch          the Arch tarball and signet-gtk-bin
#
# Each target's image (signet-farm:<target>) has its distribution's development packages and the
# Swift toolchain SWIFT_VERSION from swift.org. The checkout is copied into the container (the
# working tree as it is, uncommitted changes included); .build is kept between runs in a volume
# per target (signet-farm-<target>; `docker volume rm` it for a clean build). Packages are owned
# by the user running this. Then try them with packaging/farm/smoke.sh.
set -eu

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
cd "$ROOT"
FARM=packaging/farm

SWIFT_VERSION=${SWIFT_VERSION:-6.4.2}
VERSION=${VERSION:-$(packaging/version.sh)}
[ $# -gt 0 ] || set -- debian-13 ubuntu-2604 fedora-45 arch

for target in "$@"; do
    platform=
    case "$target" in
        debian-13)   dockerfile=deb;  base=debian:13 ;;
        ubuntu-2604) dockerfile=deb;  base=ubuntu:26.04 ;;
        fedora-*)    dockerfile=rpm;  base="fedora:${target#fedora-}"; platform=fedora41 ;;
        arch)        dockerfile=arch; base=archlinux:latest; platform=ubi9 ;;
        *) echo "unknown target $target" >&2; exit 1 ;;
    esac
    case "$target" in
        debian-13)   build='packaging/deb/build-deb.sh && SKIP_BUILD=1 packaging/tarball/build-tarball.sh' ;;
        ubuntu-*)    build='packaging/deb/build-deb.sh' ;;
        fedora-*)    build='packaging/rpm/build-rpm.sh' ;;
        arch)        build='packaging/tarball/build-tarball.sh && packaging/arch/build-arch.sh' ;;
    esac

    echo "==> $target: image"
    docker build -q -t "signet-farm:$target" -f "$FARM/Dockerfile.$dockerfile" \
        --build-arg BASE="$base" --build-arg UID="$(id -u)" \
        --build-arg SWIFT_VERSION="$SWIFT_VERSION" --build-arg SWIFTLY_PLATFORM="$platform" \
        "$FARM" >/dev/null

    echo "==> $target: build $VERSION"
    mkdir -p "dist/$target"
    docker run --rm \
        -v "$ROOT:/src:ro" \
        -v "signet-farm-$target:/work/.build" \
        -v "$ROOT/dist/$target:/work/dist/$target" \
        -e VERSION="$VERSION" \
        "signet-farm:$target" sh -euc "
            [ \"\$(/src/packaging/distdir.sh)\" = $target ] ||
                { echo 'the image is not $target' >&2; exit 1; }
            tar -C /src --exclude=./.build --exclude=./dist -cf - . | tar -xf -
            $build"
done
