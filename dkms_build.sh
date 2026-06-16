#!/bin/bash
# dkms_build.sh — DKMS PRE_BUILD helper. Builds all three MacBook8,1 modules
# for kernel $1 into the build/ tree, in BUILD_ONLY mode so DKMS performs the
# install (modules land once under updates/dkms, not double-copied to updates/).
#
# Order matters: install.cirrus.driver.sh downloads + extracts the kernel hda
# source tree (and wipes build/hda) that the generic and azx builds reuse.
set -eu

kver="${1:-$(uname -r)}"
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$here"

export BUILD_ONLY=1

echo "=== dkms_build: cs420x (codec) for $kver ==="
bash install.cirrus.driver.sh -k "$kver"

echo "=== dkms_build: generic (codec, CS4208 clock-latch skip) for $kver ==="
bash install.generic.driver.sh -k "$kver"

echo "=== dkms_build: snd-hda-intel (no-reset attach) for $kver ==="
bash install.azx.driver.sh -k "$kver"

echo "=== dkms_build: all three modules built ==="
