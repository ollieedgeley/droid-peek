import QtQuick

QtObject {
    property var command: []
    property bool stdinEnabled: false
    property bool running: false
    property string versionReply: "1.0.0"
    property bool autoCompleteVersion: true
    property int versionExitCode: 0
    property int startCount: 0
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
        startCount += 1
        if (command.indexOf("--version") >= 0 && autoCompleteVersion)
            Qt.callLater(completeVersionCheck)
    }

    function completeVersionCheck() {
        if (!running || !Array.isArray(command)
                || command.indexOf("--version") < 0)
            return
        if (stdout)
            stdout.read(versionReply)
        exitProcess(versionExitCode)
    }

    function exitProcess(exitCode) {
        if (!running)
            return
        running = false
        exited(exitCode)
    }

    function write(data) {
        written += String(data)
    }
}
