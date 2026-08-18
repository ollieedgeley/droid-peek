import QtQuick
import qs.Commons

Rectangle {
    property string iconText: ""
    property string tooltipText: ""
    property bool focusable: false
    property bool bordered: false
    property color foreground: "white"
    property color hoverColor: foreground
    property var borderSpec: ({})

    signal clicked()

    activeFocusOnTab: focusable
    implicitWidth: Style.spacing.controlHeight
    implicitHeight: Style.spacing.controlHeight
    color: "transparent"
    Keys.onReturnPressed: if (focusable) clicked()
}
