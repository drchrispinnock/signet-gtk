#!/bin/sh
# Builds dist/signet-gtk-<version>-linux-<arch>.tar.xz: the files packaging/stage.sh lays out,
# relative to the top of the archive (bin/, lib/, share/), with install.sh, uninstall.sh and a
# README. It runs in place too (bin/signet-gtk).
#
#   packaging/tarball/build-tarball.sh
#   VERSION=0.8 SKIP_BUILD=1 packaging/tarball/build-tarball.sh
set -eu

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
cd "$ROOT"

VERSION=${VERSION:-$(packaging/version.sh)}
ARCH=$(uname -m)
NAME="signet-gtk-$VERSION-linux-$ARCH"

STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
packaging/stage.sh "$STAGE/$NAME" ""
install -m 755 packaging/tarball/install.sh packaging/tarball/uninstall.sh "$STAGE/$NAME/"
install -m 644 packaging/tarball/README.txt "$STAGE/$NAME/"

mkdir -p dist
OUT="dist/$NAME.tar.xz"
tar -C "$STAGE" --owner=0 --group=0 --numeric-owner --sort=name -cJf "$OUT" "$NAME"
echo "$OUT"
