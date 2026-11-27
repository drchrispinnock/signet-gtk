Signet for Linux
================

A Tezos wallet: the GTK 4 / libadwaita port of Signet for the Mac. The program is ready to run;
the Swift runtime is linked in.

Install
  sudo ./install.sh            for everyone, into /usr/local (adds the Ledger udev rule)
  ./install.sh --user          for you only, into ~/.local (no root)

Remove
  sudo ./uninstall.sh   or   ./uninstall.sh --user

Or run it in place: ./bin/signet-gtk

Made for Debian 13 (trixie). It uses these Debian packages:
  libgtk-4-1, libadwaita-1-0, libjavascriptcoregtk-6.0-1, libhidapi-hidraw0,
  libwebp7, libcurl4t64, curl, librsvg2-common

Accounts are kept in ~/.signet in octez-client's format; backups go to ~/.signet_backups.
Source and issues: https://github.com/drchrispinnock/signet-gtk
