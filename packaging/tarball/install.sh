#!/bin/sh
# Installs Signet from this directory.
#
#   sudo ./install.sh                  into /usr/local, for everyone (with the Ledger udev rule)
#   ./install.sh --user                into ~/.local, for you only (no root; see the Ledger note)
#   sudo ./install.sh --prefix /opt/signet
#
# What was installed is listed in <prefix>/lib/signet-gtk/installed-files, which uninstall.sh
# reads. Your wallet (~/.signet, ~/.signet_backups) is never touched.
set -eu

HERE=$(cd "$(dirname "$0")" && pwd)
PREFIX=/usr/local
USER_INSTALL=0
while [ $# -gt 0 ]; do
    case $1 in
        --user) USER_INSTALL=1; PREFIX="$HOME/.local" ;;
        --prefix) PREFIX=${2:?--prefix needs a directory}; shift ;;
        -h|--help) sed -n '2,9p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "unknown option: $1" >&2; exit 2 ;;
    esac
    shift
done

LIB="$PREFIX/lib/signet-gtk"
MANIFEST="$LIB/installed-files"
if [ -e "$MANIFEST" ]; then
    echo "Replacing the Signet already in $PREFIX."
    "$HERE/uninstall.sh" --prefix "$PREFIX" --quiet
fi

install -d "$LIB" "$PREFIX/bin"
cp -r "$HERE/lib/signet-gtk/signet-gtk" "$HERE/lib/signet-gtk/signet-gtk_Signet.bundle" "$LIB/"
ln -sfn "$LIB/signet-gtk" "$PREFIX/bin/signet-gtk"
# The launcher names the program by its full path, so it works whether or not PREFIX/bin is on
# the menu's PATH.
install -d "$PREFIX/share/applications"
sed "s|^Exec=signet-gtk|Exec=$PREFIX/bin/signet-gtk|" "$HERE/share/applications/org.tezos.signet.desktop" \
    > "$PREFIX/share/applications/org.tezos.signet.desktop"
install -D -m 644 "$HERE/share/icons/hicolor/256x256/apps/org.tezos.signet.png" "$PREFIX/share/icons/hicolor/256x256/apps/org.tezos.signet.png"
install -D -m 644 "$HERE/share/doc/signet-gtk/copyright" "$PREFIX/share/doc/signet-gtk/copyright"

{
    echo "$PREFIX/bin/signet-gtk"
    echo "$PREFIX/share/applications/org.tezos.signet.desktop"
    echo "$PREFIX/share/icons/hicolor/256x256/apps/org.tezos.signet.png"
    echo "$PREFIX/share/doc/signet-gtk/copyright"
} > "$MANIFEST"

UDEV_RULE=/etc/udev/rules.d/70-signet-ledger.rules
if [ "$USER_INSTALL" = 0 ] && [ "$(id -u)" = 0 ]; then
    install -D -m 644 "$HERE/lib/udev/rules.d/70-signet-ledger.rules" "$UDEV_RULE"
    echo "$UDEV_RULE" >> "$MANIFEST"
    if command -v udevadm >/dev/null 2>&1; then
        udevadm control --reload-rules 2>/dev/null || true
        udevadm trigger --subsystem-match=usb --attr-match=idVendor=2c97 2>/dev/null || true
    fi
    LEDGER_NOTE=""
else
    LEDGER_NOTE="To use a Ledger, install its udev rule once as root:
  sudo install -m 644 '$HERE/lib/udev/rules.d/70-signet-ledger.rules' $UDEV_RULE && sudo udevadm control --reload-rules"
fi

command -v gtk-update-icon-cache >/dev/null 2>&1 && gtk-update-icon-cache -q -t "$PREFIX/share/icons/hicolor" 2>/dev/null || true
command -v update-desktop-database >/dev/null 2>&1 && update-desktop-database -q "$PREFIX/share/applications" 2>/dev/null || true

echo "Signet is installed in $PREFIX. Start it from the applications menu or with: $PREFIX/bin/signet-gtk"
[ -z "$LEDGER_NOTE" ] || echo "$LEDGER_NOTE"
