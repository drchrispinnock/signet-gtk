#!/bin/sh
# Builds signet-gtk_<version>_<arch>.deb in dist/<platform>/ (packaging/distdir.sh) from what packaging/stage.sh lays out under /usr:
# a release build with the Swift runtime linked statically (so the package needs no Swift
# toolchain), a launcher, desktop entry, icon and Ledger udev rule.
#
#   packaging/deb/build-deb.sh               # version from packaging/version.sh
#   VERSION=0.8 packaging/deb/build-deb.sh
#
# Needs dpkg-deb and dpkg-shlibdeps (dpkg-dev; no fakeroot: --root-owner-group sets the ownership).
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

# The libraries' package names and least versions on the system building it (Debian and Ubuntu
# name some differently), from the binary's NEEDED libraries. GTK's least version by symbols is
# older than Signet needs: it uses GTK 4.18 (libadwaita's own floor, 1.7, comes out right).
install -d "$STAGE/debian"
printf 'Source: %s\n\nPackage: %s\nArchitecture: any\n' "$PACKAGE" "$PACKAGE" > "$STAGE/debian/control"
SHLIBS=$(cd "$STAGE" && dpkg-shlibdeps -O -e "$PACKAGE/usr/lib/signet-gtk/signet-gtk" 2>/dev/null |
    sed -n 's/^shlibs:Depends=//p' | sed 's/libgtk-4-1 ([^)]*)/libgtk-4-1 (>= 4.18)/')
[ -n "$SHLIBS" ] || { echo "dpkg-shlibdeps found no dependencies" >&2; exit 1; }
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
Depends: $SHLIBS, curl, librsvg2-common
Recommends: fonts-noto-color-emoji, libzbar0t64 | libzbar0
Description: Tezos wallet for Linux (GTK port of Signet)
 Signet keeps Tezos accounts in octez-client's format in ~/.signet: create or
 import keys (encrypted with a password), use a Ledger, send and receive tez,
 delegate and stake, run a baker's keys and parameters, vote in governance,
 use generic multisigs and connect to dApps over Octez Connect.
 .
 This is the GTK 4 / libadwaita port of the macOS app, compiled from the same
 Swift sources. The Swift runtime is linked in.
EOF

DIST="dist/$(packaging/distdir.sh)"
mkdir -p "$DIST"
OUT="$DIST/${PACKAGE}_${VERSION}_${ARCH}.deb"
dpkg-deb --root-owner-group -Zxz --build "$PKG" "$OUT"
echo "$OUT"
