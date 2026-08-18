import QtQuick
import qs.Commons

FocusScope {
    property string text: ""
    property string placeholderText: ""
    property int inputMethodHints: Qt.ImhNone
    property int maximumLength: 32767
    property color foreground: "white"

    signal accepted()

    activeFocusOnTab: true
    implicitWidth: Style.space(160)
    implicitHeight: Style.spacing.controlHeight
    Keys.onReturnPressed: accepted()
    Keys.onEnterPressed: accepted()
}
