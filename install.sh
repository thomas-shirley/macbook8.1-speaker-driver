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
#       51-mb81-rawpcm-speaker.lua  -> ~/.config/wireplumber/main.lua.d/
#           (same rules for WirePlumber 0.4.x, as shipped by Mint 22.x / Ubuntu
#            24.04; 0.4 has no SPA-JSON .conf support)
# plus the suspend/resume recovery (S3 resume re-latches the codec clock; a bound
# driver cannot clear it, so audio returns silent):
#       resume_recover.sh + efi_recover.py -> /usr/local/bin/
#       mb81-resume-recover.service -> /etc/systemd/system/ (runs on every resume)
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
real_uid="$(id -u "$real_user")"
pw_dir="$real_home/.config/pipewire/pipewire.conf.d"
wp_dir="$real_home/.config/wireplumber/wireplumber.conf.d"
wp_lua_dir="$real_home/.config/wireplumber/main.lua.d"

# Run `systemctl --user` as the invoking user, against their session bus.
user_systemctl() {
    sudo -u "$real_user" \
        XDG_RUNTIME_DIR="/run/user/$real_uid" \
        DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$real_uid/bus" \
        systemctl --user "$@"
}

# Rebuild the initramfs. Both the patched modules and mb81-singlecmd.conf (the
# cs420x softdep) are baked into it, and neither `dkms install` nor a plain
# `cp` into /etc/modprobe.d updates it — Ubuntu's DKMS defaults REMAKE_INITRD
# to "no". Skipping this leaves the machine booting a stale initrd: an old
# generic linking against a new cs420x ("disagrees about version of symbol
# snd_hda_gen_spec_init", err -22) and no softdep, so generic wins the codec
# bind and the speaker is silent even though the card looks healthy.
# Kept identical to dkms.sh's copy; install.sh runs it once at the end, with
# MB81_SKIP_INITRAMFS=1 suppressing the nested one.
refresh_initramfs() {
    echo "=== refreshing initramfs (so new modules + softdep reach boot) ==="
    if command -v update-initramfs > /dev/null; then
        update-initramfs -u -k all
    else
        echo "WARNING: no update-initramfs found. Refresh the initramfs by hand,"
        echo "         or the installed modules will NOT be the ones used at boot."
    fi
}

if [[ $action == 'remove' ]]; then
    echo "=== removing suspend/resume recovery service ==="
    systemctl disable --now mb81-resume-recover.service 2>/dev/null || true
    rm -f /etc/systemd/system/mb81-resume-recover.service \
          /usr/local/bin/mb81-resume-recover /usr/local/bin/efi_recover.py
    systemctl daemon-reload 2>/dev/null || true
    echo "=== removing headphone jack-switch service ==="
    user_systemctl disable --now mb81-jack-switch.service 2>/dev/null || true
    rm -f /etc/systemd/user/mb81-jack-switch.service /usr/local/bin/mb81-jack-switch
    user_systemctl daemon-reload 2>/dev/null || true
    echo "=== removing DKMS package ==="
    # Defer the initramfs refresh: the modprobe.d conf is still on disk here,
    # and refreshing now would bake it back in. Done once at the end instead.
    MB81_SKIP_INITRAMFS=1 bash dkms.sh -r || true
    echo "=== removing config files ==="
    rm -f /etc/modprobe.d/mb81-singlecmd.conf
    rm -f "$pw_dir/51-macbook81-speaker.conf"
    rm -f "$wp_dir/51-mb81-rawpcm-speaker.conf"
    rm -f "$wp_lua_dir/51-mb81-rawpcm-speaker.lua"
    rm -f "$wp_dir/51-mb81-disable-iec958.conf"   # legacy name (pre raw-PCM)
    depmod -a
    refresh_initramfs
    echo "DONE. Reboot to fall back to the stock in-tree drivers."
    exit 0
fi

echo "=== disabling any leftover 'model=generic' for snd-hda-intel ==="
# A common "fix" for silent Macs is options snd-hda-intel model=generic. It
# makes snd_hda_codec_configure() set codec->probe_id = HDA_CODEC_ID_GENERIC,
# so hda_codec_match() then offers the CS4208 *only* to snd-hda-codec-generic:
# cs420x can never bind, no matter the load order. Strip just that token (other
# options on the line are kept) and keep a backup.
while IFS= read -r f; do
    cp -a "$f" "$f.mb81-bak"
    sed -i -E 's/(^|[[:space:]])model=generic([[:space:]]|$)/\1\2/' "$f"
    echo "    cleaned $f (backup: $f.mb81-bak)"
done < <(grep -lE '^[[:space:]]*options[[:space:]]+snd-hda-intel.*model=generic' /etc/modprobe.d/*.conf 2>/dev/null || true)

echo "=== (B) modprobe.d: single_cmd=1 ==="
install -m 0644 mb81-singlecmd.conf /etc/modprobe.d/mb81-singlecmd.conf

echo "=== PipeWire EQ sink + WirePlumber raw-PCM speaker (user: $real_user) ==="
install -d -o "$real_user" -g "$real_user" "$pw_dir" "$wp_dir" "$wp_lua_dir"
install -m 0644 -o "$real_user" -g "$real_user" \
    51-macbook81-speaker.conf "$pw_dir/51-macbook81-speaker.conf"
install -m 0644 -o "$real_user" -g "$real_user" \
    51-mb81-rawpcm-speaker.conf "$wp_dir/51-mb81-rawpcm-speaker.conf"
# WirePlumber 0.4.x (Mint 22.x / Ubuntu 24.04) ignores the SPA-JSON .conf above
# and reads Lua snippets from main.lua.d instead; install the 0.4 equivalent too.
install -m 0644 -o "$real_user" -g "$real_user" \
    51-mb81-rawpcm-speaker.lua "$wp_lua_dir/51-mb81-rawpcm-speaker.lua"
# Remove the legacy iec958-disable rule if a previous install left it (its job
# is now folded into 51-mb81-rawpcm-speaker.conf, which disables device 1).
rm -f "$wp_dir/51-mb81-disable-iec958.conf"

echo "=== headphone jack auto-switch (user service) ==="
install -m 0755 mb81-jack-switch.sh /usr/local/bin/mb81-jack-switch
install -m 0644 mb81-jack-switch.service /etc/systemd/user/mb81-jack-switch.service
if [[ -d "/run/user/$real_uid" ]]; then
    user_systemctl daemon-reload || true
    user_systemctl enable --now mb81-jack-switch.service || true
    echo "    jack-switch service enabled for $real_user"
else
    echo "    NOTE: no active session for $real_user; enable it after next login with:"
    echo "          systemctl --user enable --now mb81-jack-switch.service"
fi

echo "=== suspend/resume recovery (re-heals the codec clock latch on every wake) ==="
install -m 0755 resume_recover.sh /usr/local/bin/mb81-resume-recover
# efi_recover.py is invoked from the same dir as the script; keep them co-located.
install -m 0755 efi_recover.py /usr/local/bin/efi_recover.py
install -m 0644 mb81-resume-recover.service /etc/systemd/system/mb81-resume-recover.service
systemctl daemon-reload || true
systemctl enable mb81-resume-recover.service || true
echo "    mb81-resume-recover.service enabled (runs on every resume)"

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
# Defer dkms.sh's own refresh so the initramfs is rebuilt exactly once, below,
# after both the modules and mb81-singlecmd.conf are in place.
MB81_SKIP_INITRAMFS=1 bash dkms.sh
depmod -a
refresh_initramfs

echo
echo "================================================================"
echo "DONE. The patched snd-hda-intel autoloads at a normal boot and"
echo "attaches to the live EFI link without reset; CS4208 enumerates"
echo "via single_cmd, and the speaker plays through input.MacBook_Speaker."
echo "Reboot to activate."
echo "================================================================"
