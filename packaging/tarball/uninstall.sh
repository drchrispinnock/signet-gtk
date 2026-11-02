#!/bin/sh
# Removes a Signet that install.sh put in place. Your wallet (~/.signet, ~/.signet_backups) is
# never touched.
#
#   sudo ./uninstall.sh                from /usr/local
#   ./uninstall.sh --user              from ~/.local
#   sudo ./uninstall.sh --prefix /opt/signet
set -eu

PREFIX=/usr/local
QUIET=0
while [ $# -gt 0 ]; do
    case $1 in
        --user) PREFIX="$HOME/.local" ;;
        --prefix) PREFIX=${2:?--prefix needs a directory}; shift ;;
        --quiet) QUIET=1 ;;
        *) echo "unknown option: $1" >&2; exit 2 ;;
    esac
    shift
done

LIB="$PREFIX/lib/signet-gtk"
MANIFEST="$LIB/installed-files"
[ -e "$MANIFEST" ] || { echo "No Signet installed by install.sh in $PREFIX." >&2; exit 1; }
while IFS= read -r file; do
    rm -f "$file"
done < "$MANIFEST"
rm -rf "$LIB"
rmdir "$PREFIX/share/doc/signet-gtk" 2>/dev/null || true
command -v gtk-update-icon-cache >/dev/null 2>&1 && gtk-update-icon-cache -q -t "$PREFIX/share/icons/hicolor" 2>/dev/null || true
command -v update-desktop-database >/dev/null 2>&1 && update-desktop-database -q "$PREFIX/share/applications" 2>/dev/null || true
[ "$QUIET" = 1 ] || echo "Signet is removed from $PREFIX."
