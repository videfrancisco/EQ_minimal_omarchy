# Equalizer (omarchy plugin)

12-band equalizer (20 Hz – 20 kHz) for the Omarchy shell, with a real-time
audio spectrum (via [cava](https://github.com/karlstav/cava)) and named curve
presets. It drives the PipeWire `Equalizer` sink, built from a filter-chain, so
gains survive reboot.

An `EQ` button on the Omarchy bar opens the panel with:

- **Live spectrum** of 32 bars (cava in raw mode, reading the output monitor),
  with a toggle to turn the analyzer off when not in use.
- **12 gain sliders** from −12 dB to +12 dB, in 0.5 dB steps: a low shelf at
  40 Hz, peaking bands from 60 Hz to 14 kHz and a high shelf at 16 kHz.
- **Presets**: save the current curve under a name, load it back with a click,
  and delete it with a right-click. Stored in `~/.config/omarchy/eq-presets.json`.
- **Power on/off** for the Equalizer sink and a **reset** for every band.

## Installation

```sh
omarchy plugin add https://github.com/videfrancisco/EQ_minimal_omarchy.git --enable
```

Then enable the widget on the bar in **Settings → Shell → Bar**, or run:

```sh
omarchy plugin enable francisco.eq
```

## Removal

Turn the equalizer off before removing, so the sink is dismantled:

```sh
~/.config/omarchy/plugins/francisco.eq/scripts/eq.sh off
omarchy plugin remove francisco.eq
```

`off` removes the `~/.config/pipewire/pipewire.conf.d/eq6.conf` config and
restarts PipeWire. The plugin also keeps state in
`~/.config/omarchy/eq.json` and `~/.config/omarchy/eq-presets.json`; remove
those manually if you want to wipe the saved curves.

## External dependencies

- **PipeWire + pw-cli + pw-dump + jq** — required (the Equalizer sink).
- **cava** — optional; only the live spectrum. Without it the panel shows
  "Spectrum unavailable — install cava" and everything else works.
- `omarchy-shell` — provided by Omarchy.

## CLI for the script

The same `eq.sh` script works from a terminal:

```sh
eq.sh status                      # current state as JSON
eq.sh set 3 -4.5                  # band 3 gain (160-320 Hz)
eq.sh reset                       # every band at 0 dB
eq.sh on | off                    # create or remove the Equalizer sink
eq.sh bands                       # band/frequency table
eq.sh presets                     # names of the saved presets
eq.sh preset-save Vocal           # save the current curve
eq.sh preset-load Vocal | preset-delete Vocal
eq.sh spectrum on | off           # panel spectrum preference
```

## Structure

| File | Role |
| --- | --- |
| `manifest.json` | Plugin manifest (schema 1, kinds `bar-widget` + `panel`) |
| `BarWidget.qml` | `EQ` button on the Omarchy shell bar |
| `Panel.qml` | Panel with spectrum, 12 band sliders and presets |
| `scripts/eq.sh` | CLI backend: PipeWire filter-chain, state and presets |
| `scripts/cava.conf` | cava config in raw mode for the spectrum |

## License

[MIT](LICENSE)
