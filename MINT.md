# Linux Mint 22.x / XFCE notes (MacBook8,1)

Everything here was needed on top of the driver itself; none of it changes the
kernel modules.

## 1. WirePlumber 0.4

Mint 22.x ships WirePlumber 0.4.17, which ignores SPA-JSON `.conf` snippets.
`install.sh` installs `51-mb81-rawpcm-speaker.lua` (0.4 rule format) next to the
`.conf`, so the raw speaker node exists on both 0.4 and 0.5.

## 2. `model=generic` must not be set

A previous "fix silent Mac" attempt had left

```
options snd-hda-intel model=generic
```

in `/etc/modprobe.d/`. With that option the kernel sets
`codec->probe_id = HDA_CODEC_ID_GENERIC`, and `hda_codec_match()` then offers the
CS4208 only to `snd-hda-codec-generic`. `snd-hda-codec-cs420x` cannot bind at
all — no TDM speaker PCM (device 2), codec shown as "Cirrus Logic Generic".
`install.sh` now strips the token; to fix by hand:

```bash
sudo sed -i -E 's/(^|[[:space:]])model=generic([[:space:]]|$)/\1\2/' /etc/modprobe.d/*.conf
sudo update-initramfs -u -k all
```

Symptom in `dmesg`: `attaching to running EFI link without reset` is present, but
no `MB81 TDM PREPARE done` and `aplay -l` has no card-0 device 2.

## 3. Top-row media keys (`applespi`)

`applespi` defaults to `fnmode=1`, meaning **media keys are primary** and F1–F12
need `Fn`. Note this is the opposite of `hid_apple`'s numbering: `2` is
"fkeysfirst" and turns the top row back into F-keys. Persist it with:

```bash
echo 'options applespi fnmode=1' | sudo tee /etc/modprobe.d/applespi-fnmode.conf
sudo update-initramfs -u -k all
```

## 4. Volume keys + on-screen level

XFCE ships no default bindings for `XF86Audio*`. The helper in
`mint/mb81-volume` steps the default sink, clamps at 100% and shows a
notification with a level bar:

```bash
install -m 0755 mint/mb81-volume ~/.local/bin/mb81-volume
xfconf-query -c xfce4-keyboard-shortcuts -p /commands/custom/XF86AudioRaiseVolume \
     -n -t string -s "$HOME/.local/bin/mb81-volume +5"
xfconf-query -c xfce4-keyboard-shortcuts -p /commands/custom/XF86AudioLowerVolume \
     -n -t string -s "$HOME/.local/bin/mb81-volume -5"
xfconf-query -c xfce4-keyboard-shortcuts -p /commands/custom/XF86AudioMute \
     -n -t string -s "$HOME/.local/bin/mb81-volume mute"
```

`-n` fails if the property already exists; drop it on re-runs.
