import QtQuick

Item {
    property QtObject bar: null
    property string moduleName: ""
    property var settings: ({})
    property string ipcTarget: ""
    property bool manageIpc: true
    property bool opened: false

    readonly property color barForeground: bar ? bar.barForeground : "white"

    function open() {
        opened = true
    }

    function close() {
        opened = false
    }

    function toggle() {
        opened = !opened
    }
}
