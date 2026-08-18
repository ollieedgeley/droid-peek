import QtQuick

QtObject {
    property string path: ""
    property bool watchChanges: false
    property bool printErrors: true

    signal fileChanged()
    signal loaded()
    signal loadFailed()

    function text() {
        return ""
    }
}
