#!/bin/sh
# Builds dist/signet-gtk-<version>-1.<arch>.rpm with rpmbuild (Debian: apt install rpm) from what
# packaging/stage.sh lays out under /usr.
#
#   packaging/rpm/build-rpm.sh
#   VERSION=0.8 SKIP_BUILD=1 packaging/rpm/build-rpm.sh
set -eu

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
cd "$ROOT"

VERSION=${VERSION:-$(packaging/version.sh)}
ARCH=$(uname -m)

TOP=$(mktemp -d)
trap 'rm -rf "$TOP"' EXIT
packaging/stage.sh "$TOP/stage" /usr

rpmbuild -bb --quiet \
    --define "_topdir $TOP" \
    --define "pkg_version $VERSION" \
    --define "pkg_arch $ARCH" \
    --define "stagedir $TOP/stage" \
    --target "$ARCH" \
    packaging/rpm/signet-gtk.spec

mkdir -p dist
for rpm in "$TOP"/RPMS/*/*.rpm; do
    cp "$rpm" dist/
    echo "dist/$(basename "$rpm")"
done
