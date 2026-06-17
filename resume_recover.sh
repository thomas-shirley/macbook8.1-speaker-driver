#!/bin/bash
# resume_recover.sh — restore the MacBook8,1 internal speakers after S3 resume.
#
# WHY: on resume the HDA controller comes back through a reset that re-induces the
# CS4208 clock latch (coef 0x1f = 0x400). While snd_hda_intel stays BOUND, NOTHING
# clears it (PMCSR D3, runtime-PM D3, even a GCTL CRST all leave 0x400) — so the
# TDM PREPARE re-runs with the right format=0x4013 yet the PLL is latched -> silence.
# The ONLY clear is to let the codec sit UNOWNED so the PCH gates the HDA clock and
# the PLL re-locks. That is exactly what efi_recover.py does (D3hot->D0 + EFI replay).
# After the driverless heal we re-modprobe the patched no-reset+single_cmd driver,
# which re-attaches to the freshly EFI-replayed link just like a clean cold boot.
#
# Run by mb81-resume-recover.service on every resume; also runnable by hand:
#   sudo bash resume_recover.sh
#
# Guaranteed fallback if anything misbehaves: a plain reboot (cold-boot path clean).

set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[[ $EUID -ne 0 ]] && { echo "must be root: sudo bash resume_recover.sh"; exit 1; }

# Resolve the desktop user whose PipeWire/jack-switch we toggle. Interactive runs
# get it from SUDO_USER; the resume service (no SUDO_USER) finds the active seat
# user via loginctl.
U="${SUDO_USER:-}"
if [[ -z "$U" || "$U" == "root" ]]; then
    U="$(loginctl list-users --no-legend 2>/dev/null | awk '$1>=1000{print $2; exit}')"
fi
[[ -z "$U" ]] && { echo "FAIL: could not resolve a desktop user"; exit 1; }
RT="/run/user/$(id -u "$U")"
run_user(){ sudo -u "$U" XDG_RUNTIME_DIR="$RT" \
            DBUS_SESSION_BUS_ADDRESS="unix:path=$RT/bus" "$@"; }
PWUNITS="pipewire.socket pipewire-pulse.socket pipewire.service pipewire-pulse.service wireplumber.service"

echo "=== mb81 resume recovery (user: $U) $(date -Is) ==="

echo "=== 1/5: release PipeWire + the jack-switch monitor (both hold the PCM) ==="
# mb81-jack-switch.service runs `alsactl monitor hw:1`, keeping /dev/snd/controlC1
# open — it pins the module and must be stopped before the codec can sit unowned.
run_user systemctl --user stop mb81-jack-switch.service 2>/dev/null
run_user systemctl --user stop $PWUNITS 2>/dev/null
sleep 1

echo "=== 2/5: unload the whole HDA stack so 00:1b.0 sits UNOWNED ==="
# HDMI audio on 00:03.0 also holds snd_hda_intel — unbind it first.
[[ -e /sys/bus/pci/devices/0000:00:03.0/driver ]] && \
    echo 0000:00:03.0 > /sys/bus/pci/drivers/snd_hda_intel/unbind
rmmod snd_hda_codec_cs420x    2>/dev/null
rmmod snd_hda_codec_generic   2>/dev/null
rmmod snd_hda_codec_intelhdmi 2>/dev/null
rmmod snd_hda_codec_hdmi      2>/dev/null
modprobe -r snd_hda_intel     2>/dev/null
sleep 1
if [[ -e /sys/bus/pci/devices/0000:00:1b.0/driver ]]; then
    echo "FAIL: 00:1b.0 still bound after unload:"; ls -l /sys/bus/pci/devices/0000:00:1b.0/driver
    echo "Something still holds the module. Reboot to recover."
    run_user systemctl --user start $PWUNITS 2>/dev/null
    run_user systemctl --user start mb81-jack-switch.service 2>/dev/null
    exit 1
fi
echo "    00:1b.0 unowned; PCH clock-gate window (2 s)..."; sleep 2

echo "=== 3/5: driverless heal — efi_recover.py (clears 0x1f latch + EFI replay) ==="
python3 "$HERE/efi_recover.py" || { echo "FAIL: efi_recover.py errored — reboot to recover."; exit 1; }

echo "=== 4/5: re-attach the patched driver (no-reset + single_cmd, like boot) ==="
modprobe snd_hda_intel
sleep 3
CODECF=$(grep -l 'Cirrus Logic CS4208' /proc/asound/card*/codec#0 2>/dev/null | head -1)
[[ -z "$CODECF" ]] && { echo "FAIL: CS4208 did not re-enumerate — reboot to recover."; exit 1; }
CARD=$(echo "$CODECF" | grep -oP 'card\K[0-9]+')
DEV=/dev/snd/hwC${CARD}D0
rdcoef(){ hda-verb "$DEV" 0x24 0x500 "$1" >/dev/null 2>&1
          hda-verb "$DEV" 0x24 0xC00 0 2>&1 | grep -oP 'value = \K0x[0-9a-f]+'; }
echo "    CS4208 = card $CARD ; coef 0x1f after re-attach = $(rdcoef 0x1f)  (want 0x0000)"

echo "=== 5/5: restart PipeWire + the jack-switch monitor; select the speaker sink ==="
run_user systemctl --user start $PWUNITS 2>/dev/null
sleep 3
run_user pactl set-default-sink input.MacBook_Speaker 2>/dev/null || true
run_user systemctl --user start mb81-jack-switch.service 2>/dev/null || true
echo "=== done — audio should be back. If silent, just reboot (cold-boot path is clean). ==="
