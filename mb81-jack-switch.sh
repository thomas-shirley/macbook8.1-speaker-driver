#!/bin/bash
# mb81-jack-switch — MacBook8,1 (CS4208) headphone-jack auto-switch.
#
# WHY THIS EXISTS
# ---------------
# The CS4208's headphone DAC (codec converter 0x02) and the TDM speaker
# converter (0x0a) collide on the same HDA stream tag. Opening the headphone
# output grabs the tag the speaker is using, so the codec stops routing the
# speaker's DMA to the class-D amp and the speaker goes silent (headphones play
# fine). The raw speaker node is pinned open (the cold-boot fix:
# session.suspend-timeout-seconds=0 / node.pause-on-idle=false), so it never
# closes and re-claims a clean tag on its own.
#
# Normal PipeWire/WirePlumber jack switching is also unavailable here because the
# card runs in raw-PCM mode (api.alsa.use-acp = false) for the custom 4-channel
# TDM speaker device — there are no ACP ports/routes to drive auto-switching.
#
# So this watcher reacts to the ALSA "Headphone Jack" control directly:
#   plugged   -> default sink = headphone analog output
#   unplugged -> re-prepare the speaker (restart WirePlumber, which closes and
#                reopens the raw speaker PCM so converter 0x0a gets a clean tag)
#                then default sink = speaker EQ
#
# Runs as a systemd --user service (it needs the user's PipeWire/WirePlumber bus).
# Overridable via env: MB81_CARD_ID, MB81_HP_SINK, MB81_SPK_SINK.

set -u

CARD_ID="${MB81_CARD_ID:-PCH}"   # /proc/asound id of the CS4208 controller
HP_SINK="${MB81_HP_SINK:-alsa_output.pci-0000_00_1b.0.playback.0.0}"
SPK_SINK="${MB81_SPK_SINK:-input.MacBook_Speaker}"

log() { printf 'mb81-jack-switch: %s\n' "$*"; }

# ALSA card index for the CS4208 (e.g. "HDA Intel PCH" -> 0).
card_index() {
    awk -v id="$CARD_ID" '$0 ~ ("HDA Intel " id "$") {print $1; exit}' \
        /proc/asound/cards
}

# numid of the "Headphone Jack" boolean control on card $1.
jack_numid() {
    amixer -c "$1" controls 2>/dev/null \
        | sed -n "s/numid=\([0-9]*\).*name='Headphone Jack'.*/\1/p" | head -1
}

# Jack state on card $1, control $2: prints "on" (plugged) or "off" (unplugged).
jack_state() {
    amixer -c "$1" cget numid="$2" 2>/dev/null \
        | sed -n 's/.*: values=\(on\|off\).*/\1/p' | head -1
}

# Set the default audio sink by node.name (same metadata key wpctl writes).
set_default() {
    pw-metadata -n default 0 default.configured.audio.sink \
        "{ \"name\": \"$1\" }" >/dev/null 2>&1
}

node_exists() {
    pw-cli ls Node 2>/dev/null | grep -q "node.name = \"$1\""
}

apply() {  # $1 = on|off
    if [[ "$1" == on ]]; then
        log "headphones plugged -> $HP_SINK"
        set_default "$HP_SINK"
    else
        log "headphones unplugged -> re-prepare speaker + $SPK_SINK"
        # Restarting WirePlumber closes and reopens the raw speaker PCM so the
        # codec converter 0x0a re-claims a free stream tag (the tag clobber the
        # headphone output caused cannot be undone any other way while the node
        # is pinned open). This is the proven recovery.
        systemctl --user restart wireplumber
        # Wait for the raw speaker node to be recreated before pinning default.
        for _ in $(seq 1 24); do
            node_exists "$SPK_SINK" && break
            sleep 0.25
        done
        set_default "$SPK_SINK"
    fi
}

CARD="$(card_index)"
[[ -z "$CARD" ]] && { log "CS4208 card ($CARD_ID) not found; exiting"; exit 1; }
NUMID="$(jack_numid "$CARD")"
[[ -z "$NUMID" ]] && { log "Headphone Jack control not found on card $CARD; exiting"; exit 1; }
log "watching card $CARD 'Headphone Jack' (numid=$NUMID)"

# Startup: align the default sink with the current jack state WITHOUT a
# re-prepare. The speaker already works at boot, and a WirePlumber restart here
# would bounce audio on every login/service-start. The re-prepare only runs on
# an actual unplug *transition* below.
last="$(jack_state "$CARD" "$NUMID")"
case "$last" in
    on) log "startup: headphones present -> $HP_SINK"; set_default "$HP_SINK" ;;
    *)  log "startup: speakers -> $SPK_SINK";          set_default "$SPK_SINK" ;;
esac

# React to control changes. alsactl emits a line on every control event on the
# card; re-read the jack and act only when its state actually changed. (The pipe
# runs the loop in a subshell, which keeps its own copy of $last across events.)
alsactl monitor "hw:$CARD" 2>/dev/null | while read -r _; do
    s="$(jack_state "$CARD" "$NUMID")"
    [[ -z "$s" || "$s" == "$last" ]] && continue
    last="$s"
    apply "$s"
done

# alsactl monitor exited (card gone / suspend); let systemd restart us.
log "alsactl monitor exited"
exit 1
