# Packages the files packaging/stage.sh lays out (a release build with the Swift runtime linked
# in), so the RPM is built on any machine with rpmbuild: packaging/rpm/build-rpm.sh. Library
# dependencies are found by rpm from the binary (libadwaita-1.so.0()(64bit) and so on), which
# keeps one package good for Fedora 42+ and openSUSE Tumbleweed.

%global debug_package %{nil}
%global _build_id_links none
# The binary is stripped already; rpm's own post-install steps would only rewrite it.
%global __os_install_post %{nil}

Name:           signet-gtk
Version:        %{pkg_version}
Release:        1
Summary:        Tezos wallet for Linux (GTK port of Signet)
License:        MIT
URL:            https://github.com/drchrispinnock/signet-gtk
ExclusiveArch:  %{pkg_arch}

# The library names rpm finds do not say which release: Signet uses GTK 4.18 and libadwaita 1.7
# (AdwToggleGroup). Fedora and openSUSE name the packages differently.
Requires:       (gtk4 >= 4.18 or libgtk-4-1 >= 4.18)
Requires:       (libadwaita >= 1.7 or libadwaita-1-0 >= 1.7)
Requires:       curl
# gdk-pixbuf's SVG loader, for the token logos.
Requires:       (librsvg2 or gdk-pixbuf-loader-rsvg)
Recommends:     (google-noto-color-emoji-fonts or noto-coloremoji-fonts)

%description
Signet keeps Tezos accounts in octez-client's format in ~/.signet: create or
import keys (encrypted with a password), use a Ledger, send and receive tez,
delegate and stake, run a baker's keys and parameters, vote in governance,
use generic multisigs and connect to dApps over Octez Connect.

This is the GTK 4 / libadwaita port of the macOS app, compiled from the same
Swift sources. The Swift runtime is linked in.

%install
cp -a %{stagedir}/. %{buildroot}/

%post
# Pick up the Ledger rule for devices already plugged in.
if command -v udevadm >/dev/null 2>&1; then
    udevadm control --reload-rules 2>/dev/null || :
    udevadm trigger --subsystem-match=usb --attr-match=idVendor=2c97 2>/dev/null || :
fi
# The signet:// handler (MimeType in the desktop entry).
command -v update-desktop-database >/dev/null 2>&1 && update-desktop-database -q /usr/share/applications 2>/dev/null || :

%postun
command -v update-desktop-database >/dev/null 2>&1 && update-desktop-database -q /usr/share/applications 2>/dev/null || :

%files
%license /usr/share/doc/signet-gtk/copyright
/usr/bin/signet-gtk
/usr/lib/signet-gtk/
/usr/share/applications/org.tezos.signet.desktop
/usr/share/icons/hicolor/256x256/apps/org.tezos.signet.png
/usr/lib/udev/rules.d/70-signet-ledger.rules
