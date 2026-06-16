// MacBook 8,1 (A1534 early 2015) speaker setup
// Based on EFI codec dump + AppleHDA.kext layout100 analysis
// Codec: CS4208, Subsystem: 0x106b6400, PCI: 8086:7270
// Amp: built-in class-D via TDM (no I2C needed)
// TDM: Bus 1, SRMultiple=256, 4 channels, offsets [32,96,0,128]
//
// DFET / GPIO mapping (from layout100 plist):
//   GPIO0 = MuteGPIO      (LOW = unmuted, HIGH = muted)
//   GPIO4 = CHDFETControl  (CH DFET, charge pump power)
//   GPIO5 = USDFETControl  (US DFET, upstream supply power)
//   AmpPreDelay  = 75ms (after DFET on, before unmute)
//   AmpPostDelay = 12ms (after mute, before DFET off)

#ifndef AC_VERB_GET_STRIPE_CONTROL
#define AC_VERB_GET_STRIPE_CONTROL 0x0f24
#endif

#ifndef AC_VERB_SET_STRIPE_CONTROL
#define AC_VERB_SET_STRIPE_CONTROL 0x0724
#endif

/*
 * CS4208 Cirrus-specific GPIO verbs
 * Standard HDA GPIO verbs (0x710/0x714) map to DIFFERENT registers on CS4208!
 * Confirmed by disassembling macOS AppleHDA:
 *   GPIO Enable:    standard 0x710 → Cirrus 0x716
 *   GPIO Direction: standard 0x714 → Cirrus 0x717
 *   GPIO Data:      0x715 is the same for both
 */
#define CS4208_VERB_SET_GPIO_MASK	0x718
#define CS4208_VERB_SET_GPIO_ENABLE	0x716
#define CS4208_VERB_SET_GPIO_DIR	0x717
#define CS4208_VERB_GET_GPIO_MASK	0xF18
#define CS4208_VERB_GET_GPIO_ENABLE	0xF16
#define CS4208_VERB_GET_GPIO_DIR	0xF17
#define CS4208_VERB_SET_TDM_ENABLE	0x7f0
#define CS4208_VERB_SET_VENDOR_STATE	0x7f1
#define CS4208_VERB_GET_TDM_ENABLE	0xff0
#define CS4208_VERB_GET_VENDOR_STATE	0xff1

static unsigned int mb81_cached_coef_index;
static unsigned int mb81_saved_coef_index;
static unsigned int mb81_saved_7f0;
static unsigned int mb81_saved_7f1;
static bool mb81_have_power_rail_state;

static void mb81_write_coef(struct hda_codec *codec,
			    unsigned int idx, unsigned int coef)
{
	mb81_cached_coef_index = idx;
	snd_hda_codec_write(codec, CS4208_VENDOR_NID, 0,
			    AC_VERB_SET_COEF_INDEX, idx);
	snd_hda_codec_write(codec, CS4208_VENDOR_NID, 0,
			    AC_VERB_SET_PROC_COEF, coef);
}

static unsigned int mb81_read_coef(struct hda_codec *codec, unsigned int idx)
{
	mb81_cached_coef_index = idx;
	snd_hda_codec_write(codec, CS4208_VENDOR_NID, 0,
			    AC_VERB_SET_COEF_INDEX, idx);
	return snd_hda_codec_read(codec, CS4208_VENDOR_NID, 0,
				  AC_VERB_GET_PROC_COEF, 0);
}

static void mb81_update_coef(struct hda_codec *codec,
			     unsigned int idx, unsigned int mask,
			     unsigned int bits)
{
	unsigned int val = mb81_read_coef(codec, idx);
	val = (val & ~mask) | bits;
	mb81_write_coef(codec, idx, val);
}

static void mb81_write_all_coefficients(struct hda_codec *codec)
{
	/* All non-zero coefficients from EFI dump */
	mb81_write_coef(codec, 0x00, 0x00c4);
	mb81_write_coef(codec, 0x02, 0x003a);
	mb81_write_coef(codec, 0x03, 0x0baa);
	mb81_write_coef(codec, 0x04, 0x0c04);
	mb81_write_coef(codec, 0x05, 0x1000);
	mb81_write_coef(codec, 0x06, 0x9f9f);
	mb81_write_coef(codec, 0x07, 0x9f9f);
	mb81_write_coef(codec, 0x08, 0x1f1f);
	mb81_write_coef(codec, 0x09, 0x1f1f);
	mb81_write_coef(codec, 0x0a, 0x1f1f);
	mb81_write_coef(codec, 0x0b, 0x1f1f);
	mb81_write_coef(codec, 0x0c, 0x9f9f);
	mb81_write_coef(codec, 0x0d, 0x9f9f);
	mb81_write_coef(codec, 0x0e, 0x9f9f);
	mb81_write_coef(codec, 0x0f, 0x9f9f);
	mb81_write_coef(codec, 0x10, 0x1f1f);
	mb81_write_coef(codec, 0x11, 0x1f1f);
	mb81_write_coef(codec, 0x12, 0x1f1f);
	mb81_write_coef(codec, 0x13, 0x1f1f);
	mb81_write_coef(codec, 0x18, 0x0400);
	mb81_write_coef(codec, 0x19, 0x0088);
	mb81_write_coef(codec, 0x1a, 0x00f3);
	mb81_write_coef(codec, 0x1b, 0x0002);
	mb81_write_coef(codec, 0x1c, 0x0103);
	mb81_write_coef(codec, 0x1d, 0x0bdf);
	mb81_write_coef(codec, 0x1e, 0x016d);
	mb81_write_coef(codec, 0x22, 0x0080);
	mb81_write_coef(codec, 0x25, 0x0001);
	mb81_write_coef(codec, 0x33, 0x0821); /* EFI chime value (was 0x4493) */
	mb81_write_coef(codec, 0x34, 0x3b21); /* EFI chime value (was 0x1b13) */
	mb81_write_coef(codec, 0x36, 0x0034);
}

/*
 * Windows CONF_0807 InitVerbs — only the coefficients the Windows driver sets.
 * Does NOT include EFI dump values or macOS-specific verbs.
 *
 * NOTE: coeff 0x00 uses update_coef to PRESERVE bits [3:0] which include:
 *   bit 2 = set by macOS initForNodeID (required for TDM)
 *   bit 3 = I2C master enable (must not be accidentally set)
 */
static __maybe_unused void mb81_write_win_coefficients(struct hda_codec *codec)
{
	mb81_update_coef(codec, 0x00, 0xfff0, 0x0080); /* rate bits only, preserve [3:0] */
	mb81_write_coef(codec, 0x04, 0x0C04); /* TX1 ch0: slot 4, ch1: slot 12 */
	mb81_write_coef(codec, 0x05, 0x1000); /* TX1 ch2: slot 0, ch3: slot 16 */
	mb81_write_coef(codec, 0x1D, 0x0BF6); /* DC detect level = 36h */
	mb81_write_coef(codec, 0x33, 0x4493); /* A/C Gat, A2/C Inv, A1/A2/C ICS */
	mb81_write_coef(codec, 0x34, 0x1B13); /* A1/A2/C Enable, A threshold=250mV */
	mb81_write_coef(codec, 0x36, 0x0034); /* SP1 slew rate = slow */
}

static void mb81_dfet_power_up(struct hda_codec *codec)
{
	/*
	 * EFI / driverless WORKING scheme: the codec drives ONLY GPIO0 (the
	 * speaker un-mute). GPIO4/GPIO5 (the class-D amp's CH/US DFET supply
	 * rails) are LEFT EXACTLY AS EFI SET THEM at chime time — never enabled
	 * as outputs, never driven.
	 *
	 * The previous code enabled GPIO4/5 and started by writing 0x30
	 * (GPIO4=GPIO5=HIGH = both DFET rails OFF) before turning them back on.
	 * That POWER-CYCLES the class-D amp and loses EFI's one-shot amp
	 * configuration (volatile), which can only be re-established by an EFI
	 * re-init (reboot / re-chime). The result was permanent silence that no
	 * later GPIO/coef/DIGEN change could recover — matching every failed
	 * end-to-end test. EFI's reference (GPIO enable mask 0x09) and the
	 * driverless tone (which only ever toggled GPIO0) both proved the amp
	 * plays as long as its rails are never cut. So: NEVER touch GPIO4/5.
	 */
	snd_hda_codec_write(codec, codec->core.afg, 0,
			    CS4208_VERB_SET_GPIO_MASK, 0x01);  /* only GPIO0 writable */
	snd_hda_codec_write(codec, codec->core.afg, 0,
			    CS4208_VERB_SET_GPIO_DIR, 0x01);   /* GPIO0 output */
	snd_hda_codec_write(codec, codec->core.afg, 0,
			    CS4208_VERB_SET_GPIO_ENABLE, 0x09); /* GPIO0 out + GPIO3 in (EFI) */

	/* Unmute speaker: GPIO0 HIGH. Rails stay as EFI left them (on). */
	snd_hda_codec_write(codec, codec->core.afg, 0,
			    AC_VERB_SET_GPIO_DATA, 0x01);
}

static void mb81_dfet_power_down(struct hda_codec *codec)
{
	/* Step 1: Mute speaker (GPIO0 LOW) */
	snd_hda_codec_write(codec, codec->core.afg, 0,
			    AC_VERB_SET_GPIO_DATA, 0x00);

	/* AmpPostDelay: per-DFET delay is 0 in plist */

	/* Step 2: CH DFET off (GPIO4 HIGH) */
	snd_hda_codec_write(codec, codec->core.afg, 0,
			    AC_VERB_SET_GPIO_DATA, 0x10);

	/* Step 3: US DFET off (GPIO5 HIGH) */
	snd_hda_codec_write(codec, codec->core.afg, 0,
			    AC_VERB_SET_GPIO_DATA, 0x30);
}

static void mb81_apply_software_workarounds(struct hda_codec *codec)
{
	/*
	 * From AppleHDAFunctionGroupCS4208::applyCodecSpecificSoftwareWorkarounds
	 * Unlocks hidden registers behind a test-mode gate.
	 */
	mb81_write_coef(codec, 0x40, 0x9999); /* enable test mode */
	mb81_write_coef(codec, 0x50, 0x00cb); /* EFI chime value (was 0x8b) */
	mb81_write_coef(codec, 0x40, 0x0000); /* disable test mode */
}

static __maybe_unused void mb81_charge_pump_enable(struct hda_codec *codec)
{
	/*
	 * From AppleHDAFunctionGroupCS4208::requestCPset
	 * Coeff 0 bit 14 (0x4000) = charge pump enable.
	 * macOS ref-counts this; we just enable it.
	 */
	mb81_update_coef(codec, 0x00, 0x4000, 0x4000);
	usleep_range(1000, 1500); /* macOS waits 1ms after CP change */
}

static void mb81_power_rail_save(struct hda_codec *codec)
{
	mb81_saved_coef_index = mb81_cached_coef_index;
	mb81_saved_7f0 = snd_hda_codec_read(codec, CS4208_VENDOR_NID, 0,
					    CS4208_VERB_GET_TDM_ENABLE, 0);
	mb81_saved_7f1 = snd_hda_codec_read(codec, CS4208_VENDOR_NID, 0,
					    CS4208_VERB_GET_VENDOR_STATE, 0);
	mb81_have_power_rail_state = true;
}

static void mb81_power_rail_restore(struct hda_codec *codec)
{
	if (!mb81_have_power_rail_state)
		return;

	snd_hda_codec_write(codec, CS4208_VENDOR_NID, 0,
			    AC_VERB_SET_COEF_INDEX, mb81_saved_coef_index & 0xffff);
	snd_hda_codec_write(codec, CS4208_VENDOR_NID, 0,
			    CS4208_VERB_SET_TDM_ENABLE, mb81_saved_7f0 & 0xffff);
	snd_hda_codec_write(codec, CS4208_VENDOR_NID, 0,
			    CS4208_VERB_SET_VENDOR_STATE, mb81_saved_7f1 & 0xffff);
}

static void mb81_sync_converters(struct hda_codec *codec, unsigned int strm)
{
	/*
	 * From AppleHDAFunctionGroupCS4208::syncConverters
	 *
	 * The sync dance: disable converters, update routing bitmask
	 * in coeff 1, then re-enable converters. This ensures they
	 * start in lockstep.
	 *
	 * Coeff 1 bit mapping:
	 *   bit 0 = NID 0x02 (analog DAC)
	 *   bit 8 = NID 0x0a (TDM converter 0)
	 *   bit 9 = NID 0x0b (TDM converter 1)
	 */
	unsigned int coef1;
	unsigned int fmt_0a;

	/* Save current format on 0x0a */
	fmt_0a = snd_hda_codec_read(codec, 0x0a, 0,
				    AC_VERB_GET_STREAM_FORMAT, 0);

	/* Disable converter 0x0a by setting format to 0 */
	snd_hda_codec_write(codec, 0x0a, 0,
			    AC_VERB_SET_STREAM_FORMAT, 0);

	/* Read coeff 1, set bit 8 for converter 0x0a active */
	coef1 = mb81_read_coef(codec, 0x01);
	coef1 |= 0x0100; /* bit 8 = NID 0x0a */
	mb81_write_coef(codec, 0x01, coef1);

	/* Restore format on 0x0a */
	snd_hda_codec_write(codec, 0x0a, 0,
			    AC_VERB_SET_STREAM_FORMAT, fmt_0a);
}

static int setup_macbook81(struct hda_codec *codec)
{
	codec_dbg(codec, "setup_macbook81 (Windows-pure) begin\n");

	/* AFG: PS-Set = D0 */
	snd_hda_codec_write(codec, codec->core.afg, 0,
			    AC_VERB_SET_POWER_STATE, 0x00);

	/* VPW: proc on */
	snd_hda_codec_write(codec, CS4208_VENDOR_NID, 0,
			    AC_VERB_SET_PROC_STATE, 0x01);

	/* macOS clearRegisters() — reset internal state before init */
	mb81_write_coef(codec, 0x22, 0x0080);
	mb81_write_coef(codec, 0x2a, 0x0000);

	/* macOS initForNodeID() follow-up vendor-widget init */
	mb81_update_coef(codec, 0x03, 0xf000, 0x0000);
	mb81_update_coef(codec, 0x01, 0x03ff, 0x0000);
	mb81_update_coef(codec, 0x00, 0x0004, 0x0004);

	/* Full EFI chime coefficient image (clock-locked state the codec
	 * leaves EFI boot in). Writing the Windows subset + charge-pump bit
	 * instead knocks the codec PLL out of lock -> coef 0x1f latches 0x400
	 * and the TDM link goes silent. */
	mb81_write_all_coefficients(codec);

	/* Software workarounds (test mode gate — same in Windows) */
	mb81_apply_software_workarounds(codec);

	/*
	 * Widget caps override from Windows INF:
	 * n0AWidgetCaps = 0x00042631 (CCE=1, 4ch max)
	 * Original is 0x46631 (CCE=3, 8ch).
	 */
	snd_hda_override_wcaps(codec, 0x0a, 0x00042631); /* CCE=1, 4ch, Digital */

	/*
	 * Pin config overrides: CONF_08xx base + CONF_0807 layered.
	 * Use snd_hda_codec_set_pincfg() to update kernel cache so
	 * the auto-parser sees our overrides.
	 *
	 * For pins where INF only sets byte 3, we read current config
	 * and replace byte 3.
	 */
#define MB81_PIN_SET_BYTE3(nid, b3) \
	snd_hda_codec_set_pincfg(codec, nid, \
		(snd_hda_codec_get_pincfg(codec, nid) & 0x00ffffff) | ((b3) << 24))

	/* HP (0x10): ASSN=F, COL=gray, DD=HP, CTYP=combo, PCON=jack, LOC=right */
	snd_hda_codec_set_pincfg(codec, 0x10, 0x042b20f0);

	/* LO1-LO4 (0x11-0x14): PCON=n/c, LOC=int */
	MB81_PIN_SET_BYTE3(0x11, 0x50);
	MB81_PIN_SET_BYTE3(0x12, 0x50);
	MB81_PIN_SET_BYTE3(0x13, 0x50);
	MB81_PIN_SET_BYTE3(0x14, 0x50);

	/* MI1-MI2 (0x15-0x16): PCON=n/c, LOC=mob/lid/ins */
	MB81_PIN_SET_BYTE3(0x15, 0x77);
	MB81_PIN_SET_BYTE3(0x16, 0x77);

	/* LI (0x17): PCON=n/c, LOC=prim/left */
	MB81_PIN_SET_BYTE3(0x17, 0x43);

	/* HS (0x18): ASSN=5, COL=gray, DD=MI, CTYP=combo, PCON=jack, LOC=right */
	snd_hda_codec_set_pincfg(codec, 0x18, 0x04ab2050);

	/* DM1 (0x19): ASSN=7, DD=MI, CTYP=unkn, PCON=fixed, LOC=int */
	snd_hda_codec_set_pincfg(codec, 0x19, 0x90a00070);

	/* DM2-DM4 (0x1a-0x1c): PCON=n/c, LOC=mob/lid/ins */
	MB81_PIN_SET_BYTE3(0x1a, 0x77);
	MB81_PIN_SET_BYTE3(0x1b, 0x77);
	MB81_PIN_SET_BYTE3(0x1c, 0x77);

	/* TX1 (0x1d): ASSN=1, DD=SPDO, CTYP=unkn, PCON=fixed, LOC=int */
	snd_hda_codec_set_pincfg(codec, 0x1d, 0x90400010);

	/* TX2 (0x1e): PCON=n/c, LOC=int */
	MB81_PIN_SET_BYTE3(0x1e, 0x50);

	/* RX1-RX2 (0x1f-0x20): PCON=n/c, LOC=int */
	MB81_PIN_SET_BYTE3(0x1f, 0x50);
	MB81_PIN_SET_BYTE3(0x20, 0x50);

	/* SPDO (0x21): PCON=n/c, LOC=prim/left */
	MB81_PIN_SET_BYTE3(0x21, 0x43);

	/* SPDI (0x22): PCON=n/c, LOC=prim/left */
	MB81_PIN_SET_BYTE3(0x22, 0x43);

#undef MB81_PIN_SET_BYTE3

	/* GPIO: EFI scheme — only GPIO0 driven (un-mute); GPIO4/GPIO5 (amp DFET
	 * rails) left untouched so the class-D amp is never power-cycled. See
	 * mb81_dfet_power_up() for the rationale. */
	snd_hda_codec_write(codec, codec->core.afg, 0,
			    CS4208_VERB_SET_GPIO_MASK, 0x01);  /* only GPIO0 writable */
	snd_hda_codec_write(codec, codec->core.afg, 0,
			    CS4208_VERB_SET_GPIO_DIR, 0x01);  /* GPIO0 output */
	snd_hda_codec_write(codec, codec->core.afg, 0,
			    CS4208_VERB_SET_GPIO_ENABLE, 0x09); /* GPIO0 out + GPIO3 in (EFI) */

	/* Enable TDM output. clearRegisters() (coef 0x22=0x0080) resets this
	 * to 0 — must be explicitly re-armed after every init sequence. */
	snd_hda_codec_write(codec, CS4208_VENDOR_NID, 0,
			    CS4208_VERB_SET_TDM_ENABLE, 1);

	codec_dbg(codec, "setup_macbook81 done\n");
	return 0;
}

static int play_macbook81(struct hda_codec *codec)
{
	codec_dbg(codec, "play_macbook81 (Windows-pure) begin\n");

	/* AFG D0 */
	snd_hda_codec_write(codec, codec->core.afg, 0,
			    AC_VERB_SET_POWER_STATE, 0x00);

	/* VPW proc on (re-ensure after auto-parser) */
	snd_hda_codec_write(codec, CS4208_VENDOR_NID, 0,
			    AC_VERB_SET_PROC_STATE, 0x01);

	/* Re-apply full EFI coefficient image (auto-parser may overwrite) */
	mb81_write_all_coefficients(codec);

	/* Software workarounds */
	mb81_apply_software_workarounds(codec);

	/* Pin 0x1d: connect to converter 0x0a, enable output */
	snd_hda_codec_write(codec, 0x1d, 0,
			    AC_VERB_SET_CONNECT_SEL, 0x00);
	snd_hda_codec_write(codec, 0x1d, 0,
			    AC_VERB_SET_PIN_WIDGET_CONTROL, PIN_OUT);

	codec_dbg(codec, "play_macbook81 done\n");
	return 0;
}
