#!/bin/sh
# Builds dist/<platform>/signet-gtk-<version>-linux-<arch>.tar.xz (packaging/distdir.sh): the files packaging/stage.sh lays out,
# relative to the top of the archive (bin/, lib/, share/), with install.sh, uninstall.sh and a
# README. It runs in place too (bin/signet-gtk). Built anywhere but Debian 13 (Arch's package is
# made from one), "linux" in its name is the platform (signet-gtk-<version>-arch-<arch>), so it
# does not clash with the released Debian tarball.
#
#   packaging/tarball/build-tarball.sh
#   VERSION=0.8 SKIP_BUILD=1 packaging/tarball/build-tarball.sh
set -eu

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
cd "$ROOT"

VERSION=${VERSION:-$(packaging/version.sh)}
ARCH=$(uname -m)
PLATFORM=$(packaging/distdir.sh)
case "$PLATFORM" in
    debian-13) NAME="signet-gtk-$VERSION-linux-$ARCH" ;;
    *) NAME="signet-gtk-$VERSION-$PLATFORM-$ARCH" ;;
esac

STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
packaging/stage.sh "$STAGE/$NAME" ""
install -m 755 packaging/tarball/install.sh packaging/tarball/uninstall.sh "$STAGE/$NAME/"
install -m 644 packaging/tarball/README.txt "$STAGE/$NAME/"

mkdir -p "dist/$PLATFORM"
OUT="dist/$PLATFORM/$NAME.tar.xz"
tar -C "$STAGE" --owner=0 --group=0 --numeric-owner --sort=name -cJf "$OUT" "$NAME"
echo "$OUT"
