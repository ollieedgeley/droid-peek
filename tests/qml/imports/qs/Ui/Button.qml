import QtQuick
import qs.Commons

FocusScope {
    id: root

    property string text: ""
    property string iconText: ""
    property string tooltipText: ""
    property bool selected: false
    property bool active: false
    property bool hasCursor: false
    property bool focusable: false
    property bool bordered: false
    property color foreground: "white"
    property color background: "transparent"

    signal clicked()
    signal rightClicked()
    signal hovered(bool isHovered)

    activeFocusOnTab: focusable
    implicitWidth: label.implicitWidth + Style.spacing.controlPaddingX * 2
    implicitHeight: label.implicitHeight + Style.spacing.controlPaddingY * 2

    Keys.onReturnPressed: if (focusable) clicked()
    Keys.onEnterPressed: if (focusable) clicked()
    Keys.onSpacePressed: if (focusable) clicked()

    Text {
        id: label
        anchors.centerIn: parent
        text: root.text
        color: root.foreground
        font.family: Style.fontFamily
        font.pixelSize: Style.fontBaseSize
    }
}
