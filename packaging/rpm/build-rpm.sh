#!/bin/sh
# Builds dist/<platform>/signet-gtk-<version>-1.<arch>.rpm (packaging/distdir.sh) with rpmbuild from what
# packaging/stage.sh lays out under /usr.
#
#   packaging/rpm/build-rpm.sh
#   VERSION=0.8 SKIP_BUILD=1 packaging/rpm/build-rpm.sh
set -eu

# Packages built on Debian did not work on Fedora, RHEL or openSUSE, so this builds only on the system it packages
# for (the build farm builds each package natively).
# In a subshell: os-release sets VERSION too ("45 (Container Image)" on Fedora).
OS=$(. /etc/os-release; echo " $ID ${ID_LIKE:-} ")
PRETTY=$(. /etc/os-release; echo "$PRETTY_NAME")
case "$OS" in
    *" fedora "*|*" rhel "*|*" centos "*|*" suse "*|*" opensuse "*) ;;
    *) echo "build this package on Fedora, RHEL or openSUSE itself, not on $PRETTY" >&2; exit 1 ;;
esac

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

DIST="dist/$(packaging/distdir.sh)"
mkdir -p "$DIST"
for rpm in "$TOP"/RPMS/*/*.rpm; do
    cp "$rpm" "$DIST/"
    echo "$DIST/$(basename "$rpm")"
done
