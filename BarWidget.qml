import QtQuick
import qs.Commons
import qs.Ui

BarWidget {
  id: root

  moduleName: "francisco.eq"

  // The widget must report the button's size: a bare BarWidget has zero width,
  // which left the label floating on top of the next widget (the audio icon).
  implicitWidth: row.implicitWidth
  implicitHeight: row.implicitHeight

  Row {
    id: row

    spacing: 1

    WidgetButton {
      id: button

      bar: root.bar
      text: "EQ"
      fontSize: Style.font.caption
      tooltipText: "Equalizer — open the 12-band EQ panel with spectrum"
      onPressed: function (mouseButton) {
        if (mouseButton !== Qt.LeftButton) return
        if (!root.bar) return
        root.bar.run("omarchy-shell shell toggle francisco.eq")
      }
    }
  }
}
