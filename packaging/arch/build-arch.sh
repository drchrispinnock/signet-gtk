#!/bin/sh
# Writes dist/arch/PKGBUILD (and .SRCINFO) for signet-gtk-bin from PKGBUILD.in, pointing at the
# tarball on the GitHub release, and builds the package from the local tarball with makepkg
# into dist/arch. Run packaging/tarball/build-tarball.sh first, on Arch: it makes
# dist/arch/signet-gtk-<version>-arch-<arch>.tar.xz, which goes on the release beside Debian's.
#
#   packaging/arch/build-arch.sh
#   VERSION=0.8 packaging/arch/build-arch.sh
#
# dist/arch/PKGBUILD and .SRCINFO are what goes to the AUR.
set -eu

# Packages built on Debian did not work on Arch, so this builds only on the system it packages
# for (the build farm builds each package natively).
# In a subshell: os-release sets VERSION too ("45 (Container Image)" on Fedora).
OS=$(. /etc/os-release; echo " $ID ${ID_LIKE:-} ")
PRETTY=$(. /etc/os-release; echo "$PRETTY_NAME")
case "$OS" in
    *" arch "*) ;;
    *) echo "build this package on Arch itself, not on $PRETTY" >&2; exit 1 ;;
esac

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
cd "$ROOT"

VERSION=${VERSION:-$(packaging/version.sh)}
# pacman versions cannot hold '-'; a test build's '+git…' becomes '.r…' as Arch writes them.
PKGVER=$(echo "$VERSION" | sed 's/+git/.r/; s/-/_/g')
ARCH=$(uname -m)
TARBALL="dist/arch/signet-gtk-$VERSION-arch-$ARCH.tar.xz"
[ -f "$TARBALL" ] || { echo "$TARBALL is missing: run packaging/tarball/build-tarball.sh" >&2; exit 1; }
[ "$PKGVER" = "$VERSION" ] || { echo "the tarball's version $VERSION is not a pacman version; tag the release first" >&2; exit 1; }
SHA=$(sha256sum "$TARBALL" | cut -d' ' -f1)
URL="https://github.com/drchrispinnock/signet-gtk/releases/download/v$VERSION/$(basename "$TARBALL")"

mkdir -p dist/arch
sed -e "s|@VERSION@|$PKGVER|" -e "s|@SHA256@|$SHA|" -e "s|@SOURCE@|$URL|" packaging/arch/PKGBUILD.in > dist/arch/PKGBUILD

# Build here from the local tarball, so nothing is downloaded and the release need not exist yet.
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
sed "s|^source=.*|source=(\"$(basename "$TARBALL")\")|" dist/arch/PKGBUILD > "$WORK/PKGBUILD"
cp "$TARBALL" "$WORK/"
# Arch's own makepkg.conf compresses with zstd; Debian's defaults to gzip.
(cd "$WORK" && PKGDEST="$ROOT/dist/arch" PKGEXT=.pkg.tar.zst PACKAGER="${PACKAGER:-Chris Pinnock <chris_pinnock@mac.com>}" makepkg --nodeps --force --noconfirm)
(cd dist/arch && makepkg --printsrcinfo > .SRCINFO)
ls dist/arch/*.pkg.tar.*
