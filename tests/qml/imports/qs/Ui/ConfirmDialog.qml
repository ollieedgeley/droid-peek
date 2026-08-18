import QtQuick

FocusScope {
    property bool opened: false
    property int selectedIndex: 0
    property string message: ""
    property string cancelText: ""
    property string confirmText: ""
    property color background: "transparent"
    property color foreground: "white"
    signal confirmed()
    signal canceled()

    function handleKey(event) {
        return false
    }
}
