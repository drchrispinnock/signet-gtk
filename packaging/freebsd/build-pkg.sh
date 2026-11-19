#!/bin/sh
# Builds signet-gtk-<version>.pkg in dist/<platform>/ (packaging/distdir.sh: freebsd-15) from what
# packaging/stage.sh lays out under /usr/local: a release build with the Swift runtime linked
# statically (so the package needs no Swift toolchain), a launcher, desktop entry and icon.
# FreeBSD only; Swift is the swift6 package.
#
#   packaging/freebsd/build-pkg.sh             # version from packaging/version.sh
#   VERSION=0.9.19 packaging/freebsd/build-pkg.sh
#
# The package is not in the FreeBSD ports collection: it goes in Signet's own pkg repository,
# whose catalogue `pkg repo` makes and signs (by hand, as the apt repository is). Its
# dependencies name the packages installed on the system building it, at their versions, so build
# against the branch users install from (quarterly, a release's default).
set -eu

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
cd "$ROOT"
[ "$(uname -s)" = FreeBSD ] || { echo "build-pkg.sh builds on FreeBSD only" >&2; exit 1; }

PACKAGE=signet-gtk
# A test build's 0.9.19+git20261119.1a2b3c4 becomes 0.9.19.20261119: pkg's versions have no '+',
# and the extra number sorts the build after the release it follows.
VERSION=${VERSION:-$(packaging/version.sh | sed -E 's/\+git([0-9]+)\..*/.\1/')}
MAINTAINER=${MAINTAINER:-chris_pinnock@mac.com}
PREFIX=/usr/local

STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
packaging/stage.sh "$STAGE/root" "$PREFIX"

# What Signet loads (zbar by dlopen for Scan QR code, librsvg's loader for SVG logos), runs (curl
# for upstream's PublicHTTPClient) and draws with (Adwaita's symbolic icons, which it forces, and
# a font: with none GTK draws nothing). pkg has no weak dependencies, so zbar is a hard one.
DEPS="gtk4 libadwaita webkit2-gtk_60 hidapi webp curl zbar librsvg2-rust adwaita-icon-theme dejavu"
{
    echo 'deps: {'
    for dep in $DEPS; do
        pkg query '  "%n": { origin: "%o", version: "%v" }' "$dep" ||
            { echo "$dep is not installed" >&2; exit 1; }
    done
    echo '}'
} > "$STAGE/deps.ucl"

cat > "$STAGE/+MANIFEST" <<EOF
name: $PACKAGE
origin: finance/$PACKAGE
version: "$VERSION"
comment: "Tezos wallet (GTK port of Signet)"
www: "https://github.com/drchrispinnock/signet-gtk"
maintainer: "$MAINTAINER"
prefix: $PREFIX
categories: [ finance ]
licenselogic: single
licenses: [ MIT ]
desc: <<EOD
Signet keeps Tezos accounts in octez-client's format in ~/.signet: create or
import keys (encrypted with a password), use a Ledger, send and receive tez,
delegate and stake, run a baker's keys and parameters, vote in governance,
use generic multisigs and connect to dApps over Octez Connect.

This is the GTK 4 / libadwaita port of the macOS app, compiled from the same
Swift sources. The Swift runtime is linked in.
EOD
EOF
cat "$STAGE/deps.ucl" >> "$STAGE/+MANIFEST"

# Every file and symlink, owned by root whoever builds it; modes are the staged ones.
{
    echo '@owner root'
    echo '@group wheel'
    (cd "$STAGE/root$PREFIX" && find . \( -type f -o -type l \) | sed 's|^\./||' | sort)
} > "$STAGE/plist"

DIST="dist/$(packaging/distdir.sh)"
mkdir -p "$DIST"
pkg create -M "$STAGE/+MANIFEST" -p "$STAGE/plist" -r "$STAGE/root" -o "$DIST"
echo "$DIST/$PACKAGE-$VERSION.pkg"
