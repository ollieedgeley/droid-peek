import QtQuick

QtObject {
    property var command: []
    property bool stdinEnabled: false
    property bool running: false
    property QtObject stdout: null
    property string written: ""
    readonly property var writtenLines: {
        if (written.length === 0)
            return []
        var lines = written.split("\n")
        lines.pop()
        return lines
    }

    signal exited(int exitCode)

    onRunningChanged: {
        if (!running || !Array.isArray(command))
            return
        if (command.indexOf("--version") >= 0) {
            Qt.callLater(function () {
                if (stdout)
                    stdout.read("1.0.0")
                running = false
                exited(0)
            })
            return
        }
    }

    function write(data) {
        written += String(data)
    }
}
