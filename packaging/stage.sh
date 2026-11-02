#!/bin/sh
# Builds the release binary and lays out what every package installs, under DESTDIR with the
# given PREFIX (default /usr):
#
#   PREFIX/lib/signet-gtk/signet-gtk                  the program (Swift runtime linked in)
#   PREFIX/lib/signet-gtk/signet-gtk_Signet.bundle/   its resources, which it looks for beside it
#   PREFIX/bin/signet-gtk                             a relative symlink to the program
#   PREFIX/share/applications/org.tezos.signet.desktop
#   PREFIX/share/icons/hicolor/256x256/apps/org.tezos.signet.png
#   PREFIX/share/doc/signet-gtk/copyright
#   PREFIX/lib/udev/rules.d/70-signet-ledger.rules   the Ledger rule (the tarball's install.sh
#                                                     puts it in /etc/udev/rules.d instead)
#
#   packaging/stage.sh DESTDIR [PREFIX]
#
# SKIP_BUILD=1 reuses the release build already in .build.
set -eu

DESTDIR=${1:?usage: stage.sh DESTDIR [PREFIX]}
PREFIX=${2-/usr}   # an empty PREFIX is the top of DESTDIR (the tarball)
ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"
PATH="$HOME/.local/share/swiftly/bin:$PATH"

[ "${SKIP_BUILD:-0}" = 1 ] || swift build -c release --static-swift-stdlib
BIN=.build/release/signet-gtk
BUNDLE=.build/release/signet-gtk_Signet.bundle
[ -x "$BIN" ] && [ -d "$BUNDLE" ] || { echo "release build is missing $BIN or $BUNDLE" >&2; exit 1; }

P="$DESTDIR$PREFIX"
install -d "$P/lib/signet-gtk" "$P/bin"
install -m 755 "$BIN" "$P/lib/signet-gtk/signet-gtk"
strip --strip-unneeded "$P/lib/signet-gtk/signet-gtk"
rm -rf "$P/lib/signet-gtk/signet-gtk_Signet.bundle"
cp -r "$BUNDLE" "$P/lib/signet-gtk/"
find "$P/lib/signet-gtk/signet-gtk_Signet.bundle" -type f -exec chmod 644 {} +
find "$P/lib/signet-gtk/signet-gtk_Signet.bundle" -type d -exec chmod 755 {} +
ln -sfn ../lib/signet-gtk/signet-gtk "$P/bin/signet-gtk"

install -D -m 644 packaging/linux/org.tezos.signet.desktop "$P/share/applications/org.tezos.signet.desktop"
install -D -m 644 upstream/docs/images/signet-256.png "$P/share/icons/hicolor/256x256/apps/org.tezos.signet.png"
install -D -m 644 LICENSE "$P/share/doc/signet-gtk/copyright"
install -D -m 644 packaging/linux/70-signet-ledger.rules "$P/lib/udev/rules.d/70-signet-ledger.rules"
