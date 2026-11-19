#!/bin/sh
# The directory under dist/ for packages built on this system, named as pkg-builder's apt
# script names platforms (it reads dist/<platform>/*.deb): ID-VERSION_ID from /etc/os-release
# without dots (debian-13, ubuntu-2604, fedora-45), or ID alone for a rolling release (arch).
# FreeBSD is named by its major version alone (freebsd-15), as pkg's ABI (FreeBSD:15:amd64) is.
set -eu
. /etc/os-release
# Arch's Docker image gives the image's date as VERSION_ID beside BUILD_ID=rolling.
if [ "$ID" = freebsd ]; then
    echo "$ID-${VERSION_ID%%.*}"
elif [ -z "${VERSION_ID:-}" ] || [ "${BUILD_ID:-}" = rolling ]; then
    echo "$ID"
else
    echo "$ID-$(echo "$VERSION_ID" | tr -d .)"
fi
