#!/bin/bash
# install.generic.driver.sh — build a patched snd-hda-codec-generic.ko.
#
# MacBook8,1 (CS4208, vendor_id 0x10134208) clock-latch fix.
#
# The CS4208 comes out of EFI with its PLL clock locked. Two snd_hda_gen_init()
# bring-up steps knock that lock out and latch a clock fault (coef 0x1f bit10,
# 0x0 -> 0x400) -> silent speakers, with NO register trace. Both were
# bisected (2026-06-14/15) and are skipped for the CS4208:
#
#   1. The ADC/loopback INPUT paths (init_aamix_paths / init_analog_input /
#      init_input_src) share the PLL clock domain with the TDM speaker DAC.
#      This machine is speaker-out only, so the inputs are unused — skip them.
#   2. init_digital sends SET_DIGI_CONVERT to the SHARED converter 0x0a (the
#      auto-parser registered it as SPDIF). Rewriting 0x0a's digital-converter
#      config during bring-up glitches the TDM serializer. efi_chime_play (which
#      PLAYS) never touches dig1, so leaving 0x0a in EFI's chime state is correct.
#
# Run:  sudo bash install.generic.driver.sh
set -eu
[[ $EUID -ne 0 ]] && { echo "must be root"; exit 1; }

KVER=$(uname -r)
while [[ $# -gt 0 ]]; do
    case "$1" in
        -k|--kernel) KVER="$2"; [[ -z "$KVER" ]] && { echo "-k needs a kernel version"; exit 1; }; shift;;
        *) echo "unrecognized option: $1"; exit 1;;
    esac
    shift
done

REPO="$(cd "$(dirname "$0")" && pwd)"
SRC="$REPO/build/hda/codecs/generic.c"
GEN="$REPO/build/hda/genmod"

[[ -f "$SRC" ]] || { echo "FAIL: $SRC missing — run install.cirrus.driver.sh first"; exit 1; }

rm -rf "$GEN"
mkdir -p "$GEN"
cp "$REPO/build/hda/codecs/generic.h" "$GEN/generic.h"

python3 - "$SRC" "$GEN/generic.c" <<'PY'
import sys
src, dst = sys.argv[1], sys.argv[2]
s = open(src).read()

# MacBook8,1 CS4208 vendor id: defined once at file scope, just above the
# function, so the body below carries no magic number.
fn = '''int snd_hda_gen_init(struct hda_codec *codec)
{'''
fn_new = '''/* MacBook8,1 Cirrus CS4208 codec vendor id (see HDA_CODEC_ENTRY in patch_cirrus.c). */
#define MB81_CS4208_VENDOR_ID 0x10134208

int snd_hda_gen_init(struct hda_codec *codec)
{'''
assert s.count(fn) == 1, "snd_hda_gen_init definition anchor count != 1"
s = s.replace(fn, fn_new, 1)

# Original body (exact, tab-indented) -> CS4208-patched body.
old = '''	init_multi_out(codec);
	init_extra_out(codec);
	init_multi_io(codec);
	init_aamix_paths(codec);
	init_analog_input(codec);
	init_input_src(codec);
	init_digital(codec);
'''
new = '''	init_multi_out(codec);
	init_extra_out(codec);
	init_multi_io(codec);
	/* MB81 FIX: on the CS4208 the ADC/loopback input paths share the PLL clock
	 * domain with the TDM speaker DAC; bringing these (unused on this
	 * speaker-out-only machine) up knocks the EFI-locked PLL out of lock and
	 * latches coef 0x1f bit10 -> silent speakers. Skip them. */
	if (codec->core.vendor_id != MB81_CS4208_VENDOR_ID) {
		init_aamix_paths(codec);
		init_analog_input(codec);
		init_input_src(codec);
	}
	/* MB81 FIX: init_digital sends SET_DIGI_CONVERT to the SHARED converter
	 * 0x0a (auto-parser registered it as SPDIF). Rewriting 0x0a's digital-
	 * converter config during bring-up glitches the TDM serializer with no
	 * register trace -> speakers silent. efi_chime_play (which PLAYS) never
	 * touches dig1, so leave 0x0a in EFI's chime state for the CS4208. */
	if (codec->core.vendor_id != MB81_CS4208_VENDOR_ID)
		init_digital(codec);
'''
assert s.count(old) == 1, "gen_init body anchor count != 1"
s = s.replace(old, new, 1)

open(dst, "w").write(s)
print("patched generic.c written:", dst)
PY

cat > "$GEN/Kbuild" <<'EOF'
ccflags-y += -I$(src)/../common
obj-m := snd-hda-codec-generic.o
snd-hda-codec-generic-y := generic.o
EOF

KB="/lib/modules/$KVER/build"
echo "=== building patched snd-hda-codec-generic.ko for $KVER ==="
make -C "$KB" M="$GEN" modules

# Install (skipped under BUILD_ONLY — DKMS installs from the build tree).
if [[ -z "${BUILD_ONLY:-}" ]]; then
    UP="/lib/modules/$KVER/updates"
    mkdir -p "$UP"
    cp "$GEN/snd-hda-codec-generic.ko" "$UP/"
    depmod -a
    echo "=== installed ==="
    modinfo -n snd-hda-codec-generic
    echo "srcversion: $(modinfo -F srcversion snd-hda-codec-generic)"
    echo "DONE. Reboot to load the patched snd-hda-codec-generic.ko."
else
    echo "=== built (BUILD_ONLY): $GEN/snd-hda-codec-generic.ko ==="
fi
