import QtQuick
import qs.Commons

Item {
    id: root

    property var bar: null
    property string text: ""
    property string tooltipText: ""
    property real fixedWidth: -1
    property real fixedHeight: -1
    property bool dimmed: false
    property bool interactive: true
    property bool pressable: true
    property bool useActiveColor: true
    property bool tooltipHovered: false
    readonly property bool vertical: bar ? bar.vertical : false
    readonly property color foreground: bar ? bar.barForeground : "white"

    signal pressed(int button)

    function triggerPress(button) {
        if (pressable)
            pressed(button)
    }

    implicitWidth: fixedWidth > 0 ? fixedWidth : Style.bar.iconSlot
    implicitHeight: fixedHeight > 0 ? fixedHeight : Style.bar.sizeHorizontal
    opacity: dimmed ? 0.45 : 1

    Behavior on opacity {
        NumberAnimation {
            duration: 140
            easing.type: Easing.OutCubic
        }
    }

    MouseArea {
        anchors.fill: parent
        acceptedButtons: Qt.LeftButton | Qt.RightButton | Qt.MiddleButton
        enabled: root.interactive
        onClicked: function (mouse) {
            root.triggerPress(mouse.button)
        }
    }
}
