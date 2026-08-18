import QtQuick
import qs.Commons

Item {
    property real value: 0
    property real minimum: 0
    property real maximum: 100
    property real step: 1
    property bool integer: false
    property int tickCount: 0
    property color fillColor: "white"
    property color knobColor: "white"
    readonly property real liveValue: value

    signal released(real value)

    implicitHeight: Style.spacing.controlHeight
}
