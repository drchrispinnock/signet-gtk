#!/bin/sh
# Builds the release binary and lays out what every package installs, under DESTDIR with the
# given PREFIX (default /usr):
#
#   PREFIX/lib/signet-gtk/signet-gtk                  the program (Swift runtime linked in)
#   PREFIX/lib/signet-gtk/signet-gtk_Signet.bundle/   its resources, which it looks for beside it
#                                                     (.resources on FreeBSD, as SwiftPM names it)
#   PREFIX/bin/signet-gtk                             a relative symlink to the program
#   PREFIX/share/applications/org.tezos.signet.desktop
#   PREFIX/share/icons/hicolor/256x256/apps/org.tezos.signet.png
#   PREFIX/share/doc/signet-gtk/copyright
#   PREFIX/lib/udev/rules.d/70-signet-ledger.rules   the Ledger rule (the tarball's install.sh
#                                                     puts it in /etc/udev/rules.d instead; not on
#                                                     FreeBSD, which has devd rather than udev)
#
#   packaging/stage.sh DESTDIR [PREFIX]
#
# SKIP_BUILD=1 reuses the release build already in .build (.build-freebsd on FreeBSD).
set -eu

DESTDIR=${1:?usage: stage.sh DESTDIR [PREFIX]}
PREFIX=${2-/usr}   # an empty PREFIX is the top of DESTDIR (the tarball)
ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"
PATH="$HOME/.local/share/swiftly/bin:/usr/local/swift6/usr/local/bin:$PATH"   # swift6: FreeBSD's package

if [ "$(uname -s)" = FreeBSD ]; then
    # SwiftPM 6.4's Swift Build never gets past planning a --static-swift-stdlib build here (it
    # spins), and its native build system drops that option off Linux, so -static-stdlib goes to
    # swiftc itself. The native build gets a directory of its own, apart from Swift Build's.
    SCRATCH=.build-freebsd
    [ "${SKIP_BUILD:-0}" = 1 ] ||
        swift build -c release -Xswiftc -static-stdlib --build-system native --scratch-path "$SCRATCH"
    RESOURCES=signet-gtk_Signet.resources
else
    SCRATCH=.build
    [ "${SKIP_BUILD:-0}" = 1 ] || swift build -c release --static-swift-stdlib
    RESOURCES=signet-gtk_Signet.bundle
fi
BIN=$SCRATCH/release/signet-gtk
BUNDLE=$SCRATCH/release/$RESOURCES
[ -x "$BIN" ] && [ -d "$BUNDLE" ] || { echo "release build is missing $BIN or $BUNDLE" >&2; exit 1; }

P="$DESTDIR$PREFIX"
install -d "$P/lib/signet-gtk" "$P/bin"
install -m 755 "$BIN" "$P/lib/signet-gtk/signet-gtk"
strip --strip-unneeded "$P/lib/signet-gtk/signet-gtk"
rm -rf "$P/lib/signet-gtk/$RESOURCES"
cp -r "$BUNDLE" "$P/lib/signet-gtk/"
find "$P/lib/signet-gtk/$RESOURCES" -type f -exec chmod 644 {} +
find "$P/lib/signet-gtk/$RESOURCES" -type d -exec chmod 755 {} +
ln -sfn ../lib/signet-gtk/signet-gtk "$P/bin/signet-gtk"

# install -d first: BSD install's -D is not GNU's "make the directories".
install -d "$P/share/applications" "$P/share/icons/hicolor/256x256/apps" "$P/share/doc/signet-gtk"
install -m 644 packaging/linux/org.tezos.signet.desktop "$P/share/applications/org.tezos.signet.desktop"
install -m 644 upstream/docs/images/signet-256.png "$P/share/icons/hicolor/256x256/apps/org.tezos.signet.png"
install -m 644 LICENSE "$P/share/doc/signet-gtk/copyright"
if [ "$(uname -s)" = Linux ]; then
    install -d "$P/lib/udev/rules.d"
    install -m 644 packaging/linux/70-signet-ledger.rules "$P/lib/udev/rules.d/70-signet-ledger.rules"
fi
