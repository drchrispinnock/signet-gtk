# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A Linux port of **Signet**, the macOS Tezos wallet written in SwiftUI. The repository holds only
`README.md` and `LICENSE` (MIT) so far. Update this file with the commands and layout once they exist.

Stack: Swift 6 on Linux (installed with swiftly), GTK4 + libadwaita for the UI, swift-crypto in
place of CryptoKit, and the Linux JavaScriptCore (`javascriptcoregtk-6.0`, the same engine as the
Mac) for the Taquito bridge. Swift was chosen so upstream's Models, Services and ViewModels can be
reused with as few changes as possible; only the views and the platform glue are rewritten.
Development headers come from Debian 13 packages (`libgtk-4-dev`, `libadwaita-1-dev`,
`libjavascriptcoregtk-6.0-dev`, `libhidapi-dev`, `pkg-config`).

The development machine is reached over SSH. Its desktop is XFCE on a TigerVNC X server at
`DISPLAY=:1` (1920x1080), so GUI runs and screenshots use that display.

## Sibling repositories

- `../signet`: the Mac app (origin `drchrispinnock/signet`). It is the source of truth and keeps
  evolving, so this port follows it. Before porting or changing a feature, read `../signet/CLAUDE.md`
  (detailed architecture), `../signet/docs/spec/SPEC.md` and `../signet/docs/spec/EXAMPLE.png`.
  Behaviour, wording, file formats and edge cases should match the Mac app unless Linux forces a
  difference. When it does, note the difference here.
- `../signet-windows`: the Windows port (C# / WinUI 3), which is further along. Its `CLAUDE.md`
  sets out the porting approach used so far: upstream pulled in as a git submodule `upstream/`
  whose pin marks the last ported Mac commit, names mirrored one-to-one with the Swift sources so
  the two codebases stay diffable, upstream tests ported under the same names with skipped stubs
  as the backlog, and a table of platform substitutions. Follow the same approach here unless
  there is a reason not to.

## Branches

Same scheme as upstream (`../signet/BRANCHES.md`). `main` is the raw development line and
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
  while writing. It also reads `~/.tezos-client` and backups go in `~/.signet_backups`.
- **The Taquito bridge is shared, never forked.** All chain access, signing, Ledger APDUs, Octez
  Connect and key encryption run in upstream's JavaScript bundle
  (`Signet/Resources/taquito-bridge.js`, built from `TaquitoBridge/src`). A port embeds that bundle
  unchanged and provides the native contract that `Signet/Services/TaquitoBridge.swift` installs
  as `globalThis.__signet` (timers, `randomBytes`, `fetch`, Ledger HID exchange, storage,
  `octezConnectEvent`) on a single engine thread. If the bridge needs a change, make it upstream.
- User-facing text says "account" for a `Wallet`; "wallet" means the whole key directory and the app.
