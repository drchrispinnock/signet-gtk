#!/bin/sh
# Writes dist/arch/PKGBUILD (and .SRCINFO) for signet-gtk-bin from PKGBUILD.in, pointing at the
# release tarball on GitHub, and builds the package from the local tarball with makepkg
# (Debian: apt install makepkg) into dist/. Run packaging/tarball/build-tarball.sh first.
#
#   packaging/arch/build-arch.sh
#   VERSION=0.8 packaging/arch/build-arch.sh
#
# dist/arch/PKGBUILD and .SRCINFO are what goes to the AUR.
set -eu

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
cd "$ROOT"

VERSION=${VERSION:-$(packaging/version.sh)}
# pacman versions cannot hold '-'; a test build's '+git…' becomes '.r…' as Arch writes them.
PKGVER=$(echo "$VERSION" | sed 's/+git/.r/; s/-/_/g')
ARCH=$(uname -m)
TARBALL="dist/signet-gtk-$VERSION-linux-$ARCH.tar.xz"
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
(cd "$WORK" && PKGDEST="$ROOT/dist" PKGEXT=.pkg.tar.zst PACKAGER="${PACKAGER:-Chris Pinnock <chris_pinnock@mac.com>}" makepkg --nodeps --force --noconfirm)
(cd dist/arch && makepkg --printsrcinfo > .SRCINFO)
ls dist/*.pkg.tar.*
