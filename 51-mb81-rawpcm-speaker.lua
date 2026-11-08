-- MacBook8,1 (CS4208) raw-PCM speaker node for WirePlumber 0.4.x
--
-- WirePlumber 0.5+ reads the SPA-JSON file 51-mb81-rawpcm-speaker.conf.
-- Mint 22.x / Ubuntu 24.04 ship WirePlumber 0.4.17, which has no .conf support
-- and reads main.lua.d/*.lua instead, so this file is the same set of rules in
-- the 0.4 rule format. Having both installed is harmless: each WirePlumber
-- version reads only the one it understands.
--
-- Raw-PCM node names are identical in 0.4 and 0.5:
--   alsa_output.pci-0000_00_1b.0.playback.<pcm>.<subdevice>
-- and the jack-switch script / saved defaults refer to those names.

alsa_monitor.rules = {
  {
    -- ACP/UCM does not know about the CS4208 TDM speaker PCM (device 2), so
    -- expose the card as raw PCM nodes, one per PCM device.
    matches = { { { "device.name", "matches", "alsa_card.pci-0000_00_1b.0" } } },
    apply_properties = { ["api.alsa.use-acp"] = false },
  },
  {
    -- device 1 = Digital/SPDIF. It shares converter 0x0a with the speaker and
    -- clobbers its stream tag; there is no physical SPDIF jack.
    matches = { { { "node.name", "equals", "alsa_output.pci-0000_00_1b.0.playback.1.0" } } },
    apply_properties = { ["node.disabled"] = true },
  },
  {
    -- device 0 playback = analog headphone jack. Raw-PCM mode names this
    -- "Built-in Audio"; give it a clear name.
    matches = { { { "node.name", "equals", "alsa_output.pci-0000_00_1b.0.playback.0.0" } } },
    apply_properties = { ["node.description"] = "Headphones" },
  },
  {
    -- device 0 capture = internal mic, or the headset mic when plugged in
    matches = { { { "node.name", "equals", "alsa_input.pci-0000_00_1b.0.capture.0.0" } } },
    apply_properties = { ["node.description"] = "Microphone" },
  },
  {
    -- device 2 = TDM speaker; this is the sink the EQ chain feeds.
    matches = { { { "node.name", "equals", "alsa_output.pci-0000_00_1b.0.playback.2.0" } } },
    apply_properties = {
      ["node.name"] = "MacBook_Speaker_Raw",
      ["node.description"] = "MacBook Speaker (Raw)",
      ["audio.format"] = "S16LE",
      ["audio.rate"] = 44100,
      ["audio.channels"] = 4,
      ["audio.position"] = "FL,FR,RL,RR",
      ["api.alsa.period-size"] = 1024,
      ["api.alsa.headroom"] = 1024,
      ["node.pause-on-idle"] = false,
      ["session.suspend-timeout-seconds"] = 0,
    },
  },
}
