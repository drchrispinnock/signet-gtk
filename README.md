<p align="center">
  <img src="docs/images/signet-256.png" width="160" alt="Signet: a gold signet ring engraved with the Tezos ꜩ">
</p>

<h1 align="center">Signet GTK for Linux and FreeBSD</h1>


Port of the [Signet](https://github.com/drchrispinnock/signet) Tezos wallet to Linux and other
Unices: GTK 4 and libadwaita, compiled from the Mac app's own Swift sources. It keeps accounts in
`~/.signet` in octez-client's format, works with a Ledger, and does sending, staking, baking,
governance, multisig and dApps (Octez Connect) on layer 1, Etherlink (send, receive, the
bridge and dApps on its Michelson side) and shielded tez on the TzEL rollup.

## Install

Packages for **Debian 13 (trixie)** on amd64 are on the
[releases page](https://github.com/drchrispinnock/signet-gtk/releases), with the Swift runtime
linked in.

- **Debian 13:** `sudo apt install ./signet-gtk_<version>_amd64.deb`
- **Or the tarball, on Debian 13:** unpack `signet-gtk-<version>-linux-x86_64.tar.xz` and run
  `sudo ./install.sh` (or `./install.sh --user` to install into `~/.local` without root);
  `uninstall.sh` removes it.

Signet then appears in the applications menu. The package installs a udev rule that lets you use
a Ledger without root; with the tarball's `--user` install, `install.sh` prints the one command
that adds it.

## Build from source

You need Swift 6 (tested with 6.4) and the development files for GTK 4, libadwaita,
WebKitGTK 6.0 (its JavaScriptCore runs the Taquito bridge, its web view the Buy sheet's on-ramp),
hidapi and libwebp. These steps have been tried on Debian 13.

**1. System packages.** The first two lines are what Swift itself needs, the rest is for Signet:

```sh
sudo apt install git curl gnupg binutils binutils-gold g++ unzip zip libcurl4-openssl-dev \
    libpython3-dev libxml2-dev libncurses-dev libz3-dev \
    pkg-config libgtk-4-dev libadwaita-1-dev libjavascriptcoregtk-6.0-dev libwebkitgtk-6.0-dev \
    libhidapi-dev libwebp-dev zlib1g-dev librsvg2-common libzbar0t64
```

libzbar is only opened when Signet runs: without it Signet works, but Scan QR code (which also
needs a camera) does not show.

**2. Swift**, with [swiftly](https://www.swift.org/install/linux/), which installs it in
`~/.local/share/swiftly` and adds it to your path through `~/.profile`:

```sh
curl -O https://download.swift.org/swiftly/linux/swiftly-$(uname -m).tar.gz
tar zxf swiftly-$(uname -m).tar.gz && ./swiftly init
. ~/.local/share/swiftly/env.sh     # this shell; new logins get it from ~/.profile
hash -r
swift --version
```

If `swift --version` says there is no `swift`, swiftly installed itself but not Swift: `swiftly
init` gives up when a package Swift needs is missing, and prints an `apt-get install …` line.
Run that line with `sudo`, then `swiftly install --use latest`.

**3. Signet.** Clone it with the Mac app as a submodule, build and run:

```sh
git clone --recursive https://github.com/drchrispinnock/signet-gtk.git
cd signet-gtk
swift build -c release --static-swift-stdlib
.build/release/signet-gtk
```

The first build takes a few minutes. `--static-swift-stdlib` links the Swift runtime into the
program, so it runs on a machine without Swift. The program looks for its resources in
`signet-gtk_Signet.bundle` beside it: copy both together if you move it. A plain `swift build`
makes a debug build in `.build/debug`. To update later: `git pull && git submodule update`, then
build again.

Elsewhere, install the same libraries under their own names (GTK 4.18 and libadwaita 1.7 or
newer); `swiftly init` lists what Swift needs.

Run the tests with:

```sh
swift build --build-tests && swift test --skip-build --no-parallel
```

### FreeBSD

Signet builds and runs on FreeBSD with Swift's FreeBSD preview toolchain (see
[swift.org/install](https://www.swift.org/install/)). These steps have been tried on FreeBSD 15.1
on amd64, with a Swift 6.5 development snapshot made for FreeBSD 14.

**1. Packages.** The first line is what the Swift toolchain needs (`compat14x-amd64` only when
running a toolchain made for FreeBSD 14 on 15), the second is for Signet. GTK needs at least one
font installed: with none, the window comes up blank.

```sh
sudo pkg install git curl sqlite3 libuuid compat14x-amd64 \
    pkgconf gtk4 libadwaita webkit2-gtk_60 hidapi webp zbar dejavu adwaita-icon-theme
```

**2. Swift.** The toolchain is a tarball holding a `usr` directory; unpack it anywhere and put its
`usr/bin` on your path, for example:

```sh
mkdir ~/swift && tar xzf <toolchain>.tar.gz -C ~/swift
export PATH=$HOME/swift/usr/bin:$PATH     # sh; for csh: set path = ($HOME/swift/usr/bin $path)
swift --version
```

**3. Signet** builds the same way as on Linux:

```sh
git clone --recursive https://github.com/drchrispinnock/signet-gtk.git
cd signet-gtk
swift build -c release --static-swift-stdlib
.build/release/signet-gtk
```

The tests run as on Linux too; two of them need `python3` (`sudo pkg install python3`). Using a
Ledger on FreeBSD has not been tried yet.

If the window comes up blank and the terminal fills with GTK warnings about labels needing a
height of over a million pixels, no font is installed: `sudo pkg install dejavu`, quit Signet and
start it again (a second launch only hands over to the one already running).

If `~/.config` shows as `drw-rw-rw-` (`ls -ld ~/.config`), Signet cannot save its settings and
other programs cannot read theirs there: Swift's Foundation on FreeBSD creates a missing
`~/.config` without the directory's execute bit. Signet now creates it itself first, but one made
by an older build or by the tests needs repairing once:

```sh
chmod 700 ~/.config
```

**Over SSH.** To run Signet on a FreeBSD machine with no desktop and show it on yours, the
machine needs `xauth` for X11 forwarding (`sudo pkg install xauth`; without it sshd refuses with
"No xauth program; cannot forward X11"). Then:

```sh
ssh -X user@freebsd-host
GSK_RENDERER=cairo signet-gtk/.build/release/signet-gtk
```

`GSK_RENDERER=cairo` has GTK draw in software, since forwarded X has no GPU.

## Make the packages

On Debian 13, from a source checkout, after building once:

```sh
packaging/deb/build-deb.sh          # dist/debian-13/signet-gtk_<version>_<arch>.deb       (needs dpkg-deb)
packaging/tarball/build-tarball.sh  # dist/debian-13/signet-gtk-<version>-linux-<arch>.tar.xz
```

`packaging/rpm` and `packaging/arch` build only on the systems they package for. With Docker,
`packaging/farm/build.sh` builds every package on its own system, in containers, into
`dist/<platform>/` (`debian-13`, `ubuntu-2604`, `fedora-45`, `arch`), and
`packaging/farm/smoke.sh` installs each into a clean container and starts it.

The version is the repository's tag when the commit is tagged (`v0.8` gives `0.8`), otherwise the
last tag plus the date and commit; `VERSION=…` overrides it. `SKIP_BUILD=1` reuses the release
build already made.
