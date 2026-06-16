# MacBook8,1 (12-inch, Early 2015) — built-in speaker driver

Makes the internal speakers work on Linux for the 12" MacBook (MacBook8,1, A1534,
Cirrus Logic **CS4208** codec driving a TDM class-D amplifier). This took around 3 months of persistent testing/ chatting with Claude, plus a mountain of manual verification to iterate over and over, before converging on a solution. Three different patches were actually required, with some pipewire configs in the mix too.

Note: I have no prior experience with drivers, so this has been a learning curve - there are still plenty of gaps in my knowledge and plenty I don't actually understand. But I love the form factor of this laptop and the quality of the industrial design, so I'm pleased to keep it going.

Switching between speakers & headphones is still wonky, I'm working on that. There is currently a systemd unit to handle switching between headphone jack and the speakers, so we don't end up with silence again after pulling out the jack.

> The full kernel driver stack
> plays the built-in speakers through normal PipeWire on every plain reboot, with
> no manual steps. Validated end-to-end on kernel 6.17 (Ubuntu) via DKMS.

If you just want it working, jump to [Install](#install). For *why* this was hard
and how each piece works, read [`HOW_IT_WORKS.md`](HOW_IT_WORKS.md).

---

## What this is

The stock in-tree `snd_hda_codec_cs420x` driver detects the CS4208 but cannot
make the internal speakers play on this machine: the speaker path is not the
ordinary analog DAC, it's a **4-channel TDM stream** into an external class-D
amp, and the codec comes out of EFI in a fragile clock state that the normal
driver bring-up sequence silently breaks.

The fix is **four patched/added pieces that only work together**, plus three
runtime config files. All of it is packaged as a single DKMS install that
rebuilds automatically on kernel upgrades.

| Part | What it does | Where |
|---|---|---|
| **A** `snd-hda-intel` | Attaches to the live EFI link **without a controller reset** (the reset latches a codec clock fault) | `install.azx.driver.sh` |
| **B** `single_cmd=1` | Forces the reliable MMIO immediate-command path so the un-reset codec enumerates | `mb81-singlecmd.conf` |
| **C** `snd-hda-codec-cs420x` | Writes the EFI coef image + fixes the TDM `prepare` sequence (the actual "silencer" bug) | `install.cirrus.driver.sh`, `patch_cirrus/` |
| **D** `snd-hda-codec-generic` | Skips the input-path bring-up that latches the PLL clock fault on the CS4208 | `install.generic.driver.sh` |
| routing | PipeWire EQ sink + event-driven WirePlumber raw-PCM node (survives the cold-boot race) | `51-macbook81-speaker.conf`, `51-mb81-rawpcm-speaker.conf` |

See [`HOW_IT_WORKS.md`](HOW_IT_WORKS.md) for the full story of each.

---

## Prerequisites

```bash
sudo apt install gcc make dkms wget
```

Matching kernel headers must be present:

```bash
ls /usr/src/linux-headers-$(uname -r)
```

`wget` is required: the build downloads the matching kernel source tarball from
kernel.org to extract the pristine HDA sources before patching them.

---

## Install

```bash
cd macbook8.1-speaker-driver
sudo bash install.sh
sudo reboot
```

That's it. After reboot the speakers play through the default sink
`input.MacBook_Speaker` — no manual `systemctl --user restart` needed.

`install.sh`:

- Registers the DKMS package **`macbook12-audio/0.1`**, which rebuilds all three
  modules (`snd-hda-codec-cs420x`, `snd-hda-codec-generic`, `snd-hda-intel`) on
  every kernel upgrade.
- Installs `/etc/modprobe.d/mb81-singlecmd.conf` (`single_cmd=1 power_save=0`).
- Installs the two user configs into the invoking user's home:
  - `~/.config/pipewire/pipewire.conf.d/51-macbook81-speaker.conf` (EQ chain)
  - `~/.config/wireplumber/wireplumber.conf.d/51-mb81-rawpcm-speaker.conf`
    (raw-PCM speaker node, SPDIF disabled)

### Uninstall

```bash
sudo bash install.sh -r
sudo reboot
```

Removes the DKMS package and all config files; the stock in-tree drivers take
over again on the next boot.

---

## Verify

After reboot:

```bash
# fresh boot, no manual restart:
uptime -p

# CS4208 should be a card (PCH)
cat /proc/asound/cards

# the raw speaker sink + EQ chain should be present
wpctl status | grep -i speaker
#   MacBook Speaker (Raw)        <- raw-PCM node (device 2 TDM)
#   input.MacBook_Speaker        <- default EQ sink (play here)
#   MacBook_Speaker_DSP_Out      <- EQ output, targets the Raw node

# the patched modules should come from updates/dkms
modinfo -n snd-hda-intel snd-hda-codec-cs420x snd-hda-codec-generic

# the no-reset attach should have fired
dmesg | grep -i "attaching to running EFI link without reset"

# play a tone
speaker-test -c2 -t sine -f 440 -D pipewire 2>/dev/null
```

A correct boot shows codec coef `0x1f = 0x0` (clock locked) end to end; a broken
boot shows `0x1f = 0x400` (latched clock fault) and silence. See `HOW_IT_WORKS.md`.

---

## Layout

```
install.sh                     one-shot installer (DKMS + configs)
dkms.conf / dkms.sh            DKMS package definition + register/remove helper
dkms_build.sh                  PRE_BUILD: builds all 3 modules in BUILD_ONLY mode
install.cirrus.driver.sh       builds patched snd-hda-codec-cs420x (part C)
install.generic.driver.sh      builds patched snd-hda-codec-generic (part D)
install.azx.driver.sh          builds patched snd-hda-intel       (part A)
Makefile_cs420x / Makefile_cirrus   out-of-tree build makefiles (6.17+ / older)
mb81-singlecmd.conf            modprobe.d: single_cmd=1 power_save=0   (part B)
51-macbook81-speaker.conf      PipeWire EQ filter-chain sink
51-mb81-rawpcm-speaker.conf    WirePlumber raw-PCM speaker node + SPDIF disable
patch_cirrus/                  C sources for the three module patches
HOW_IT_WORKS.md                deep dive: the bugs and the four-part fix
```

`build/` is created during the build (kernel source extraction) and is
git-ignored.

---

## Credits

Built on davidjo's [snd_hda_macbookpro](https://github.com/davidjo/snd_hda_macbookpro)
and leifliddy's [macbook12-audio-driver](https://github.com/leifliddy/macbook12-audio-driver),
extended for MacBook8,1's TDM speaker path and EFI clock-state quirks.
