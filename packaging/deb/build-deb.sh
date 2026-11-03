#!/bin/sh
# Builds signet-gtk_<version>_<arch>.deb in dist/ from what packaging/stage.sh lays out under /usr:
# a release build with the Swift runtime linked statically (so the package needs no Swift
# toolchain), a launcher, desktop entry, icon and Ledger udev rule.
#
#   packaging/deb/build-deb.sh               # version from packaging/version.sh
#   VERSION=0.8 packaging/deb/build-deb.sh
#
# Needs only dpkg-deb (no fakeroot: --root-owner-group sets the ownership).
set -eu

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
cd "$ROOT"
PATH="$HOME/.local/share/swiftly/bin:$PATH"

PACKAGE=signet-gtk
ARCH=$(dpkg --print-architecture)
VERSION=${VERSION:-$(packaging/version.sh)}
MAINTAINER=${MAINTAINER:-"${DEBFULLNAME:-Chris Pinnock} <${DEBEMAIL:-chris_pinnock@mac.com}>"}

STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
PKG="$STAGE/$PACKAGE"
packaging/stage.sh "$PKG" /usr

install -d "$PKG/DEBIAN"
install -m 755 packaging/deb/postinst packaging/deb/postrm "$PKG/DEBIAN/"
SIZE=$(du -sk --exclude=DEBIAN "$PKG" | cut -f1)
cat > "$PKG/DEBIAN/control" <<EOF
Package: $PACKAGE
Version: $VERSION
Architecture: $ARCH
Maintainer: $MAINTAINER
Installed-Size: $SIZE
Section: utils
Priority: optional
Homepage: https://github.com/drchrispinnock/signet
Depends: libc6 (>= 2.38), libgcc-s1, libstdc++6, libglib2.0-0t64 (>= 2.84), libgtk-4-1 (>= 4.18), libadwaita-1-0 (>= 1.7), libjavascriptcoregtk-6.0-1, libwebkitgtk-6.0-4, libhidapi-hidraw0, libwebp7, libcurl4t64, libpango-1.0-0, libpangocairo-1.0-0, libharfbuzz0b, libcairo2, libcairo-gobject2, libgdk-pixbuf-2.0-0, libgraphene-1.0-0, libvulkan1, curl, librsvg2-common
Recommends: fonts-noto-color-emoji
Description: Tezos wallet for Linux (GTK port of Signet)
 Signet keeps Tezos accounts in octez-client's format in ~/.signet: create or
 import keys (encrypted with a password), use a Ledger, send and receive tez,
 delegate and stake, run a baker's keys and parameters, vote in governance,
 use generic multisigs and connect to dApps over Octez Connect.
 .
 This is the GTK 4 / libadwaita port of the macOS app, compiled from the same
 Swift sources. The Swift runtime is linked in.
EOF

mkdir -p dist
OUT="dist/${PACKAGE}_${VERSION}_${ARCH}.deb"
dpkg-deb --root-owner-group -Zxz --build "$PKG" "$OUT"
echo "$OUT"
