# signet-gtk

Port of the [Signet](https://github.com/drchrispinnock/signet) Tezos wallet to Linux and other
Unices: GTK 4 and libadwaita, compiled from the Mac app's own Swift sources. It keeps accounts in
`~/.signet` in octez-client's format, works with a Ledger, and does sending, staking, baking,
governance, multisig and dApps (Octez Connect) on layer 1. Etherlink and shielded tez are not
ported yet.

## Install

Packages are on the [releases page](https://github.com/drchrispinnock/signet-gtk/releases). Each
has the Swift runtime linked in and needs glibc 2.41 or newer (Debian 13, Ubuntu 25.04, Fedora 42,
openSUSE Tumbleweed, Arch).

- **Debian, Ubuntu:** `sudo apt install ./signet-gtk_<version>_amd64.deb`
- **Fedora, openSUSE:** `sudo dnf install ./signet-gtk-<version>-1.x86_64.rpm` (or `zypper install`)
- **Arch:** `sudo pacman -U signet-gtk-bin-<version>-1-x86_64.pkg.tar.zst`
- **Anything else:** unpack `signet-gtk-<version>-linux-x86_64.tar.xz` and run `sudo ./install.sh`
  (or `./install.sh --user` to install into `~/.local` without root); `uninstall.sh` removes it.

Signet then appears in the applications menu. The packages install a udev rule that lets you use
a Ledger without root; with the tarball's `--user` install, `install.sh` prints the one command
that adds it.

## Build from source

You need Swift 6 (tested with 6.4) and the development files for GTK 4, libadwaita,
JavaScriptCore (WebKitGTK 6.0), hidapi and libwebp.

On Debian 13:

```sh
sudo apt install git curl pkg-config libgtk-4-dev libadwaita-1-dev \
    libjavascriptcoregtk-6.0-dev libhidapi-dev libwebp-dev librsvg2-common
```

Install Swift with [swiftly](https://www.swift.org/install/linux/), which puts it in
`~/.local/share/swiftly/bin`:

```sh
curl -O https://download.swift.org/swiftly/linux/swiftly-$(uname -m).tar.gz
tar zxf swiftly-$(uname -m).tar.gz && ./swiftly init
```

Then clone with the Mac app as a submodule, build and run:

```sh
git clone --recursive https://github.com/drchrispinnock/signet-gtk.git
cd signet-gtk
swift build -c release --static-swift-stdlib
.build/release/signet-gtk
```

`--static-swift-stdlib` links the Swift runtime into the program, so it runs on a machine without
Swift. The program looks for its resources in `signet-gtk_Signet.bundle` beside it: copy both
together if you move it. A plain `swift build` makes a debug build in `.build/debug`.

Other distributions need the same libraries under their own names, for example on Fedora
`gtk4-devel libadwaita-devel javascriptcoregtk6.0-devel hidapi-devel libwebp-devel`, and on Arch
`gtk4 libadwaita webkitgtk-6.0 hidapi libwebp`; only Debian 13 has been tried.

Run the tests with:

```sh
swift build --build-tests && swift test --skip-build --no-parallel
```

## Make the packages

From a source checkout, after building once:

```sh
packaging/deb/build-deb.sh          # dist/signet-gtk_<version>_<arch>.deb       (needs dpkg-deb)
packaging/rpm/build-rpm.sh          # dist/signet-gtk-<version>-1.<arch>.rpm     (needs rpmbuild: apt install rpm)
packaging/tarball/build-tarball.sh  # dist/signet-gtk-<version>-linux-<arch>.tar.xz
packaging/arch/build-arch.sh        # dist/signet-gtk-bin-…pkg.tar.zst, and dist/arch/PKGBUILD for the AUR
                                    #   (needs makepkg: apt install makepkg; run after the tarball)
```

The version is the repository's tag when the commit is tagged (`v0.8` gives `0.8`), otherwise the
last tag plus the date and commit; `VERSION=…` overrides it. `SKIP_BUILD=1` reuses the release
build already made.
