import QtQuick

QtObject {
    property var command: []
    property bool stdinEnabled: false
    property bool running: false
    property QtObject stdout: null

    signal exited(int exitCode)

    function write(data) {
    }
}
