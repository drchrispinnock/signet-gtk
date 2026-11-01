# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

**signet-gtk**: a port of **Signet**, the macOS Tezos wallet written in SwiftUI, to Linux first and
then the BSDs. Linux is the primary target. FreeBSD should follow, since Swift has a FreeBSD port
and preview toolchain. NetBSD and OpenBSD are aims rather than promises: Swift is barely available
there (OpenBSD has no libdispatch, so no async/await). Keep code portable anyway: hidapi for
Ledger rather than Linux hidraw, POSIX `lockf` for `wallet_lock`, and no Linux-only paths or
syscalls outside `Sources/SignetGTK/Platform`.

Stack: Swift 6 (installed with swiftly, `~/.local/share/swiftly/bin`), GTK4 + libadwaita for the
UI, swift-crypto in place of CryptoKit, and the Linux JavaScriptCore (`javascriptcoregtk-6.0`, the
same engine as the Mac) for the Taquito bridge. Development headers come from Debian 13 packages
(`libgtk-4-dev`, `libadwaita-1-dev`, `libjavascriptcoregtk-6.0-dev`, `libhidapi-dev`, `libwebp-dev`,
`pkg-config`).

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

## Layout and how upstream is reused

`upstream/` is the Mac repository as a git submodule. `Package.swift` compiles its
`Signet/Models`, `Signet/Services` and `Signet/ViewModels` **as they are**, together with
`Sources/SignetGTK`, into one executable module named `Signet` (as on the Mac, where views and
app share the module; upstream's types are `internal`, so they must). The product is
`signet-gtk`. Upstream's `SignetTests` compile unchanged against it as the `SignetTests` target
(`@testable import Signet`).

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
  - `LedgerHID+hidapi.swift`: hidapi in place of IOKit (the name avoids clashing with upstream's
    `LedgerHID.swift`, which still supplies `LedgerFraming` and `LedgerDevice`). Device ids are
    hidapi paths. Linux needs Ledger's udev rule (`20-hw1.rules`) for non-root access.
  - `ImageLoader.swift` and `ArtworkCache.swift`: upstream's, with `PlatformImage` (a
    GdkTexture, decoded and downsampled by gdk-pixbuf, WebP by libwebp since TzKT's avatars are
    WebP and gdk-pixbuf rarely has a WebP loader) in place of `NSImage`; the cache is
    `$XDG_CACHE_HOME/signet/artwork`. `Views/RemoteImage.swift` draws one.
  - `QRCode.swift`: a QR encoder in Swift (byte mode, all versions and levels) in place of Core
    Image, checked module for module against libqrencode. Its image is a `PlatformImage`.
  - Not yet replaced: `UpdaterService`.
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
- `Sources/SignetGTK/Views` holds the GTK views, one class per upstream SwiftUI view with the same
  name and file name (`Views/WalletHomeView.swift`), each with a `root` widget. Wording is
  upstream's. Static helpers upstream's tests call (such as `SendSheet.capture`) keep their names
  and signatures. `Operations` in `WalletHeaderView.swift` is upstream's `OperationsMenuItems`:
  the burger menu, its window actions and shortcuts, and the list of sheets with their
  `isPresenting…` flags. A sheet not ported yet shows a toast ("… is not available on Linux yet.")
  and lowers its flag; port a sheet by presenting it there instead.
- `Sources/SignetGTK/App`: `SignetApp` (upstream's `makeModel`, the `AdwApplication`, unique per
  session over D-Bus like `LSMultipleInstancesProhibited`), `Style` (the CSS for looks
  libadwaita has no class for, using its named colours so dark mode follows).

Done so far: the window (`WalletHomeView` with the error line and `NodeStatusBar`), the welcome
screen (`NoWalletsView`), the launch disclaimer, appearance, and the dashboard down to the
activity: header (`WalletIdentityView`, `NetworkBadgeMenu`, `AppMenuButton`), `ActionButtonsView`,
`AssetListView`, `DelegateRowView`, `AccountNotOnChainView` and `ActivityTabsView` (without
the Etherlink `LayerToggles`).
- `macOnlyTests` in `Package.swift` lists upstream test files left out because they exercise
  Mac-only code; each returns once the GTK version of what it tests exists.

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

Known test difference: `nativeReadersUseTheBoundedPath` fails because a `URLProtocol` registered
globally does not reach the companion session made from `.shared`'s configuration. Only the
test's mock is affected, not real requests.

## Differences from the Mac app

- Wording that names the Mac: "Welcome to Signet, a Tezos Wallet." (upstream adds "for the
  Mac"), "Generate a fresh key on this computer" ("on this Mac").
- No menu bar: the burger menu holds the Operations items, with Ctrl in place of Cmd
  (Ctrl+N, Ctrl+Shift+I/L/N/D, Ctrl+R, Ctrl+comma); Ctrl+Q quits. The window has a libadwaita
  header bar for its title and controls.
- The app forces the Adwaita icon theme: libadwaita's look assumes its symbolic icons, and other
  desktops' themes (XFCE's) fall back to coloured ones. GTK icon names stand in for SF Symbols.
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
  (`upstream/Signet/Resources/taquito-bridge.js`, built from `TaquitoBridge/src`), embedded
  unchanged. If the bridge needs a change, make it upstream.
- User-facing text says "account" for a `Wallet`; "wallet" means the whole key directory and the app.
