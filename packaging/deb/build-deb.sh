#!/bin/sh
# Builds signet-gtk_<version>_<arch>.deb in dist/: a release build with the Swift runtime linked
# statically (so the package needs no Swift toolchain), installed under /usr/lib/signet-gtk with
# its resource bundle beside it, plus a launcher, desktop entry, icon and Ledger udev rule.
#
#   packaging/deb/build-deb.sh               # version from upstream's tag and this commit
#   VERSION=0.9.12-1 packaging/deb/build-deb.sh
#
# Needs only dpkg-deb (no fakeroot: --root-owner-group sets the ownership).
set -eu

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
cd "$ROOT"
PATH="$HOME/.local/share/swiftly/bin:$PATH"

PACKAGE=signet-gtk
ARCH=$(dpkg --print-architecture)
UPSTREAM=$(git -C upstream describe --tags --abbrev=0 2>/dev/null | sed 's/^v//')
VERSION=${VERSION:-${UPSTREAM:-0.0.0}+git$(git log -1 --format=%cd --date=format:%Y%m%d).$(git rev-parse --short HEAD)}
MAINTAINER=${MAINTAINER:-"${DEBFULLNAME:-Chris Pinnock} <${DEBEMAIL:-chris_pinnock@mac.com}>"}

swift build -c release --static-swift-stdlib
BIN=.build/release/signet-gtk
BUNDLE=.build/release/signet-gtk_Signet.bundle
[ -x "$BIN" ] && [ -d "$BUNDLE" ] || { echo "release build is missing $BIN or $BUNDLE" >&2; exit 1; }

STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
PKG="$STAGE/$PACKAGE"

# The executable finds its resources in signet-gtk_Signet.bundle beside it (Bundle.module).
install -d "$PKG/usr/lib/signet-gtk" "$PKG/usr/bin"
install -m 755 "$BIN" "$PKG/usr/lib/signet-gtk/signet-gtk"
strip --strip-unneeded "$PKG/usr/lib/signet-gtk/signet-gtk"
cp -r "$BUNDLE" "$PKG/usr/lib/signet-gtk/"
find "$PKG/usr/lib/signet-gtk/signet-gtk_Signet.bundle" -type f -exec chmod 644 {} +
find "$PKG/usr/lib/signet-gtk/signet-gtk_Signet.bundle" -type d -exec chmod 755 {} +
ln -s ../lib/signet-gtk/signet-gtk "$PKG/usr/bin/signet-gtk"

install -D -m 644 packaging/linux/org.tezos.signet.desktop "$PKG/usr/share/applications/org.tezos.signet.desktop"
install -D -m 644 upstream/docs/images/signet-256.png "$PKG/usr/share/icons/hicolor/256x256/apps/org.tezos.signet.png"
install -D -m 644 packaging/linux/70-signet-ledger.rules "$PKG/usr/lib/udev/rules.d/70-signet-ledger.rules"
install -D -m 644 LICENSE "$PKG/usr/share/doc/$PACKAGE/copyright"

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
Depends: libc6 (>= 2.41), libgcc-s1, libstdc++6, libglib2.0-0t64 (>= 2.84), libgtk-4-1 (>= 4.18), libadwaita-1-0 (>= 1.7), libjavascriptcoregtk-6.0-1, libhidapi-hidraw0, libwebp7, libcurl4t64, libpango-1.0-0, libpangocairo-1.0-0, libharfbuzz0b, libcairo2, libcairo-gobject2, libgdk-pixbuf-2.0-0, libgraphene-1.0-0, libvulkan1, curl, librsvg2-common
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
