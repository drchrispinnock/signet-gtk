#!/bin/sh
# The version packages carry: this repository's tag when HEAD is tagged (v0.8 → 0.8), else the
# last tag plus the commit date and hash (0.8+git20261102.1a2b3c4), so a test build sorts after
# the release it follows.
set -eu
cd "$(dirname "$0")/.."
if tag=$(git describe --tags --exact-match --match 'v[0-9]*' 2>/dev/null); then
    echo "${tag#v}"
else
    last=$(git describe --tags --abbrev=0 --match 'v[0-9]*' 2>/dev/null || echo v0.0)
    echo "${last#v}+git$(git log -1 --format=%cd --date=format:%Y%m%d).$(git rev-parse --short HEAD)"
fi
