import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import qs.Commons
import qs.Commons as Commons
import qs.Ui

// Equalizer panel: a live spectrum analyzer plus twelve frequency-range band
// gains for the PipeWire "Equalizer" sink, driven by the plugin's `eq` script.
// The spectrum comes from cava in raw mode. Hosted by the omarchy shell like
// other panel plugins: the shell drives `opened` on toggle/summon and the bar
// widget opens it with `omarchy-shell shell toggle francisco.eq`.
Item {
  id: root

  property var shell: null
  property var manifest: null
  property bool opened: false

  property bool sinkEnabled: false
  readonly property int bandCount: 12
  property var gains: [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]
  property var labels: ["20-40", "40-80", "80-160", "160-320", "320-640", "640-1.2k", "1.2k-2.5k", "2.5k-5k", "5k-8k", "8k-12k", "12k-16k", "16k-20k"]
  property string lastResult: ""
  property bool busy: false

  // Saved curves from ~/.config/omarchy/eq-presets.json, newest state first.
  property var presets: []
  property string presetName: ""
  property string presetMsg: ""

  // Presets card starts collapsed so the sliders stay reachable; it stays
  // expanded once the user opens it (for the rest of the shell's lifetime).
  property bool presetsCollapsed: true

  // Live spectrum: 0-100 per bar, as emitted by cava.
  readonly property int spectrumBars: 32
  property var spectrum: []
  property bool spectrumFailed: false
  // Mirror of the persisted preference (eq.json "spectrum"); off also stops
  // the cava process so an unused analyzer costs nothing.
  property bool spectrumOn: true

  // Band waiting to be applied while the user drags a slider; the timer
  // coalesces continuous moves into one `eq set` call.
  property int pendingBand: 0
  property real pendingGain: 0

  // Script commands clicked while another one runs wait in this queue instead
  // of being dropped, so a fast second change is never lost.
  property var queue: []

  // True while the running command replies with JSON status (status, set,
  // reset); on/off reply with plain text and are followed by a refresh.
  property bool jsonReply: false

  readonly property string eqScript: decodeURIComponent(Qt.resolvedUrl("scripts/eq.sh").toString().replace(/^file:\/\//, ""))
  readonly property string spectrumConf: decodeURIComponent(Qt.resolvedUrl("scripts/cava.conf").toString().replace(/^file:\/\//, ""))

  onOpenedChanged: {
    if (root.opened) {
      root.spectrumFailed = false
      root.spectrum = []
      root.presetMsg = ""
      if (root.spectrumOn) spectrumProcess.running = true
      root.refresh()
    } else {
      spectrumProcess.running = false
      spectrumRetry.stop()
      root.spectrum = []
    }
  }

  // The status reply carries the persisted preference; react to switches
  // coming back from the script as well as to user toggles in the panel.
  onSpectrumOnChanged: {
    if (root.spectrumOn) {
      if (root.opened && !spectrumProcess.running) spectrumProcess.running = true
    } else {
      spectrumProcess.running = false
      spectrumRetry.stop()
      root.spectrum = []
    }
  }

  function open(payloadJson) {
    // Called by the shell host on summon/toggle.
    root.opened = true
  }

  function close() {
    // Called by the shell host on hide.
    root.opened = false
  }

  function hideSelf() {
    root.close()
    if (root.shell && typeof root.shell.hide === "function")
      root.shell.hide((root.manifest && root.manifest.id) || "francisco.eq")
  }

  function refresh() {
    root.run(["status"])
  }

  function applyGain(band, value) {
    root.run(["set", String(band), (Math.round(value * 2) / 2).toFixed(1)])
  }

  function resetAll() {
    root.run(["reset"])
  }

  function setSinkEnabled(on) {
    root.run([on ? "on" : "off"])
  }

  function setSpectrumEnabled(on) {
    // The preference persists via eq.json; the status reply flips the flag
    // again and the onSpectrumOnChanged handler starts/stops cava.
    root.run(["spectrum", on ? "on" : "off"])
  }

  function savePreset() {
    var name = String(root.presetName || "").replace(/^\s+|\s+$/g, "")
    if (!name) {
      root.presetMsg = "✗ Type a name first"
      return
    }
    if (name.length > 40) {
      root.presetMsg = "✗ Preset names are limited to 40 characters"
      return
    }
    root.presetMsg = ""
    root.run(["preset-save", name])
  }

  function loadPreset(name) {
    if (!name) return
    root.presetMsg = ""
    root.run(["preset-load", String(name)])
  }

  function deletePreset(name) {
    if (!name) return
    root.presetMsg = ""
    root.run(["preset-delete", String(name)])
  }

  // Commands that answer with the status JSON, so the panel can parse them.
  function isJsonCommand(args) {
    if (!args || args.length === 0) return false
    var cmd = args[0]
    return cmd === "status" || cmd === "set" || cmd === "reset"
      || cmd === "preset-save" || cmd === "preset-load" || cmd === "preset-delete"
      || cmd === "spectrum"
  }

  function updateSpectrum(line) {
    if (typeof line !== "string" || line.length > 8192) return
    var parts = line.split(";")
    var next = []
    for (var i = 0; i < root.spectrumBars; i++) {
      var value = Number(parts[i])
      next.push(isFinite(value) ? Math.max(0, Math.min(100, value)) : 0)
    }
    root.spectrum = next
  }

  function handleOutput(text) {
    if (!root.jsonReply) return
    try {
      if (typeof text !== "string" || text.length > 65536) return
      var d = JSON.parse(text || "{}")
      if (d.enabled !== undefined) root.sinkEnabled = d.enabled === true
      if (d.spectrum !== undefined) root.spectrumOn = d.spectrum === true
      if (d.gains && d.gains.length === root.bandCount) {
        var next = []
        for (var i = 0; i < root.bandCount; i++) next.push(Number(d.gains[i]) || 0)
        root.gains = next
      }
      if (d.labels && d.labels.length === root.bandCount) root.labels = d.labels
      if (d.presets && typeof d.presets.length === "number") {
        var names = []
        for (var j = 0; j < d.presets.length && j < 100; j++) {
          var name = d.presets[j]
          if (typeof name === "string" && name.length > 0 && name.length <= 40) names.push(name)
        }
        root.presets = names
      }
      if (typeof d.notice === "string" && d.notice !== "") {
        root.presetMsg = "✓ " + d.notice
        if (d.notice.indexOf("Preset saved:") === 0) root.presetName = ""
      }
      root.lastResult = ""
    } catch (error) {
      root.lastResult = "✗ Could not read the equalizer state"
    }
  }

  // Runs an eq command. If another one is still running, the command is
  // queued and runs as soon as the current one finishes.
  function run(args) {
    if (root.busy) {
      var q = root.queue.slice()
      q.push(args)
      root.queue = q
      return
    }
    root.busy = true
    root.jsonReply = root.isJsonCommand(args)
    eqProcess.command = [root.eqScript].concat(args)
    eqProcess.running = true
  }

  function runNext() {
    if (root.queue.length === 0) return
    var cmd = root.queue.shift()
    root.busy = true
    root.jsonReply = root.isJsonCommand(cmd)
    eqProcess.command = [root.eqScript].concat(cmd)
    eqProcess.running = true
  }

  implicitWidth: 0
  implicitHeight: 0

  Process {
    id: eqProcess

    stdout: StdioCollector {
      onStreamFinished: root.handleOutput(text)
    }

    onExited: function (exitCode) {
      root.busy = false
      if (exitCode !== 0) {
        root.lastResult = "✗ eq command failed"
      } else if (!root.jsonReply) {
        // on/off answer in plain text; read the fresh state instead.
        root.queue.push(["status"])
      }
      root.runNext()
    }
  }

  // cava writes one raw ASCII frame per line while the panel is open.
  Process {
    id: spectrumProcess

    running: false
    command: ["cava", "-p", root.spectrumConf]

    stdout: SplitParser {
      onRead: function (line) {
        root.updateSpectrum(line)
      }
    }

    onExited: function (exitCode) {
      if (!root.opened) return
      if (exitCode === 127) {
        root.spectrumFailed = true
        return
      }
      spectrumRetry.restart()
    }
  }

  Timer {
    id: spectrumRetry

    interval: 1500
    onTriggered: if (root.opened && !root.spectrumFailed) spectrumProcess.running = true
  }

  Timer {
    id: applyTimer

    interval: 120
    onTriggered: root.applyGain(root.pendingBand, root.pendingGain)
  }

  PanelWindow {
    id: panelWindow

    visible: root.opened
    exclusionMode: ExclusionMode.Ignore
    color: "transparent"
    // Layer-shell panels don't take keyboard focus by default, so the preset
    // name field would never receive typing. Prime with Exclusive on open
    // (covers keybind summons, where no click focused the surface), then
    // settle on OnDemand so the rest of the desktop keeps working.
    property bool keyboardPrimed: false

    WlrLayershell.keyboardFocus: root.opened
      ? (keyboardPrimed ? WlrKeyboardFocus.OnDemand : WlrKeyboardFocus.Exclusive)
      : WlrKeyboardFocus.None

    onVisibleChanged: {
      if (visible) {
        keyboardPrimed = false
        keyboardPrimeTimer.restart()
      } else {
        keyboardPrimeTimer.stop()
        keyboardPrimed = false
      }
    }

    Timer {
      id: keyboardPrimeTimer

      interval: 75
      onTriggered: if (root.opened) panelWindow.keyboardPrimed = true
    }

    // The card is the whole interactive surface; without an explicit mask the
    // layer surface can stay click-through, which made every button dead.
    mask: Region {
      item: card
    }

    anchors {
      top: true
      right: true
    }
    margins {
      top: 40
      right: 8
    }
    implicitWidth: 420
    implicitHeight: Math.min(cardColumn.implicitHeight + 28, 740)

    Rectangle {
      id: card

      anchors.fill: parent
      color: Commons.Color.background
      radius: Style.cornerRadius
      border.width: 1
      border.color: Qt.alpha(Commons.Color.foreground, 0.12)

      Flickable {
        id: flick

        anchors.fill: parent
        anchors.margins: 14
        contentWidth: width
        contentHeight: cardColumn.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        interactive: contentHeight > height

        Column {
          id: cardColumn

          width: flick.width
          spacing: 8

          // Header
          Item {
            width: parent.width
            height: 30

            Text {
              anchors.verticalCenter: parent.verticalCenter
              anchors.left: parent.left
              textFormat: Text.PlainText
              text: "\uf1de  Equalizer"
              color: Commons.Color.foreground
              font.family: Style.font.family
              font.pixelSize: Style.font.subtitle
              font.bold: true
            }

            Button {
              anchors.verticalCenter: parent.verticalCenter
              anchors.right: parent.right
              iconText: "\uf00d"
              fontSize: Style.font.body
              tooltipText: "Close"
              onClicked: root.hideSelf()
            }
          }

          // Live spectrum; the header toggle turns the analyzer off entirely
          // (cava stops) and the choice persists in eq.json across opens.
          Rectangle {
            width: parent.width
            height: root.spectrumOn ? 80 : 34
            radius: Style.cornerRadius * 0.6
            color: Qt.alpha(Commons.Color.foreground, 0.04)
            border.width: 1
            border.color: Qt.alpha(Commons.Color.foreground, 0.08)
            clip: true

            Behavior on height {
              NumberAnimation {
                duration: Style.duration(120)
                easing.type: Easing.OutCubic
              }
            }

            Text {
              anchors.left: parent.left
              anchors.top: parent.top
              anchors.leftMargin: 10
              anchors.topMargin: 9
              textFormat: Text.PlainText
              text: !root.spectrumOn ? "Spectrum is off"
                : (root.spectrumFailed ? "Spectrum unavailable — install cava" : "Spectrum")
              color: root.spectrumFailed && root.spectrumOn ? "#f85149" : Commons.Color.muted
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
            }

            Row {
              anchors.right: parent.right
              anchors.top: parent.top
              anchors.rightMargin: 10
              anchors.topMargin: 4
              spacing: 8

              Text {
                anchors.verticalCenter: spectrumToggle.verticalCenter
                textFormat: Text.PlainText
                text: "20 Hz — 20 kHz"
                color: Commons.Color.muted
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
              }

              ToggleSwitch {
                id: spectrumToggle

                anchors.verticalCenter: parent.verticalCenter
                checked: root.spectrumOn
                interactive: true
                rounded: Style.cornerRadius > 0
                trackHeight: 16
                foreground: Commons.Color.foreground
                accent: Commons.Color.accent
                onToggled: root.setSpectrumEnabled(!root.spectrumOn)
              }
            }

            Row {
              id: barsRow

              visible: root.spectrumOn
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.bottom: parent.bottom
              anchors.leftMargin: 10
              anchors.rightMargin: 10
              anchors.bottomMargin: 8
              height: 54
              spacing: 2

              Repeater {
                model: root.spectrumBars

                delegate: Item {
                  required property int index

                  readonly property real level: (root.spectrum && root.spectrum.length === root.spectrumBars) ? root.spectrum[index] : 0

                  width: Math.max(1, (barsRow.width - (root.spectrumBars - 1) * barsRow.spacing) / root.spectrumBars)
                  height: barsRow.height

                  Rectangle {
                    anchors.bottom: parent.bottom
                    width: parent.width
                    height: Math.max(2, (parent.height - 4) * level / 100)
                    radius: Math.min(width / 2, 3)
                    color: Commons.Color.accent
                    opacity: 0.4 + Math.min(0.6, level / 150)

                    Behavior on height {
                      NumberAnimation {
                        duration: Style.duration(90)
                        easing.type: Easing.OutCubic
                      }
                    }
                  }
                }
              }
            }
          }

          // Presets: save the current curve under a name, click a chip to
          // load it back, right-click a chip to delete it. The header chevron
          // collapses the card to a single row so the sliders stay reachable.
          Rectangle {
            width: parent.width
            height: root.presetsCollapsed
              ? presetHeader.implicitHeight + 16
              : presetColumn.implicitHeight + 16
            radius: Style.cornerRadius * 0.6
            color: Qt.alpha(Commons.Color.foreground, 0.03)
            border.width: 1
            border.color: Qt.alpha(Commons.Color.foreground, 0.08)

            Behavior on height {
              NumberAnimation {
                duration: Style.duration(120)
                easing.type: Easing.OutCubic
              }
            }

            Column {
              id: presetColumn

              anchors.left: parent.left
              anchors.right: parent.right
              anchors.top: parent.top
              anchors.margins: 8
              spacing: 6

              Row {
                id: presetHeader

                width: parent.width
                spacing: 6

                Text {
                  width: parent.width - presetToggleButton.width - parent.spacing
                  anchors.verticalCenter: parent.verticalCenter
                  textFormat: Text.PlainText
                  text: "Presets"
                    + (root.presets.length > 0 ? " · " + root.presets.length : "")
                  color: Commons.Color.muted
                  font.family: Style.font.family
                  font.pixelSize: Style.font.caption
                  elide: Text.ElideRight
                }

                Button {
                  id: presetToggleButton

                  anchors.verticalCenter: parent.verticalCenter
                  iconText: root.presetsCollapsed ? "\uf105" : "\uf078"
                  fontSize: Style.font.caption
                  tooltipText: root.presetsCollapsed ? "Show presets" : "Hide presets"
                  onClicked: root.presetsCollapsed = !root.presetsCollapsed
                }
              }

              Row {
                visible: !root.presetsCollapsed
                width: parent.width
                height: 28
                spacing: 6

                TextField {
                  id: presetField

                  width: parent.width - savePresetButton.width - parent.spacing
                  height: 28
                  placeholderText: "Preset name"
                  text: root.presetName
                  verticalPadding: 4
                  onTextChanged: root.presetName = text
                  onAccepted: root.savePreset()
                }

                Button {
                  id: savePresetButton

                  height: 28
                  iconText: "\uf0c7"
                  text: "Save"
                  fontSize: Style.font.caption
                  tooltipText: "Save the current 12-band curve as a preset"
                  onClicked: root.savePreset()
                }
              }
              Flow {
                visible: !root.presetsCollapsed
                width: parent.width
                spacing: 6

                Repeater {
                  model: root.presets

                  delegate: Button {
                    required property var modelData

                    text: String(modelData)
                    fontSize: Style.font.caption
                    bordered: true
                    tooltipText: "Click to load · Right-click to delete"
                    onClicked: root.loadPreset(modelData)
                    onRightClicked: root.deletePreset(modelData)
                  }
                }
              }

              Text {
                visible: !root.presetsCollapsed && root.presets.length === 0
                width: parent.width
                textFormat: Text.PlainText
                text: "No presets yet — type a name and save the current curve."
                color: Commons.Color.muted
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
                wrapMode: Text.WordWrap
              }

              Text {
                visible: !root.presetsCollapsed && root.presetMsg !== ""
                width: parent.width
                textFormat: Text.PlainText
                text: root.presetMsg
                color: root.presetMsg.indexOf("✗") === 0 ? "#f85149" : Commons.Color.muted
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
                wrapMode: Text.WordWrap
              }
            }
          }

          // Equalizer output switch
          Rectangle {
            width: parent.width
            height: 34
            radius: Style.cornerRadius * 0.6
            color: Qt.alpha(Commons.Color.accent, root.sinkEnabled ? 0.12 : 0.04)

            Text {
              anchors.verticalCenter: parent.verticalCenter
              anchors.left: parent.left
              anchors.leftMargin: 10
              width: parent.width - 80
              textFormat: Text.PlainText
              text: root.sinkEnabled ? "Equalizer output is on" : "Equalizer output is off"
              color: root.sinkEnabled ? Commons.Color.accent : Commons.Color.muted
              font.family: Style.font.family
              font.pixelSize: Style.font.body
              elide: Text.ElideRight
            }

            Item {
              width: sinkToggle.width
              height: sinkToggle.height
              anchors.verticalCenter: parent.verticalCenter
              anchors.right: parent.right
              anchors.rightMargin: 10

              ToggleSwitch {
                id: sinkToggle

                checked: root.sinkEnabled
                interactive: true
                rounded: Style.cornerRadius > 0
                trackHeight: 18
                foreground: Commons.Color.foreground
                accent: Commons.Color.accent
                onToggled: root.setSinkEnabled(!root.sinkEnabled)
              }
            }
          }

          // Band sliders
          Repeater {
            model: root.bandCount

            delegate: Item {
              id: bandRow

              required property int index

              readonly property real gain: (root.gains && root.gains.length === root.bandCount) ? root.gains[index] : 0
              property real shown: bandRow.gain

              onGainChanged: if (!slider.dragging) bandRow.shown = bandRow.gain

              width: parent.width
              height: 30

              Text {
                id: freqLabel

                anchors.verticalCenter: parent.verticalCenter
                anchors.left: parent.left
                width: 74
                textFormat: Text.PlainText
                text: (root.labels && root.labels.length === root.bandCount) ? root.labels[index] : ""
                color: Commons.Color.muted
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
                horizontalAlignment: Text.AlignRight
              }

              PanelSlider {
                id: slider

                anchors.verticalCenter: parent.verticalCenter
                anchors.left: freqLabel.right
                anchors.leftMargin: 10
                anchors.right: gainLabel.left
                anchors.rightMargin: 10
                minimum: -12
                maximum: 12
                step: 0.5
                value: bandRow.shown
                tickCount: 9
                trackColor: Qt.alpha(Commons.Color.foreground, 0.12)
                fillColor: Commons.Color.accent
                knobColor: Commons.Color.foreground
                tickColor: Commons.Color.background

                onMoved: function (value) {
                  bandRow.shown = value
                  root.pendingBand = bandRow.index + 1
                  root.pendingGain = value
                  applyTimer.restart()
                }

                onReleased: function (value) {
                  applyTimer.stop()
                  bandRow.shown = value
                  root.applyGain(bandRow.index + 1, value)
                }
              }

              Text {
                id: gainLabel

                anchors.verticalCenter: parent.verticalCenter
                anchors.right: parent.right
                width: 60
                textFormat: Text.PlainText
                text: (bandRow.shown > 0 ? "+" : "") + bandRow.shown.toFixed(1) + " dB"
                color: bandRow.shown !== 0 ? Commons.Color.accent : Commons.Color.muted
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
                horizontalAlignment: Text.AlignRight
              }
            }
          }

          // Reset + hint row
          Rectangle {
            width: parent.width
            height: 34
            radius: Style.cornerRadius * 0.6
            color: Qt.alpha(Commons.Color.foreground, 0.04)
            border.width: 1
            border.color: Qt.alpha(Commons.Color.foreground, 0.10)

            Button {
              anchors.verticalCenter: parent.verticalCenter
              anchors.left: parent.left
              anchors.leftMargin: 6
              iconText: "\uf0e2"
              text: "Reset"
              fontSize: Style.font.caption
              tooltipText: "Set every band back to 0 dB"
              onClicked: root.resetAll()
            }

            Text {
              anchors.verticalCenter: parent.verticalCenter
              anchors.right: parent.right
              anchors.rightMargin: 10
              width: parent.width / 2 - 16
              textFormat: Text.PlainText
              text: "12 bands — play through the Equalizer output"
              color: Commons.Color.muted
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
              horizontalAlignment: Text.AlignRight
            }
          }

          // Footer status
          Text {
            width: parent.width
            textFormat: Text.PlainText
            text: root.busy ? "Working…" : (root.lastResult || "Gains are saved and restored on reboot")
            color: root.lastResult.startsWith("✗") ? "#f85149" : Commons.Color.muted
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
            elide: Text.ElideRight
          }
        }
      }

      // Slim scroll indicator, only when the content is taller than the panel.
      Rectangle {
        visible: flick.contentHeight > flick.height
        width: 3
        radius: 1.5
        color: Qt.alpha(Commons.Color.foreground, 0.25)
        x: card.width - 7
        y: 14 + flick.visibleArea.yPosition * flick.height
        height: Math.max(20, flick.visibleArea.heightRatio * flick.height)
      }
    }
  }
}
