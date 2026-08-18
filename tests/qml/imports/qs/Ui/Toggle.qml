import QtQuick
import qs.Commons

FocusScope {
    property string label: ""
    property bool checked: false
    property color foreground: "white"

    signal clicked()
    signal hovered(bool isHovered)

    activeFocusOnTab: true
    implicitHeight: Style.spacing.controlHeight
}
