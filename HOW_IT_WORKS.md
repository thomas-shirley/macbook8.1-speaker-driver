# How the MacBook8,1 speaker fix works

This is the long version: what was actually wrong, how it was diagnosed, and how
each of the four parts of the fix addresses one specific failure. If you just
want to install it, see [`README.md`](README.md).

---

## TL;DR

The CS4208 on this machine drives the internal speakers over a **4-channel TDM
link into an external class-D amplifier**, not the ordinary analog DAC. EFI
initialises that whole chain at boot (you hear the boot chime), leaving the codec
in a working but **fragile clock state**. The normal Linux HD-audio bring-up
sequence breaks that state in two independent ways and then, even once the clock
is fixed, mis-sequences the TDM stream so nothing comes out.

The single most useful diagnostic signal throughout was one codec register:

> **Vendor coef `0x1f`** — `0x0` means the codec PLL clock is locked (good);
> `0x400` (bit 10) means a **latched clock fault** (silent). The latch is
> *asymmetric*: a link reset can **create** it, but no register replay can
> **clear** it. Only gating the codec to D3 while **unowned** (no driver bound)
> clears it — which is impossible once the driver holds the link. So the only
> viable strategy is to **never create the latch in the first place.**

Four things had to be true simultaneously, or the speakers stay silent.

---

## Hardware background

- **Codec:** Cirrus Logic CS4208, vendor id `0x10134208`, subsystem `0x106b6400`.
- **Controller:** Intel PCH HD-audio, PCI `8086:9ca0`, subsystem `8086:7270`.
- **Speaker path:** converter node `0x0a` → TDM pin `0x1d` → external class-D
  amp. The amp is controlled by GPIOs on the codec (mute + DFET power rails).
- **EFI does a full, working init at every boot** — the startup chime plays
  through these exact speakers. That gave us a *known-good reference*: dump the
  codec state driverlessly (via the controller's MMIO immediate-command
  registers) right after the chime, before Linux touches anything, and compare it
  against what the driver produces.

The reference dump (`coef 0x00=0xc4`, `0x03=0xbaa`, `0x33=0x821`,
`0x34=0x3b21`, gated `0x50=0xcb`, fmt `0x0a=0x4013` = 44.1 kHz / 16-bit / 4ch,
**GPIO mask `0x09` — EFI never drives the DFET rails, only the mute + status
pins**) became the target the driver had to reproduce.

---

## The bugs, in the order they were peeled back

### 1. The clock latch (asymmetric, register-invisible)

The codec leaves EFI with its PLL locked (`0x1f = 0x0`). Two separate driver
actions knock it out and **latch** a clock fault (`0x1f → 0x400`):

1. **The controller's probe-time link reset (CRST).** Stock `snd-hda-intel`
   pulses a link reset when it attaches. That wipes EFI's clock init.
2. **Input-path bring-up inside `snd_hda_gen_init()`.** Even with the reset
   skipped, the generic parser's `init_aamix_paths()` + `init_analog_input()` +
   `init_input_src()` disturb the ADC/loopback PLL domain — which the TDM speaker
   DAC *shares* — and re-latch the fault. This was bisected step-by-step (the
   "g5" step) by instrumenting `snd_hda_gen_init` to print `0x1f` between every
   sub-call.

Crucially, **once latched it cannot be un-latched by the driver**: forcing a
GCTL CRST pulse with good coefs first (`crst_heal`) left `0x1f = 0x400`; a
D3hot→D0 power cycle while the driver was bound never even dropped GCTL
(`No_Soft_Reset=1`) and stayed `0x400`. The only thing that ever cleared it was
gating the codec to D3 while *no driver owned it* — useless as a runtime
strategy. Conclusion: **prevent the latch, don't try to repair it.**

### 2. The enumeration wedge

Attaching to the still-running EFI link *without* a reset (the fix for bug 1)
turned out to be flaky over the normal **CORB/RIRB DMA command ring**: the
un-reset codec returns `spurious response 0x0:0x0`, the controller times out
(`cannot read sub nodes for FG 0x1085` → `no codecs initialized`), and a *late*
fallback to single-command mode inherits an already-wedged link. A failed
no-reset attach wedges the codec so badly it needs a full reboot to recover.

The insight: the driverless rescue tools were **100% reliable on the same codec**
because they used the controller's **MMIO immediate-command interface**
(ICOI/ICII/ICIS), never CORB/RIRB. So the answer was to force the driver onto
that same path from the very first verb.

### 3. The silencer (routing, not clock)

Even with `0x1f = 0x0` all the way through bring-up, the TDM path was still
silent. The culprit was a "sync-dance" in the TDM `prepare` callback:

```
SET_STREAM_FORMAT(0x0a, 0)         # converter turned OFF mid-stream
coef 0x01 |= 0x100
SET_STREAM_FORMAT(0x0a, 0x4013)    # restored
```

That de-synced the TDM serializer. EFI's chime playback never does this — it sets
the format once and leaves it. A second, smaller divergence: PipeWire was opening
the converter at 48 kHz (`0x13`) while EFI used 44.1 kHz (`0x4013`).

---

## The fix — four parts (all required together)

### (A) `snd-hda-intel`: no-reset attach — `install.azx.driver.sh`

Patches `sound/hda/controllers/intel.c` to special-case this controller
(`pci 8086:9ca0`, ssid `8086:7270`) and call `hda_intel_init_chip(chip, false)` —
i.e. attach to the **live EFI link with `full_reset=false`**. EFI's clock init
survives instead of being wiped. It also seeds `codec_mask = 1` (the CS4208 is
codec 0) so enumeration proceeds without a reset to discover it.

dmesg marker on success:

```
MacBook8,1: attaching to running EFI link without reset
```

This addresses **bug 1, cause 1**.

### (B) `single_cmd=1`: reliable enumeration — `mb81-singlecmd.conf`

```
options snd_hda_intel single_cmd=1 power_save=0
```

`single_cmd=1` forces the controller onto the **MMIO immediate-command path from
the first verb**, bypassing the CORB/RIRB ring that wedges the no-reset attach.
This is what actually made enumeration succeed reliably across reboots.

`power_save=0` keeps the codec in D0 and never runtime-suspends it. The class-D
amp's DFET rails (GPIO4/GPIO5) are set **once by EFI** and the driver
deliberately never re-drives them; a runtime-PM D3 cycle disturbs those rails and
nothing restores them on resume — the clock recovers but the amp stays dead.
Pinning `power_save=0` keeps the EFI-powered amp alive continuously.

This addresses **bug 2** (and the amp-rail half of keeping it alive).

### (C) `snd-hda-codec-cs420x`: EFI coef image + prepare fix — `install.cirrus.driver.sh`

The patched codec driver (`patch_cirrus/cs420x.c` +
`patch_cirrus/patch_cirrus_a1534_*.h`):

- Writes the **full EFI coef image** (`00=0xc4`, `03=0xbaa`, `33=0x821`,
  `34=0x3b21`, gated `0x50=0xcb`) and drops the old `charge_pump_enable`.
- Rewrites the TDM `prepare` callback to **mirror EFI's chime playback**: D0,
  set the stream up **once**, pin `0x1d` → OUT, `TDM_EN = 1`. The three
  sync-dance lines (format→0, `coef 0x01 |= 0x100`, format-restore) are
  **removed**.
- Locks the TDM playback rate to **44100 only**, so the format is always
  `0x4013` and the 48 kHz / `0x13` path can never be selected.

This addresses **bug 3** — it is the actual "silencer" fix.

### (D) `snd-hda-codec-generic`: input-path skip — `install.generic.driver.sh`

Patches `snd_hda_gen_init()` so that for the CS4208 (`vendor_id 0x10134208`) it
**skips** the input-path bring-up that latches the clock:

```c
if (codec->core.vendor_id != 0x10134208) {
        init_aamix_paths(codec);
        init_analog_input(codec);
        init_input_src(codec);
}
...
if (codec->core.vendor_id != 0x10134208)
        init_digital(codec);
```

The machine is speaker-out only, so the ADC/loopback input paths are unused.
`init_digital` is also skipped because it sends `SET_DIGI_CONVERT` to the
*shared* converter `0x0a` (the auto-parser registered it as SPDIF), which
glitches the TDM serializer — and EFI's working chime playback never touches the
digital-convert config, so leaving `0x0a` in its EFI state is correct.

This keeps `0x1f = 0x0` through bring-up, addressing **bug 1, cause 2**.

---

## Runtime routing

### EQ sink — `51-macbook81-speaker.conf`

A PipeWire `libpipewire-module-filter-chain` sink named **`MacBook_Speaker`**
(shown as `input.MacBook_Speaker`, the default sink you play to). It applies a
macOS-style "layout100" speaker EQ (preamp + high-pass + parametric bands) and
maps stereo input → 4-channel TDM output (`FL FR RL RR`) via its
`MacBook_Speaker_DSP_Out` node, which targets `MacBook_Speaker_Raw`.

### Raw speaker node — `51-mb81-rawpcm-speaker.conf`

This is the **cold-boot fix**. ACP/UCM does not know about the custom 4-channel
TDM speaker PCM (device 2), so the original design used a *static* PipeWire
`context.objects` adapter — but that adapter is instantiated **once** at daemon
start, and on a cold boot it raced the codec probe: it opened, the card wasn't
ready, it was destroyed (`OPEN→PREPARE→CLEANUP` in ~3 ms) and never retried, so
the EQ chain dumped into a dead end → silence. The workaround was a manual
`systemctl --user restart wireplumber pipewire`.

The fix switches the PCH card to **raw-PCM mode** (`api.alsa.use-acp = false`) and
lets **WirePlumber** create one node per PCM device **event-driven**, so the
speaker node comes up whenever the card appears — surviving the race:

- device 0 playback → analog / headphone (kept)
- device 0 capture → internal mic (kept)
- device 1 playback → SPDIF / Digital — **disabled** (shares converter `0x0a`,
  clobbers the speaker stream tag, no physical jack)
- device 2 playback → CS4208 TDM speaker → renamed **`MacBook_Speaker_Raw`**,
  pinned S16LE / 44100 / 4ch / `FL FR RL RR`, pause-on-idle off, suspend off.

Validated on a real cold reboot: PipeWire/WirePlumber start **once** at login and
the speaker node comes up on its own — zero manual restart.

---

## Putting it together: the boot sequence that works

1. Normal boot. EFI inits the codec + amp (chime plays); link left running.
2. udev autoloads the patched `snd-hda-intel` with `single_cmd=1 power_save=0`.
3. It attaches to the **live EFI link without reset** (`0x1f` stays `0x0`) and
   enumerates the CS4208 over the **immediate-command** path.
4. `snd-hda-codec-generic` brings up the codec **skipping the input paths**
   (`0x1f` stays `0x0`).
5. `snd-hda-codec-cs420x` writes the **EFI coef image** and, on play, programs
   the TDM stream **the way EFI does** (no sync-dance, locked 44100/`0x4013`).
6. WirePlumber creates `MacBook_Speaker_Raw` (device 2) event-driven; the
   PipeWire EQ sink `input.MacBook_Speaker` feeds it 4-channel TDM.
7. Audio plays — `coef 0x1f = 0x0` end to end, amp kept powered by `power_save=0`.

Remove any one part and it goes silent:

| Remove | Failure |
|---|---|
| A (no-reset) | link reset latches `0x1f = 0x400` |
| B (single_cmd) | CORB/RIRB wedges, codec never enumerates |
| C (coef/prepare) | clock fine, but TDM serializer de-synced → silent |
| D (input-skip) | `gen_init` re-latches `0x1f = 0x400` |
| power_save=0 | first play works, then D3 kills the amp rails → silent |
| raw-PCM node | EQ chain has no sink target on cold boot → silent until pw restart |

---

## Diagnostic notes for the future

- **Always check `coef 0x1f` first.** `0x0` = clock good; `0x400` = latched
  fault. It tells you instantly whether a boot is in the clock-good regime.
- The latch is **asymmetric** — don't waste time trying to "heal" a `0x400`
  state with the driver bound; it cannot be done. Reboot and prevent it.
- The **MMIO immediate-command interface** (ICOI/ICII/ICIS) is reliable on this
  codec when CORB/RIRB is not; that's why `single_cmd=1` matters and why the
  driverless capture/recover tools always worked.
- The **EFI chime is the ground-truth reference** for every codec register: dump
  driverlessly right after the chime, diff against the driver.
