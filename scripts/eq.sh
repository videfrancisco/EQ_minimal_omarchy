#!/usr/bin/env bash
# eq — control the PipeWire "Equalizer" sink used by the francisco.eq
# Omarchy plugin. Twelve frequency-range bands spanning 20 Hz - 20 kHz, built
# from a low shelf at 40 Hz, peaking filters at 60-14000 Hz and a high shelf at
# 16 kHz. Gains are stored in the filter-chain config so they survive reboots,
# and applied live through pw-cli.
set -euo pipefail

CONF_DIR="$HOME/.config/pipewire/pipewire.conf.d"
# Legacy file name and node names are kept so existing WirePlumber routing to
# the "Equalizer" sink keeps working across the 6 -> 12 band upgrade.
CONF="$CONF_DIR/eq6.conf"
STATE_DIR="$HOME/.config/omarchy"
STATE="$STATE_DIR/eq.json"
PRESETS="$STATE_DIR/eq-presets.json"
SINK_NAME="effect_input.eq6"
FREQS=(40 60 120 240 480 960 1800 3600 6400 10000 14000 16000)
QS=(0.707 1.410 1.410 1.410 1.410 1.410 1.410 1.410 1.410 1.410 1.410 0.707)
# Each label is the frequency range the band acts on; FREQS holds the filter
# frequency at the centre (or shelf corner) of that range.
LABELS=("20-40" "40-80" "80-160" "160-320" "320-640" "640-1.2k" "1.2k-2.5k" "2.5k-5k" "5k-8k" "8k-12k" "12k-16k" "16k-20k")
BANDS=12
MIN_GAIN=-12.0
MAX_GAIN=12.0

mkdir -p "$CONF_DIR" "$STATE_DIR"

die() { echo "eq: $*" >&2; exit 1; }
clamp_gain() { awk -v g="$1" -v lo="$MIN_GAIN" -v hi="$MAX_GAIN" 'BEGIN{ if (g<lo) g=lo; if (g>hi) g=hi; printf "%.1f", g }'; }

# Creates the state file, upgrading a legacy 6-band curve to 12 bands by
# spreading each old range over the new ranges it covered, and makes sure the
# spectrum preference exists (a missing key means the spectrum is on).
ensure_state() {
  [[ -f $STATE ]] || { printf '{"gains":[0.0,0.0,0.0,0.0,0.0,0.0,0.0,0.0,0.0,0.0,0.0,0.0],"spectrum":true}' > "$STATE"; return; }
  local tmp n
  n=$(jq -r '.gains | length' "$STATE" 2>/dev/null || echo 0)
  if [[ $n == 6 ]]; then
    tmp=$(mktemp "$STATE_DIR/.eq.json.XXXXXX")
    jq '{gains: [.gains[0], .gains[0], .gains[1], .gains[1], .gains[2], .gains[3],
                  .gains[3], .gains[4], .gains[5], .gains[5], .gains[5], .gains[5]],
          spectrum: (if .spectrum == null then true else .spectrum end)}' \
      "$STATE" > "$tmp"
    mv "$tmp" "$STATE"
  elif [[ $n == "$BANDS" ]]; then
    # Spectrum key migration only — never touches the saved gains.
    jq -e '.spectrum != null' "$STATE" >/dev/null 2>&1 && return
    tmp=$(mktemp "$STATE_DIR/.eq.json.XXXXXX")
    jq '.spectrum = true' "$STATE" > "$tmp"
    mv "$tmp" "$STATE"
  else
    tmp=$(mktemp "$STATE_DIR/.eq.json.XXXXXX")
    jq '.gains = [0.0,0.0,0.0,0.0,0.0,0.0,0.0,0.0,0.0,0.0,0.0,0.0]
        | .spectrum = (if .spectrum == null then true else .spectrum end)' \
      "$STATE" > "$tmp"
    mv "$tmp" "$STATE"
  fi
}

# Node id of the Equalizer sink in the running graph, empty when absent.
find_sink() {
  pw-dump 2>/dev/null | jq -r --arg n "$SINK_NAME" '
    [.[] | select(.info.props["node.name"] == $n)][0].id // empty' | head -1
}

# Live gains (one per band) from the running sink, empty when absent.
read_live_gains() {
  pw-dump 2>/dev/null | jq -r --arg n "$SINK_NAME" '
    ([.[] | select(.info.props["node.name"] == $n)][0].info.params.Props // [])[]
    | .params | . as $p | range(0; length; 2) as $i
    | select($p[$i] | endswith(":Gain"))
    | "\($p[$i+1])"' | head -n "$BANDS"
}

gains_from_state() { jq -r '.gains[]' "$STATE"; }

# Writes the filter-chain fragment with the stored gains. PipeWire reads this
# on start, so the saved curve is restored on every boot.
write_conf() {
  local nodes="" links="" i n filter label
  mapfile -t gs < <(gains_from_state)
  (( ${#gs[@]} == BANDS )) || die "state file has invalid gains"
  for (( i = 0; i < BANDS; i++ )); do
    n=$(( i + 1 ))
    filter=${FREQS[$i]}
    if (( i == 0 )); then
      label=bq_lowshelf
    elif (( i == BANDS - 1 )); then
      label=bq_highshelf
    else
      label=bq_peaking
    fi
    nodes+="                    { type  = builtin
                      name  = eq_band_$n
                      label = $label
                      control = { \"Freq\" = $filter.0 \"Q\" = ${QS[$i]} \"Gain\" = ${gs[$i]} } }
"
    if (( i > 0 )); then
      links+="                    { output = \"eq_band_$(( n - 1 )):Out\" input = \"eq_band_${n}:In\" }
"
    fi
  done
  cat > "$CONF" <<EOF
# Frequency-range (12-band) sink equalizer for the francisco.eq Omarchy plugin.
# Managed by the \`eq\` command — edit gains with \`eq set <band> <dB>\`.
# Gains below are restored on PipeWire start.

context.modules = [
    { name = libpipewire-module-filter-chain
        args = {
            node.description = "Equalizer"
            media.name       = "Equalizer"
            filter.graph = {
                nodes = [
${nodes}                ]
                links = [
${links}                ]
            }
            audio.channels = 2
            audio.position = [ FL FR ]
            capture.props = {
                node.name   = "$SINK_NAME"
                media.class = Audio/Sink
            }
            playback.props = {
                node.name    = "effect_output.eq6"
                node.passive = true
            }
        }
    }
]
EOF
}

# Restarts PipeWire when the running sink still has a different number of bands
# than the config asks for (e.g. right after the 6 -> 12 band upgrade). Doing
# this here keeps the live sink in sync with the saved curve.
ensure_chain() {
  local node count
  node=$(find_sink)
  [[ -n $node ]] || return 0
  count=$(read_live_gains | wc -l)
  (( count == BANDS )) && return 0
  systemctl --user restart pipewire.service
  for _ in $(seq 1 25); do
    [[ -n $(find_sink) ]] && break
    sleep 0.2
  done
}

# Applies all stored gains to the running sink in one call.
apply_live() {
  local node args="" g i
  node=$(find_sink)
  [[ -n $node ]] || return 0
  mapfile -t gs < <(gains_from_state)
  for (( i = 0; i < BANDS; i++ )); do
    (( i > 0 )) && args+=", "
    args+="\"eq_band_$((i + 1)):Gain\", ${gs[$i]}"
  done
  pw-cli set-param "$node" Props "{ \"params\": [ $args ] }" >/dev/null
}

set_state_gains() {
  local tmp
  tmp=$(mktemp "$STATE_DIR/.eq.json.XXXXXX")
  jq "$@" "$STATE" > "$tmp" && mv "$tmp" "$STATE"
}

# Named curves live in one small JSON file next to the state file:
#   {"presets": [{"name": "Flat", "gains": [0, ...]}]}
ensure_presets() {
  if [[ ! -f $PRESETS ]] || ! jq -e '.presets | type == "array"' "$PRESETS" >/dev/null 2>&1; then
    printf '{"presets":[]}' > "$PRESETS"
  fi
}

write_presets() {
  local tmp
  tmp=$(mktemp "$STATE_DIR/.eq-presets.XXXXXX")
  jq "$@" "$PRESETS" > "$tmp" && mv "$tmp" "$PRESETS"
}

# Trims a preset name and rejects anything that could not round-trip through
# the JSON file or the panel: empty, over 40 chars, slashes, control chars.
preset_name() {
  local n
  n=$(printf '%s' "${1:-}" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
  [[ -n $n ]] || die "preset name is empty"
  (( ${#n} <= 40 )) || die "preset name is too long (max 40 characters)"
  [[ $n != */* && $n != *\\* ]] || die "preset name cannot contain slashes"
  [[ $n =~ ^[^[:cntrl:]]+$ ]] || die "preset name has invalid characters"
  printf '%s' "$n"
}

save_preset() {
  local name=$1 gains
  gains=$(jq -c '.gains' "$STATE")
  write_presets --arg n "$name" --argjson g "$gains" '
    .presets = (((.presets // []) | map(select(.name != $n))) + [{name: $n, gains: $g}])
    | .presets |= sort_by(.name | ascii_downcase)'
}

load_preset() {
  local name=$1 gains
  gains=$(jq -c --arg n "$name" '[.presets[] | select(.name == $n)][0].gains // empty' "$PRESETS")
  [[ -n $gains ]] || die "preset not found: $name"
  set_state_gains --argjson g "$gains" '.gains = $g'
  write_conf
  ensure_chain
  apply_live
}

delete_preset() {
  local name=$1
  jq -e --arg n "$name" 'any(.presets[]; .name == $n)' "$PRESETS" >/dev/null \
    || die "preset not found: $name"
  write_presets --arg n "$name" '.presets = [.presets[] | select(.name != $n)]'
}

# Only changes whether the panel runs the live spectrum; audio is untouched.
set_spectrum() {
  set_state_gains --argjson v "$( [[ $1 == on ]] && echo true || echo false )" '.spectrum = $v'
}

status() {
  local notice="${1:-}" node active live_json
  node=$(find_sink)
  active=$([[ -n $node && -f $CONF ]] && echo true || echo false)
  live_json="null"
  if [[ $active == true ]]; then
    mapfile -t lg < <(read_live_gains)
    if (( ${#lg[@]} == BANDS )); then
      live_json=$(IFS=,; echo "[${lg[*]}]")
    fi
  fi
  jq -n --argjson active "$active" --argjson live "$live_json" \
        --argjson bands "$BANDS" \
        --arg notice "$notice" \
        --argjson freqs "$(printf '%s\n' "${FREQS[@]}" | jq -sc 'map(tonumber)')" \
        --argjson labels "$(printf '%s\n' "${LABELS[@]}" | jq -R . | jq -sc .)" \
        --argjson presets "$(jq -c '[.presets[].name]' "$PRESETS")" \
        --argjson spectrum "$(jq -r '(.spectrum != false)' "$STATE")" \
        --slurpfile state "$STATE" \
        '{enabled: $active, active: $active, bands: $bands,
          freqs: $freqs, labels: $labels, presets: $presets,
          spectrum: $spectrum,
          notice: (if $notice == "" then null else $notice end),
          gains: (if $live != null then $live else $state[0].gains end)}'
}

ensure_state
ensure_presets

cmd="${1:-status}"
case "$cmd" in
  status)
    status
    ;;
  set)
    [[ $# == 3 ]] || die "usage: eq set <band 1-$BANDS> <gain dB>"
    [[ $2 =~ ^[0-9]+$ ]] && (( $2 >= 1 && $2 <= BANDS )) || die "band must be 1-$BANDS"
    [[ $3 =~ ^-?[0-9]+([.][0-9]+)?$ ]] || die "gain must be a number (dB)"
    g=$(clamp_gain "$3")
    set_state_gains --argjson i "$(( $2 - 1 ))" --argjson g "$g" '.gains[$i] = $g'
    write_conf
    ensure_chain
    apply_live
    status
    ;;
  reset)
    set_state_gains '.gains = [0.0,0.0,0.0,0.0,0.0,0.0,0.0,0.0,0.0,0.0,0.0,0.0]'
    write_conf
    ensure_chain
    apply_live
    status
    ;;
  on)
    write_conf
    if [[ -z $(find_sink) ]]; then
      systemctl --user restart pipewire.service
      for _ in $(seq 1 25); do
        [[ -n $(find_sink) ]] && break
        sleep 0.2
      done
    fi
    ensure_chain
    [[ -n $(find_sink) ]] && echo "eq: Equalizer output is on" || die "sink did not come up — check journalctl --user -u pipewire"
    ;;
  off)
    rm -f "$CONF"
    if [[ -n $(find_sink) ]]; then
      systemctl --user restart pipewire.service
    fi
    echo "eq: Equalizer output is off"
    ;;
  open)
    omarchy-shell shell toggle francisco.eq
    ;;
  presets)
    jq -c '{presets: [.presets[].name]}' "$PRESETS"
    ;;
  preset-save)
    [[ $# == 2 ]] || die "usage: eq preset-save <name>"
    name=$(preset_name "$2")
    save_preset "$name"
    status "Preset saved: $name"
    ;;
  preset-load)
    [[ $# == 2 ]] || die "usage: eq preset-load <name>"
    name=$(preset_name "$2")
    load_preset "$name"
    status "Preset loaded: $name"
    ;;
  preset-delete)
    [[ $# == 2 ]] || die "usage: eq preset-delete <name>"
    name=$(preset_name "$2")
    delete_preset "$name"
    status "Preset deleted: $name"
    ;;
  spectrum)
    [[ $# == 2 && ( $2 == on || $2 == off ) ]] || die "usage: eq spectrum <on|off>"
    set_spectrum "$2"
    status
    ;;
  bands)
    echo "band  range       filter (Hz)"
    for i in "${!FREQS[@]}"; do
      printf '%d     %-10s  %s\n' "$(( i + 1 ))" "${LABELS[$i]}" "${FREQS[$i]}"
    done
    ;;
  *)
    die "unknown command: $cmd
usage: eq [status|set <1-$BANDS> <dB>|reset|on|off|open|bands|presets|preset-save <name>|preset-load <name>|preset-delete <name>|spectrum <on|off>]"
    ;;
esac
