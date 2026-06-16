#!/bin/bash
#
# install.azx.driver.sh — build & install a patched snd-hda-intel.ko that
# attaches to the MacBook8,1 PCH HD-audio controller (8086:9ca0 / ssid
# 8086:7270) WITHOUT a link reset at probe, so EFI's codec clock init
# (vendor coef 0x1f == 0) survives instead of being latched into a clock
# fault (coef 0x1f -> 0x400) that only an unowned power-cycle can clear.
#
# Pairs with the cs420x EFI-coef-image patch (install.cirrus.driver.sh).
#
# Run as root:  sudo bash install.azx.driver.sh
# Remove with:  sudo bash install.azx.driver.sh -r   (deletes the updates/ copy)
#
set -eu

action='install'
uname_r=$(uname -r)
while [[ $# -gt 0 ]]; do
    case "$1" in
        -r|--remove) action='remove';;
        -k|--kernel) uname_r="$2"; [[ -z "$uname_r" ]] && { echo "-k needs a kernel version"; exit 1; }; shift;;
        *) echo "unrecognized option: $1"; exit 1;;
    esac
    shift
done

kernel_version=$(echo "$uname_r" | cut -d '-' -f1 | cut -d '_' -f1)
major_version=$(echo "$kernel_version" | cut -d '.' -f1)
HERE="$(cd "$(dirname "$0")" && pwd)"
build_dir="$HERE/build"
hda_dir="$build_dir/hda"
ctrl_dir="$hda_dir/controllers"
update_dir="/lib/modules/$uname_r/updates"

if [[ $action == 'remove' ]]; then
    rm -f "$update_dir/snd-hda-intel.ko" "$update_dir/snd-hda-intel.ko.zst" 2>/dev/null || true
    depmod -a
    echo "removed patched snd-hda-intel from $update_dir; depmod done."
    echo "the in-tree snd-hda-intel will be used again on next modprobe."
    exit 0
fi

[[ $EUID -ne 0 ]] && { echo "must be root: sudo bash $0"; exit 1; }

# 1. Ensure the kernel hda source tree is extracted (reuse if present).
if [[ ! -f "$ctrl_dir/intel.c" ]]; then
    echo "=== extracting sound/hda from kernel tarball ==="
    tarball=$(ls "$build_dir"/linux-*.tar.xz 2>/dev/null | head -1)
    if [[ -z "$tarball" ]]; then
        echo "no kernel tarball in $build_dir — run install.cirrus.driver.sh first" >&2
        exit 1
    fi
    src_ver=$(basename "$tarball" .tar.xz | sed 's/^linux-//')
    tar --strip-components=2 -xf "$tarball" --directory="$build_dir/" \
        "linux-$src_ver/sound/hda"
fi

# 2. Apply the no-reset gate to controllers/intel.c (idempotent).
echo "=== patching controllers/intel.c (no-reset gate) ==="
python3 - "$ctrl_dir/intel.c" <<'PYEOF'
import sys
p = sys.argv[1]
s = open(p).read()
marker = "MacBook8,1: attaching to running EFI link"
if marker in s:
    print("    already patched, skipping")
    sys.exit(0)
old = "\thda_intel_init_chip(chip, (probe_only[dev] & 2) == 0);"
if old not in s:
    sys.exit("    ERROR: anchor line not found in intel.c — kernel layout changed")
new = (
    "\t/*\n"
    "\t * MacBook8,1 quirk: PCH HD-audio controller 8086:9ca0, ssid 8086:7270,\n"
    "\t * hosting the CS4208 + class-D speaker amp. EFI leaves the codec in a\n"
    "\t * clock-locked state (vendor coef 0x1f == 0); the link reset (CRST)\n"
    "\t * normally pulsed at probe wipes it and latches a codec clock fault\n"
    "\t * (coef 0x1f -> 0x400) that no register replay clears. Attach to the\n"
    "\t * still-running EFI link WITHOUT a full reset so the init survives.\n"
    "\t */\n"
    "\tif (pci->subsystem_vendor == 0x8086 &&\n"
    "\t    pci->subsystem_device == 0x7270 && pci->device == 0x9ca0) {\n"
    "\t\tdev_info(card->dev,\n"
    "\t\t\t \"MacBook8,1: attaching to running EFI link without reset\\n\");\n"
    "\t\thda_intel_init_chip(chip, false);\n"
    "\t\tif (!azx_bus(chip)->codec_mask)\n"
    "\t\t\tazx_bus(chip)->codec_mask = 1; /* CS4208 is codec 0 */\n"
    "\t} else {\n"
    "\t\thda_intel_init_chip(chip, (probe_only[dev] & 2) == 0);\n"
    "\t}"
)
s = s.replace(old, new, 1)
open(p, "w").write(s)
print("    patched.")
PYEOF

# 3. Drop in the single-module Makefile and build.
echo "=== building snd-hda-intel.ko ==="
[[ -f "$ctrl_dir/Makefile" && ! -f "$ctrl_dir/Makefile.orig" ]] && \
    mv "$ctrl_dir/Makefile" "$ctrl_dir/Makefile.orig"
cp "$HERE/patch_cirrus/Makefile_azx" "$ctrl_dir/Makefile"

make -C "/lib/modules/$uname_r/build" M="$ctrl_dir" clean >/dev/null 2>&1 || true
make -C "/lib/modules/$uname_r/build" M="$ctrl_dir" modules

# 4. Install (skipped under BUILD_ONLY — DKMS installs from the build tree).
if [[ -z "${BUILD_ONLY:-}" ]]; then
    mkdir -p "$update_dir"
    cp "$ctrl_dir/snd-hda-intel.ko" "$update_dir/"
    depmod -a
    echo
    echo "=== installed ==="
    modinfo -n snd-hda-intel
    echo "srcversion: $(modinfo -F srcversion snd-hda-intel)"
    echo
    echo "NOTE: boot must leave this controller untouched until probe."
    echo "Test on an MB81-CHIME-CAP boot (snd_hda_intel blacklisted), then modprobe."
else
    echo "=== built (BUILD_ONLY): $ctrl_dir/snd-hda-intel.ko ==="
fi
