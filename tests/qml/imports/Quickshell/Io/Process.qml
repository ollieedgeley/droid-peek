import QtQuick

QtObject {
    property var command: []
    property bool stdinEnabled: false
    property bool running: false
    property QtObject stdout: null

    signal exited(int exitCode)

    onRunningChanged: {
        if (!running || !Array.isArray(command))
            return
        if (command.indexOf("--version") < 0)
            return
        Qt.callLater(function () {
            if (stdout)
                stdout.read("1.0.0")
            running = false
            exited(0)
        })
    }

    function write(data) {
    }
}
