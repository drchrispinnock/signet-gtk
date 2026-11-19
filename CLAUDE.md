# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

**signet-gtk**: a port of **Signet**, the macOS Tezos wallet written in SwiftUI, to Linux first and
then the BSDs. Linux is the primary target. FreeBSD builds and runs too (see "FreeBSD" below), with
FreeBSD's own `swift6` package. NetBSD and OpenBSD are aims rather than promises: Swift is barely available
there (OpenBSD has no libdispatch, so no async/await). Keep code portable anyway: hidapi for
Ledger rather than Linux hidraw, POSIX `lockf` for `wallet_lock`, and no Linux-only paths or
syscalls outside `Sources/SignetGTK/Platform`.

Stack: Swift 6 (installed with swiftly, `~/.local/share/swiftly/bin`), GTK4 + libadwaita for the
UI, swift-crypto in place of CryptoKit, and the Linux JavaScriptCore (`javascriptcoregtk-6.0`, the
same engine as the Mac) for the Taquito bridge. Development headers come from Debian 13 packages
(`libgtk-4-dev`, `libadwaita-1-dev`, `libjavascriptcoregtk-6.0-dev`, `libwebkitgtk-6.0-dev`,
`libhidapi-dev`, `libwebp-dev`, `zlib1g-dev`, `pkg-config`). WebKitGTK's web view is the Buy sheet's
on-ramp page and the Getting Started window.

The development machine is reached over SSH. The user's own desktop is XFCE on a TigerVNC X
server at `DISPLAY=:1`: put the app there only when the user wants to see it, and never send it
clicks or keys, since the user is working on that desktop and input lands on whatever window is
on top. Test on a private display instead:

```sh
Xvfb :99 -screen 0 1280x1000x24 -nolisten tcp &          # once
S=<scratch dir>; HOME=$S/home XDG_CONFIG_HOME=$S/home/.config DISPLAY=:99 .build/debug/signet-gtk &
DISPLAY=:99 xdotool search --name '^Signet$'               # window id; Return dismisses the disclaimer
DISPLAY=:99 xdotool mousemove X Y click 1; DISPLAY=:99 import -window root shot.png
```

A scratch `HOME` keeps test runs out of the user's real `~/.signet`, `~/.signet_backups` and
`~/.tezos-client`; a watch-only account is one line in `$HOME/.signet/public_key_hashs`
(`[ { "name": "alias", "value": "tz1…" } ]`, mode 600 in a 700 directory).

## Commands

```sh
git submodule update --init                      # after cloning
swift build                                      # the app: .build/debug/signet-gtk
DISPLAY=:1 .build/debug/signet-gtk
swift build --build-tests && swift test --skip-build --no-parallel
swift test --skip-build --filter KeyGeneratorTests                 # one suite
swift test --skip-build --filter 'AddressTests/shortensLongAddresses'
```

Run the whole suite with `--no-parallel`: in parallel, the tests queue more than 64 calls on the
shared bridge and `BridgeCallGate` refuses the rest (`NSURLErrorDomain -1008`), failing random
tests. Single suites are fine either way. Network tests are opt-in as upstream: they need
`SIGNET_NETWORK_TESTS=1`. A crash in the test runner prints no backtrace by default; run
`.build/out/Products/Debug-linux-x86_64/SignetTests-test-runner --testing-library swift-testing`
under the toolchain's `lldb` to get one.

## FreeBSD

Tried on FreeBSD 15.1 (amd64), first with a Swift 6.5-dev CI snapshot unpacked in `~/swift`, now
in a VM on this machine with the `swift6` package (6.4.0, `PATH=/usr/local/swift6/usr/local/bin`;
its `lldb` does not load, the base system's `/usr/bin/lldb` does). The VM is in `~/vm/freebsd`
(not in the repository): `run.sh` boots it headless under QEMU/KVM with SSH on `127.0.0.1:2222`
(`ssh -p 2222 -i ~/vm/freebsd/id_vm -o UserKnownHostsFile=~/vm/freebsd/known_hosts cjep@127.0.0.1`),
the disk an overlay of the 15.1 BASIC-CLOUDINIT image, the user `cjep` (wheel, passwordless sudo)
made by the cloud-init seed `seed.iso`. Copy the working tree in with `tar` over that SSH,
leaving out `.build` and `dist`. Packages: `gtk4 libadwaita webkit2-gtk_60 hidapi webp pkgconf curl`, plus
a font (`dejavu`; with no font at all GTK lays the window out tens of thousands of pixels tall and
draws nothing) and `python3` for two lock tests (run as `/usr/local/bin/python3` there). `swift build` and `swift test` work as on Linux
(the whole suite passed in the VM on 19 November 2026). What differs, each behind `#if`:
- hidapi's pkg-config name is `hidapi` (Linux: `hidapi-hidraw`), chosen in `Package.swift`;
  `CHidapi`'s module map names no library, so pkg-config's flags do the linking.
- Ports install under `/usr/local`: upstream's `PublicHTTPClient` runs `/usr/local/bin/curl`.
- `getnameinfo` takes `size_t` lengths (upstream's `EndpointPolicy`).
- The lock tests' python is `/usr/local/bin/python3`.
- Swift 6.4's libdispatch hands FreeBSD a pipe, not an eventfd, for the main queue: the handle is
  a `uint64_t` with the read end in the high half. `MainLoop` watches that end (declared again
  in `shim.h` as `signet_dispatch_main_queue_pipe_4CF`); 6.5's libdispatch has an eventfd again,
  hence `!compiler(>=6.5)`. Without it no `@MainActor` task ran and the status bar stayed on
  "Checking…".
- FreeBSD 15's headers make `SHUT_RDWR` an enum (`.rawValue`) and Foundation does not export
  `inet_addr`.
- The QR tests need `zbar` installed (it is opened with `dlopen`, so they fail rather than skip).
- `--static-swift-stdlib` needs libexecinfo (`backtrace()`), linked by `Package.swift`.
- Foundation makes a missing `~/.config` with a file's mode (`rw-rw-rw-`, no execute bit), after
  which `UserDefaults` never saves (and other programs lose `~/.config`); `SignetApp.run` makes
  it `0700` first. Foundation also writes the plist itself `rw-rw-rw-`, umask or not; the
  directory's mode is what keeps it private.
The README's FreeBSD section has the steps for users; keep the two in step.
The test machine has no Xvfb, so the app was run on this machine's `:99` through the SSH
connection: `ssh -R 6099:/tmp/.X11-unix/X99 …` and `DISPLAY=127.0.0.1:99 GSK_RENDERER=cairo` there.
(`ssh -X` needs `xauth` on the FreeBSD side.)
Ledger access on FreeBSD (devd rules, `usbhid`) has not been tried.

## Packaging

`packaging/stage.sh DESTDIR [PREFIX]` makes the release build (`--static-swift-stdlib`, so no
package needs a Swift toolchain) and lays out what every format installs:
`PREFIX/lib/signet-gtk/signet-gtk` with `signet-gtk_Signet.bundle` beside it (where
`Bundle.module` looks), `PREFIX/bin/signet-gtk` a relative symlink to it, the desktop entry and
Ledger udev rule from `packaging/linux`, and upstream's 256 px icon. On top of it:
- `packaging/deb/build-deb.sh`: `dpkg-deb` and `dpkg-shlibdeps` (no fakeroot or debhelper).
  `Depends` is `dpkg-shlibdeps`' list for the system building it (Debian and Ubuntu name some
  libraries differently), with GTK raised to 4.18 (its symbols alone say 4.12), plus `curl`
  (upstream's `PublicHTTPClient` runs `/usr/bin/curl`) and `librsvg2-common` (SVG logos). libzbar
  (Scan QR code, opened with `dlopen`) is in `Recommends`, and in the RPM's and Arch's weak
  dependencies.
- `packaging/rpm/build-rpm.sh` with `signet-gtk.spec`: rpmbuild packages the staged tree; rpm finds
  the library dependencies itself. Built on Debian, the RPM did not work on Rocky (nor the
  Arch package or the `.deb` on Ubuntu), so it and `build-arch.sh` refuse to run anywhere but
  their own systems (`/etc/os-release`), for a build farm to make them natively.
  Only the `.deb` and the tarball are released, and the README supports Debian 13 alone.
- `packaging/tarball/build-tarball.sh`: the staged tree with `install.sh` (`/usr/local`, `--user`
  for `~/.local`, or `--prefix`; it writes the launcher with the program's full path and keeps a
  manifest for `uninstall.sh`).
- `packaging/arch/build-arch.sh`: `signet-gtk-bin`, a PKGBUILD over the release tarball (its
  download URL and checksum filled in from `PKGBUILD.in`), built with makepkg from a tarball
  made on Arch; `dist/arch` holds the PKGBUILD and `.SRCINFO` for the AUR.
- `packaging/freebsd/build-pkg.sh`: `pkg create` over the staged tree (`/usr/local`), built in
  the FreeBSD VM against the quarterly branch, into `dist/freebsd-15`. Not a port: the package
  is for Signet's own pkg repository, whose catalogue `pkg repo` makes and the user signs (as
  with apt). Dependencies are the installed packages' names and versions; pkg has no weak ones,
  so zbar is a hard dependency. On FreeBSD `stage.sh` builds with `--build-system native
  -Xswiftc -static-stdlib` in `.build-freebsd`: SwiftPM 6.4's Swift Build spins forever planning
  a `--static-swift-stdlib` build there, and the native build system ignores that option off
  Linux (`isSupportingStaticStdlib`). The native build names the resources
  `signet-gtk_Signet.resources`, and the binary looks for that name. Tried by installing from an
  unsigned local repository into a throwaway VM from the untouched image (`run-clean.sh`).
- `apt/aptrepos.sh`: publishes the `.deb`s in `dist` to the apt repository
  (`s3://apt.signetwallet.org`, from the reprepro tree in `apt/repos`; keys in `apt/keys`). The
  user runs it by hand, since the packages are signed with their GPG key: Claude never runs or
  automates it, and stops at a built `.deb`.

Packages go in `dist/<platform>/`, the platform named by `packaging/distdir.sh` from
`/etc/os-release` as pkg-builder's apt script (`apt/aptrepos.sh`) reads them: `debian-13`,
`ubuntu-2604`, `fedora-45`, `arch` (which also holds the AUR's PKGBUILD). A tarball built
anywhere but Debian 13 is named for its platform (`signet-gtk-<version>-arch-x86_64.tar.xz`, what
`signet-gtk-bin` downloads), so it does not clash with the released Debian one.

`packaging/farm` is the build farm: Docker images (`Dockerfile.deb` for Debian and Ubuntu,
`.rpm` for Fedora, `.arch`) with each system's development packages and Swift from swiftly
(`install-swift.sh`; `SWIFT_VERSION` in `build.sh`, kept the same as the development machine's),
run as a user with the caller's uid. `build.sh [target…]` copies the working tree in, keeps
`.build` in a volume per target, and writes into `dist/<target>`; `smoke.sh [target…]` installs
each package into a clean image of its system and starts it under Xvfb (`dist/smoke/`).
Rocky/RHEL 10 is not a target: it has GTK 4.16 and libadwaita 1.6, older than Signet needs.
The build and smoke test pass on all four (November 2026). What each system needed:
- Swift is swift.org's 6.4.2: Debian's and Ubuntu's own builds, Fedora 41's on Fedora (with
  `libxml2_2.13` for its `libxml2.so.2`), UBI 9's on Arch (with a `libncurses.so.6` symlink).
- Swift Build reads `ld -version_details` and knows Fedora's GNU ld banner only with a release
  after the version, which Fedora 45's lacks; the Fedora image makes gold its `ld`. A failed
  probe is remembered in `.build`: after changing the linker, `docker volume rm` the target's.
- GLib 2.88 (Ubuntu 26.04, Fedora 45, Arch) marks flag enums `G_GNUC_FLAG_ENUM`, which Swift
  imports as an OptionSet without its zero member: write `GFileMonitorFlags(rawValue: 0)`, not
  `G_FILE_MONITOR_NONE`, so Debian's 2.84 builds too.
- `/etc/os-release` sets `VERSION`; scripts read it in a subshell so it does not replace the
  package version. Arch's Docker image gives a `VERSION_ID` (the image date) beside
  `BUILD_ID=rolling`, which `distdir.sh` treats as rolling.
- `build-arch.sh` takes only a pacman version, so an Arch test build needs one:
  `VERSION=0.9.19.r20261118 packaging/farm/build.sh arch` (and the same for `smoke.sh`).
FreeBSD is not in the farm; it is built and tried in the VM (see "FreeBSD").

`packaging/version.sh` gives the version: the tag on HEAD (`v0.8` → `0.8`), else the highest tag
(release tags are on `release`, outside `main`'s history) plus date and commit. A release is tagged on `release`, built, and the files go on the GitHub
release. The app is single-instance per D-Bus session, so to try a packaged build beside a
running Signet use `dbus-run-session -- …/bin/signet-gtk`. The submodule URL is HTTPS so a
`git clone --recursive` works without an SSH key.

## Layout and how upstream is reused

`upstream/` is the Mac repository as a git submodule. `Package.swift` compiles its
`Signet/Models`, `Signet/Services` and `Signet/ViewModels` **as they are**, together with
`Sources/SignetGTK`, into one executable module named `Signet` (as on the Mac, where views and
app share the module; upstream's types are `internal`, so they must). The product is
`signet-gtk`. Upstream's `SignetTests` compile unchanged against it as the `SignetTests` target
(`@testable import Signet`). The port's own tests are `Tests/SignetGTKTests` (target
`SignetGTKTests`), mainly its copies of upstream policy checked against the pinned upstream.

- Upstream reaches its C hashing (`tzel_blake2s.c`) through Xcode's bridging header; here
  `Sources/CTzel` compiles it and the same header is passed with `-import-objc-header`.
- `macOnly` in `Package.swift` lists the upstream files that need macOS frameworks.
  `Sources/SignetGTK/Platform` replaces the ones the rest of the module needs:
  - `TaquitoBridge.swift`: follows upstream's file section by section. Differences: JavaScriptCore's
    GLib API (wrapped in `JavaScriptCore.swift` with the Mac's `JSContext`/`JSValue` names), a
    `ThreadQueue` (one dedicated thread; JSC's GLib objects must stay on the thread that made
    them) instead of a `DispatchQueue`, natives as `JSValue(function:in:)` closures instead of
    `@convention(block)`, one fetch session whose delegate routes events per task, and the log
    at `$XDG_STATE_HOME/signet/bridge.log`. Unlike the Mac, an exception thrown synchronously by
    a call is also kept in `context.exception`, so it fails the call instead of only being logged.
    The console script, `redactedLine` and `signingCalls` are upstream's text exactly (the audit
    of 5 November 2026 found the list had drifted and NFT Transfer and Burn were refused);
    `SignetGTKTests` compares `signingCalls` with the pinned file.
  - `LedgerHID+hidapi.swift`: hidapi in place of IOKit (the name avoids clashing with upstream's
    `LedgerHID.swift`, which still supplies `LedgerFraming` and `LedgerDevice`). Device ids are
    hidapi paths. Linux needs Ledger's udev rule (`20-hw1.rules`) for non-root access.
  - `ImageLoader.swift` and `ArtworkCache.swift`: upstream's, with `PlatformImage` (a
    GdkTexture, decoded and downsampled by gdk-pixbuf, WebP by libwebp since TzKT's avatars are
    WebP and gdk-pixbuf rarely has a WebP loader) in place of `NSImage`; the cache is
    `$XDG_CACHE_HOME/signet/artwork`. `Views/RemoteImage.swift` draws one.
  - `QRCode.swift`: a QR encoder in Swift (byte mode, all versions and levels) in place of Core
    Image, checked module for module against libqrencode. Its image is a `PlatformImage`.
  - `QRScanner.swift`: upstream's `QRScanner.swift` (Scan QR code) with libzbar in place of
    AVFoundation and Vision, opened with `dlopen` (`ZBar`) so Signet starts without it; it also
    gives `QRCode.decode`/`decodeAll`. Cameras are the `/dev/video*` nodes whose VIDIOC_QUERYCAP
    says they capture; `CameraWatcher` watches `/dev`; `QRCaptureSession` runs zbar's own V4L2
    video module on a thread, scanning each frame and offering frames for the preview.
    `QRCamera.textsFromClipboard` reads GTK's clipboard (asynchronously, unlike NSPasteboard).
    `hasCamera` is false without zbar, so the Scan QR code items stay hidden. The camera path
    has not been run here: this machine has no camera (see "Trying Scan QR code" below).
  - `RemoteSignerSocket.swift`: `FramedConnection` over POSIX sockets (non-blocking, `poll` a
    quarter second at a time so `close` and cancellation stop it) for upstream's
    `RemoteSignerClient.swift`, whose own is Network.framework's; upstream builds it under
    `#if canImport(Network)`'s `#else`. Its HTTP path uses one long-lived `URLSession` off the Mac.
  - AirGap Vault signing: upstream's `AirGapSigning` and `AirGapSignSession` are compiled; the
    panel is `Views/AirGapSignView.swift` (`presentPanel`/`closePanel`, which upstream's
    `#else` calls), a `Sheet` stacked over whatever the window shows, found through
    `SignetApp.current`. Closing it any other way than with the Vault's reply cancels.
  - `CZlib` (a module map linking `z`, no pkg-config: zlib is in FreeBSD's base system) for the
    gzip around AirGap's codes, which upstream's `Gzip` does with Compression on the Mac and
    with zlib under `#elseif canImport(CZlib)`.
  - Not replaced: `UpdaterService` (Sparkle; Signet is updated by whatever installed it).
- `Sources/SignetGTK/GTK` is a thin Swift layer over GTK's C API (no binding library):
  - `MainLoop`: GLib drains libdispatch's main queue (`_dispatch_get_main_queue_handle_4CF`), so
    `@MainActor` code and `Task { @MainActor … }` run inside GTK's loop. Everything UI is on the
    main thread; C callbacks enter the main actor with `MainActor.assumeIsolated`.
  - `Widget` (typed handle: `.as()` for a typed GTK pointer, `.opaque` for an opaque one), `UI`
    builders, `Signals.connect` for closures, `Actions` (window actions, `win.<name>`, plain or
    radio choices) and `MenuBuilder` (sections, items, radio items). `Signals.connect` connects
    swapped (user data first), so one closure type fits any signal's arguments.
  - GTK4 propagates `hexpand`/`vexpand` up to every parent that has not set its own: a centred
    icon with `expand(v: true)` stretches the rows around it. `UI.circle` and `UI.hspacer` set
    their expansion explicitly; do the same in new containers.
  - `Tracker` is the stand-in for SwiftUI re-rendering: it runs a closure under
    `withObservationTracking` and runs it again whenever anything `@Observable` it read changes.
    A view's Swift object owns its trackers and is kept alive by its root widget
    (`Widget.retain`). Rebuild only the part that changes (`setChildren`), not whole views.
  - A widget taken out of its box loses its last reference and is freed. `setChildren`,
    `Form.setRows` and `Form.append` hold a reference while they move a widget, so a widget kept
    in a property can be put back after a rebuild; anything else that re-parents must do the same.
  A widget kept in a property that a rebuild leaves out (a row shown only while a switch is on)
  is freed all the same, and putting it back later uses a dead widget: `g_object_ref_sink` it
  when made and unref it in the sheet's `isolated deinit` (`NetworksSheet.l2NodeRow`).
  - `Sheet` is SwiftUI's `.sheet`: an `AdwDialog` (sized to its content as it changes, scrolling
    when taller than the window, narrowed to fit a narrow window) with upstream's layout: title,
    content, red error line, a status line with spinner (`setBusy`), and the buttons
    (`button(_:role:isDefault:)`, `cancelButton()`). `closed()` is where a sheet wipes passwords
    and keys from its fields. `Form` is `Form { }.formStyle(.grouped)`: a boxed list of
    libadwaita rows (`entry`, `password`, `toggle`, `picker`, `labeled`, `stacked` for a value
    with controls beneath, `note` for the text upstream puts inside forms).
- `Sources/SignetGTK/Views` holds the GTK views, one class per upstream SwiftUI view with the same
  name and file name (`Views/WalletHomeView.swift`), each with a `root` widget (a sheet is a
  `Sheet` subclass). Wording is upstream's. Static helpers upstream's tests call (such as
  `SendSheet.capture`) keep their names and signatures. `Operations` in `WalletHeaderView.swift`
  is upstream's `OperationsMenuItems`: the burger menu, its window actions and shortcuts, and the
  list of sheets with their `isPresenting…` flags. `WalletHomeView.makeSheet` builds the sheet
  for a flag; a flag with no sheet there shows a toast ("… is not available on Linux yet.") and
  is lowered. The dApp request sheet follows `model.dapps.current`; Settings has no model flag
  and is opened through `Operations.presentSettings`.
- `Sources/SignetGTK/App`: `SignetApp` (upstream's `makeModel`, the `AdwApplication`, unique per
  session over D-Bus like `LSMultipleInstancesProhibited`), `Style` (the CSS for looks
  libadwaita has no class for, using its named colours so dark mode follows).

Done so far: the window, the welcome screen, the launch disclaimer, the dashboard
(`WalletIdentityView`, `NetworkBadgeMenu`, `AppMenuButton`, `ActionButtonsView`, `AssetListView`,
`DelegateRowView`, `AccountNotOnChainView`, `ActivityTabsView` with `LayerToggles`), every layer 1
sheet (Create, Import, Connect Ledger, Rename, Export secret key, Proof of possession, Add
address, Remember key, Forget, Send, Receive, Staking, Baking, Governance, Faucet, Buy with its
in-app `BuyWebView`, Networks, Settings, the four multisig sheets, Connect to a dApp and the dApp
request sheet), Etherlink (`ChainSidePicker` and the Etherlink side of Send and Receive with the
alias link, the Receive side switched off with upstream's `EtherlinkAlias.isOffered` since 0.9.16
because Etherlink 8.0 changes the alias derivation, `BridgeSheet`, the Layer 2 rows of Networks with `SettingField`, the Etherlink tab of
Governance, `EtherlinkGovernanceView`), and the NFT operations of 0.9.13 (selection and the
right-click `NFTContextMenu` in `NFTGridView`, `TransferNFTSheet`, `DownloadNFTsSheet`), and
shielded transactions (TzEL: `ShieldSettingsSheet`, `ShieldedAddressSheet` with the address
book, `ShieldSheet`, `UnshieldSheet`, `SendShieldedSheet`; the pieces they share, the two sides
and the hash line, are statics on `ShieldSheet`, and a pasted address goes into a
`ShieldedJSONEditor`), 0.9.17's Scan QR code, recovery sheet and Settings' "Arrange NFTs by
address", and 0.9.18's Shadownet (Previewnet): the badge, Networks and Shielded settings list
`model.offeredNetworks` (`NetworksSheet.networkPicker` keeps the two sheets' pickers in step with
it), and the Layer 2 is named by `network.l2Name` in the layer toggles, Bridge and Send, and
0.9.19's remote signers (`ConnectRemoteSignerSheet`, also on the welcome screen), AirGap Vault
accounts (`AddAirGapAccountSheet` after a Pair Account code in Scan QR code, animated codes
gathered with progress) and their signing panel, the Domains tab (`DomainListView`, Mainnet only,
`model.activityTabs`) and "Activity" for "Recent transactions", the account tags on the address
line (AirGap, Remote signer), Etherlink voting keys (the "Voting rights contract" field in
Networks; Governance shows only the Etherlink tab to a voting key that is not a baker), and the
Help menu's Getting Started and Signet Website as the burger menu's last section. Send, Staking (delegate), Faucet, Import, Create, the multisig sheets,
the Bridge deposit, the Etherlink alias link, Send on Etherlink and a dApp on Shadownet's Layer 2
(`tezosx-shadownet`: refused with Layer 2 off, then paired and an operation approved) have been
run against Shadownet; NFT Transfer/Burn and Etherlink governance have only been looked at, not run with
real tez (NFT Download and the Buy widget have been run). The shielded sheets have been run
against Shadownet's TzEL deployment as far as it goes without the operator's access token
(settings, the token on file, a shielded address and the address book, the shield's rollup
checks, pool and estimate, the unshield and transfer estimates); a shield, unshield or private
transfer needs the token and has not been run here. Remote signers have been run against a
local octez-signer 25.3 (the sheet: List Keys, the check, Add; and upstream's
`RemoteSignerLiveTests`, a tz1 and a tz4 key over TCP and HTTP signing through the bridge); the
AirGap panel has only been looked at (no camera or Vault here), not signed with.
- NFT tiles select with click, Ctrl-click and Shift-click (`UI.onClick(_:modifiers:)`), and a
  right-click menu whose entries depend on that state is `UI.contextMenu(_:build:)`, rebuilt
  each time it opens (`UI.MenuEntry`: items, a dimmed line of explanation, dividers).
- WebKit takes the thread it is first set up on for its main thread, and the bridge runs
  JavaScriptCore on a thread of its own: `SignetApp`'s `startup` makes WebKit's default context
  before the bridge exists. Without it the Buy sheet's web view aborts the app (or, with only a
  bare `JSContext` made first, never loads). It once made and dropped a web view instead, which
  crashed FreeBSD's WebKitGTK at launch about one time in four. WebKitGTK says which frame a navigation is for only
  at its response, so `BuyWebView` applies upstream's main-frame rule there
  (`is_main_frame_main_resource`); its policy functions keep upstream's names and signatures,
  with a `WKNavigationType` of its own, so `BuyWebViewTests` run here.
- `macOnlyTests` in `Package.swift` lists upstream test files left out because they exercise
  Mac-only code; each returns once the GTK version of what it tests exists.
- Scan QR code (0.9.17): `ScanQRSheet`, opened from the burger menu after Connect Ledger and
  the welcome screen's "Import from QR code" while `model.hasCamera`. Its `onDismiss` is in
  `WalletHomeView.presentSheets` (`routePendingScan`; Send's clears `sendPrefill`); Import
  account, Add address and Send take their prefills as upstream. The Recovery Sheet
  (`Views/RecoverySheet.swift`: upstream's model, then `RecoverySheetPainter` drawing each page
  with cairo and Pango, QR codes as vectors) prints through `GtkPrintOperation`;
  `RecoverySheetPrinter.pdfData` draws the same pages into a PDF 1.4 in memory for the tests
  (`SignetGTKTests/RecoverySheetPrintTests`, which also scan the printed codes back).
  Upstream's `QRScanTests` and `RecoverySheetTests` run here, less the NSPasteboard and PDFKit
  tests (behind `#if canImport` on `claude@portable`).
- Trying a remote signer: `octez-signer -d DIR gen keys alice` (`--sig bls` for tz4), then
  `octez-signer -d DIR launch socket signer -a 127.0.0.1 -p 17732 --allow-list-known-keys` (or
  `launch http signer … -p 16732`); `SIGNET_REMOTE_SIGNERS=tcp://127.0.0.1:17732/tz1…,…` runs
  `RemoteSignerLiveTests`. `SignetGTKTests/RemoteSignerSocketTests` use a pretend signer instead.
- Getting Started (`Views/GettingStartedView.swift`): a window of its own with a WebKitGTK view,
  JavaScript off, showing `manuscript/110-starting.md` rendered by upstream's `Markua` with its
  pictures; both are copied as resources and read from `Bundle.module`. Upstream's bundle test
  reads `Bundle.main` and is behind `#if canImport(AppKit)`; `GettingStartedBundleTests` checks
  the port's bundle.
- Trying Scan QR code without a camera: make `CameraWatcher`'s report `true` for the run (do not
  commit it), then use Choose Image… (with no window manager on `:99`, click into the file
  chooser before typing a path). `magick -density 100 sheet.pdf[1] page.png` turns a recovery
  sheet into an image to scan.

## Changing upstream

Portability fixes go into upstream itself, never into a copy: in the submodule, on a
`claude@portable` branch (or another `claude@…` branch) of the Mac repository, for the user to
merge there. Every such change sits behind `#if canImport(…)`, `#if os(Linux)` or
`#if SWIFT_PACKAGE` so the Mac compiles exactly the code it compiled before; it can't be built
here, so keep the Mac side of each `#if` byte-for-byte as it was. The Xcode project is generated
and committed upstream, so adding a file there means running XcodeGen on the Mac: guard code
inside an existing file instead.

Linux Foundation (swift-corelibs-foundation) traps already handled upstream, which new code must
avoid too:
- A task's own `delegate` is never called; use a session delegate (`BoundedHTTP.Router`).
- Short-lived `URLSession`s crash when freed (`_MultiHandle deallocated with non-zero retain
  count`); keep sessions long-lived.
- A `.cancel` response disposition does not stop the transfer; cancel the task as well.
- `NSNumber.decimalValue` is inexact even for integers; use `exactDecimal`. Booleans are told
  apart with `isJSONBoolean`. `JSONDecoder` decodes `Decimal` exactly.
- `Bundle.main` holds no resources in a SwiftPM build; use `Bundle.module` under `SWIFT_PACKAGE`
  and list the file in `resources:` in `Package.swift`.

- `FileManager.homeDirectoryForCurrentUser` ignores `$HOME`; upstream uses
  `FileManager.default.userHome`, which honours an absolute `$HOME` off the Mac.
- `UserDefaults.standard` is `$XDG_CONFIG_HOME/signet-gtk.plist` (`~/.config` by default).

## Differences from the Mac app

- Wording that names the Mac: "Welcome to Signet, a Tezos Wallet." (upstream adds "for the
  Mac"), "Generate a fresh key on this computer" ("on this Mac").
- No menu bar: the burger menu holds the Operations items, with Ctrl in place of Cmd
  (Ctrl+N, Ctrl+Shift+I/L/N/D, Ctrl+R, Ctrl+comma); Ctrl+Q quits. The window has a libadwaita
  header bar for its title and controls.
- The app forces the Adwaita icon theme: libadwaita's look assumes its symbolic icons, and other
  desktops' themes (XFCE's) fall back to coloured ones. GTK icon names stand in for SF Symbols.
- Wording that names the Mac elsewhere says "this computer" (Forget account, Remember key).
- Settings is a sheet over the window rather than a window of its own, and has no Updates
  section (Signet is updated by whatever installed it, not Sparkle). "Show in Finder" is "Open
  Folder", which opens the folder in the file manager.
- Buy shows a widget provider (Mt Pelerin) in a WebKitGTK web view, as the Mac does in a
  WKWebView. A permission request carries no frame there, so camera and microphone go by the
  page the main frame shows (WebKit itself keeps them from frames not delegated them).
- Shielded settings' explanation of the TzEL services leaves out upstream's sentence that macOS
  lets plain http through only for the hosts Signet ships with: Linux has no App Transport
  Security, so any http service works.
- Scan QR code says "this computer's own screen" for "this Mac's own screen". Where macOS asks
  for camera permission, Linux opens the device node or fails; the sheet then says the user
  needs access to it (the video group) instead of offering Privacy Settings. Linux has no
  preferred camera, so the first one is chosen.
- The recovery sheet's "Printed … by Signet <version>" has no version: like upstream it reads
  `CFBundleShortVersionString`, which a SwiftPM build lacks. It is laid out at the size the
  print dialog's paper gives, and its title shrinks to stay on one line in fonts wider than
  the Mac's.
- The Help menu's Getting Started and Signet Website are the burger menu's last section, and
  Getting Started is a window of the app rather than a SwiftUI `Window` scene.
- Connect Remote Signer says plain HTTP is for a signer "on this computer" ("on this Mac"), and
  the AirGap sheets say "this computer's camera". Where macOS asks for camera permission, the
  AirGap panel opens the device node or says why not. Upstream's App Transport Security note on
  a refused plain-HTTP signer never appears: Linux has none.
- NFT Download's "Show in Finder" is "Open Folder" (the file manager, with the first saved file
  selected where it can); Ctrl-click stands in for Cmd-click when selecting tiles.
- `signet://` pairing links: the desktop entry declares `x-scheme-handler/signet` (`Exec=signet-gtk %u`)
  and the app is `G_APPLICATION_HANDLES_OPEN`; its `open` signal hands each URI to upstream's
  `handleIncomingURL`, and a second launch passes the link to the running Signet over D-Bus.
  To try pairing without a real dApp, a page loading `@tezos-x/octez.connect-sdk`'s
  `octez.connect.min.js` in headless Chrome can create a `DAppClient` and take the code from its
  `PAIR_INIT` event (`p2pPeerInfo`), then `requestPermissions()`.
- Preferences are written at once (`UserDefaults.synchronize()`): swift-corelibs-foundation only
  flushes them at a clean exit otherwise.
- The window's content scrolls as a whole; the activity lists grow inside it rather than
  scrolling on their own.
- `AssetListView`'s tez, Etherlink and Shielded images are the SVG/PNG files from upstream's
  asset catalogue, copied as resources. The baker's 👨‍🍳 needs a colour emoji font (Noto Color
  Emoji); without one GTK draws a missing-glyph box.

## Sibling repositories

- `../signet`: the Mac app (origin `drchrispinnock/signet`), source of truth; `upstream/` is the
  same repository. Before porting or changing a feature, read `upstream/CLAUDE.md` (detailed
  architecture), `upstream/docs/spec/SPEC.md` and `upstream/docs/spec/EXAMPLE.png`. Behaviour,
  wording, file formats and edge cases should match the Mac app unless Linux forces a
  difference. When it does, note the difference here. Work on upstream in the submodule, not in
  `../signet`, which is the user's own checkout.
- `../signet-windows`: the Windows port (C# / WinUI 3). Its `CLAUDE.md` has a useful table of
  platform substitutions and porting notes; its approach (translate and mirror) differs from
  this one (compile upstream's Swift directly).

## Branches

Same scheme as upstream (`upstream/BRANCHES.md`). `main` is the raw development line and
`release` is the current release line. Nothing is developed directly on either. Work happens on
a feature branch named `<user>@<feature>`, cut from `main`, where user is `chrispinnock`, `claude`
or `codex` and feature is one word or a short phrase (`claude@send-sheet`). When the feature is
thought done it is merged up into `main`; when `main` is ready to ship it is merged up into
`release`, and the version tag goes on `release`. So Claude begins a piece of work by creating or
checking out its `claude@…` branch and commits there; merging into `main` or `release`, pushing
and tagging happen only when asked.

## Constraints inherited from upstream

- **Wallet files must stay byte-compatible with octez-client.** Upstream keeps keys in `~/.signet`
  in octez-client's layout (`public_key_hashs`, `public_keys`, `secret_keys`), written by joining
  entries on alias, only ever appending, replacing files atomically and holding `wallet_lock`
  while writing. It also reads `~/.tezos-client` and backups go in `~/.signet_backups`. Since
  `TezosClientStore` and `WalletStore` are upstream's own code compiled here, this holds as long
  as upstream's code is not forked.
- **The Taquito bridge is shared, never forked.** All chain access, signing, Ledger APDUs, Octez
  Connect and key encryption run in upstream's JavaScript bundle
  (`upstream/Signet/Resources/taquito-bridge.js`, built from `TaquitoBridge/src`; since 0.9.16 on
  octez.js and Octez Connect 5 rather than Taquito, though the names stay), embedded
  unchanged. If the bridge needs a change, make it upstream.
- User-facing text says "account" for a `Wallet`; "wallet" means the whole key directory and the app.
