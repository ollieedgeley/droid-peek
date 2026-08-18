import QtQuick
import qs.Commons

FocusScope {
    property string label: ""
    property var value: null
    property var options: []
    property color foreground: "white"

    signal changed(var value)

    activeFocusOnTab: true
    implicitHeight: Style.spacing.controlHeight
}
