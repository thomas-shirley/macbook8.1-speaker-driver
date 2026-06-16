#!/bin/bash
# install.sh — one-shot installer for the MacBook8,1 (CS4208) built-in speaker fix.
#
# Installs, as a DKMS package that rebuilds on every kernel upgrade:
#   (A) snd-hda-intel     — no-reset attach to the live EFI link
#   (C) snd-hda-codec-cs420x — EFI coef image + TDM prepare sync-dance fix
#   (D) snd-hda-codec-generic — CS4208 input-path + init_digital skip (clock latch)
# plus the three runtime config files:
#   (B) mb81-singlecmd.conf  -> /etc/modprobe.d/   (single_cmd=1, reliable enum)
#       51-macbook81-speaker.conf -> ~/.config/pipewire/pipewire.conf.d/  (EQ chain)
#       51-mb81-rawpcm-speaker.conf -> ~/.config/wireplumber/wireplumber.conf.d/
#           (raw-PCM mode: WirePlumber creates MacBook_Speaker_Raw for device 2
#            event-driven so it survives the cold-boot timing race)
#
# Run:  sudo bash install.sh
# Remove: sudo bash install.sh -r
set -eu

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$here"

action='install'
[[ "${1:-}" == "-r" || "${1:-}" == "-u" || "${1:-}" == "--remove" ]] && action='remove'

[[ $EUID -ne 0 ]] && { echo "must be root: sudo bash $0 ${1:-}"; exit 1; }

# Resolve the invoking (non-root) user so the PipeWire/WirePlumber configs land
# in their per-user config dirs, not root's.
real_user="${SUDO_USER:-$USER}"
real_home="$(getent passwd "$real_user" | cut -d: -f6)"
pw_dir="$real_home/.config/pipewire/pipewire.conf.d"
wp_dir="$real_home/.config/wireplumber/wireplumber.conf.d"

if [[ $action == 'remove' ]]; then
    echo "=== removing DKMS package ==="
    bash dkms.sh -r || true
    echo "=== removing config files ==="
    rm -f /etc/modprobe.d/mb81-singlecmd.conf
    rm -f "$pw_dir/51-macbook81-speaker.conf"
    rm -f "$wp_dir/51-mb81-rawpcm-speaker.conf"
    rm -f "$wp_dir/51-mb81-disable-iec958.conf"   # legacy name (pre raw-PCM)
    depmod -a
    echo "DONE. Reboot to fall back to the stock in-tree drivers."
    exit 0
fi

echo "=== (B) modprobe.d: single_cmd=1 ==="
install -m 0644 mb81-singlecmd.conf /etc/modprobe.d/mb81-singlecmd.conf

echo "=== PipeWire EQ sink + WirePlumber raw-PCM speaker (user: $real_user) ==="
install -d -o "$real_user" -g "$real_user" "$pw_dir" "$wp_dir"
install -m 0644 -o "$real_user" -g "$real_user" \
    51-macbook81-speaker.conf "$pw_dir/51-macbook81-speaker.conf"
install -m 0644 -o "$real_user" -g "$real_user" \
    51-mb81-rawpcm-speaker.conf "$wp_dir/51-mb81-rawpcm-speaker.conf"
# Remove the legacy iec958-disable rule if a previous install left it (its job
# is now folded into 51-mb81-rawpcm-speaker.conf, which disables device 1).
rm -f "$wp_dir/51-mb81-disable-iec958.conf"

echo "=== clearing stale standalone module copies (so DKMS's updates/dkms wins) ==="
# Earlier manual install.*.driver.sh runs put these directly in updates/, which
# would shadow the DKMS-managed copies in updates/dkms/. Remove them; DKMS
# reinstalls all three under updates/dkms/.
for kdir in /lib/modules/*/updates; do
    rm -f "$kdir"/snd-hda-codec-cs420x.ko* \
          "$kdir"/snd-hda-codec-generic.ko* \
          "$kdir"/snd-hda-intel.ko* 2>/dev/null || true
done

echo "=== (A/C/D) building + installing the three modules via DKMS ==="
bash dkms.sh
depmod -a

echo
echo "================================================================"
echo "DONE. The patched snd-hda-intel autoloads at a normal boot and"
echo "attaches to the live EFI link without reset; CS4208 enumerates"
echo "via single_cmd, and the speaker plays through input.MacBook_Speaker."
echo "Reboot to activate."
echo "================================================================"
