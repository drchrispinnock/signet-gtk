#!/bin/sh
# Installs swiftly and the Swift toolchain SWIFT_VERSION for the user running it, as on the
# development machine (~/.local/share/swiftly). SWIFTLY_PLATFORM names the swift.org build to
# use where swiftly does not know the system (Fedora newer than swift.org's, Arch).
set -eu
cd "$(mktemp -d)"
curl -fsSLO "https://download.swift.org/swiftly/linux/swiftly-$(uname -m).tar.gz"
tar zxf "swiftly-$(uname -m).tar.gz"
./swiftly init --quiet-shell-followup --assume-yes --skip-install --no-modify-profile \
    ${SWIFTLY_PLATFORM:+--platform "$SWIFTLY_PLATFORM"}
# env.sh needs bash; this is all it sets that matters here.
PATH="$HOME/.local/share/swiftly/bin:$PATH"
swiftly install "${SWIFT_VERSION:?}" --use --assume-yes --post-install-file post-install.sh
# What swiftly would have installed with the system's package manager: the Dockerfile should.
[ ! -s post-install.sh ] || { echo "swiftly wants system packages:" >&2; cat post-install.sh >&2; }
swift --version
rm -rf "$PWD"
