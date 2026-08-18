import QtQuick
import Quickshell.Io
import qs.Ui

BarWidget {
    id: root

    moduleName: "ollie.android"
    property var panel: null
    readonly property bool opened: panel ? panel.opened === true : false

    function open() {
        if (panel) panel.open()
    }

    function close() {
        if (!panel)
            return;
        if ("requestClose" in panel)
            panel.requestClose();
        else
            panel.close();
    }

    function togglePanel() {
        if (!panel)
            return;
        if (opened)
            close();
        else
            panel.open();
    }

    function decodeEnvelope(encodedEnvelope, maximumLength) {
        if (typeof encodedEnvelope !== "string" || encodedEnvelope.length === 0
                || encodedEnvelope.length > maximumLength
                || !/^[A-Za-z0-9_-]+$/.test(encodedEnvelope))
            return null;
        var base64 = encodedEnvelope.replace(/-/g, "+").replace(/_/g, "/");
        while (base64.length % 4 !== 0)
            base64 += "=";
        try {
            var binary = Qt.atob(base64);
            var escaped = "";
            for (var index = 0; index < binary.length; ++index)
                escaped += "%" + ("0" + binary.charCodeAt(index).toString(16)).slice(-2);
            return JSON.parse(decodeURIComponent(escaped));
        } catch (error) {
            return null;
        }
    }

    function decodePhoneTarget(encodedEnvelope) {
        return decodeEnvelope(encodedEnvelope, 4096);
    }

    function phoneTarget(encodedEnvelope) {
        var request = decodePhoneTarget(encodedEnvelope);
        if (request === null || !root.panel
                || !("acceptPhoneTarget" in root.panel))
            return false;
        return root.panel.acceptPhoneTarget(request);
    }

    function configureScrcpy(revision, encodedConfiguration) {
        var scrcpyArguments = decodeEnvelope(encodedConfiguration, 24000);
        if (typeof revision !== "string" || !/^[0-9a-f]{16}$/.test(revision)
                || !validScrcpyArguments(scrcpyArguments) || !root.panel
                || !("setScrcpyConfiguration" in root.panel))
            return false;
        return root.panel.setScrcpyConfiguration(revision, scrcpyArguments);
    }

    function validScrcpyArguments(scrcpyArguments) {
        if (!Array.isArray(scrcpyArguments) || scrcpyArguments.length > 32)
            return false;
        var reserved = [
            "--serial", "--select-usb", "--select-tcpip", "--tcpip",
            "--video-source", "--new-display", "--display", "--v4l2-sink",
            "--no-video", "--no-window", "--window", "--control",
            "--no-control", "--no-cleanup", "--no-power-on", "--max-size",
            "--video-bit-rate", "--max-fps"
        ];
        for (var index = 0; index < scrcpyArguments.length; ++index) {
            var argument = scrcpyArguments[index];
            if (typeof argument !== "string"
                    || unescape(encodeURIComponent(argument)).length > 512
                    || !/^--[^\r\n\u0000]+$/.test(argument))
                return false;
            var separator = argument.indexOf("=");
            var name = separator < 0 ? argument : argument.slice(0, separator);
            if (reserved.indexOf(name) >= 0 || /^--audio/.test(name))
                return false;
        }
        return true;
    }

    function injectPanel() {
        if (!root.panel) return
        if ("bar" in root.panel) root.panel.bar = root.bar
        if ("anchorItem" in root.panel) root.panel.anchorItem = button
        if ("hostWidget" in root.panel) root.panel.hostWidget = root
    }

    implicitWidth: button.implicitWidth
    implicitHeight: button.implicitHeight

    onBarChanged: injectPanel()

    Loader {
        id: panelLoader
        active: true
        source: Qt.resolvedUrl("Panel.qml")
        visible: false
        onLoaded: {
            root.panel = item
            root.injectPanel()
            Qt.callLater(root.injectPanel)
        }
    }

    IpcHandler {
        target: "ollie.android"

        function open() { root.open() }
        function close() { root.close() }
        function show() { root.open() }
        function hide() { root.close() }
        function toggle() { root.togglePanel() }
        function phoneTarget(encodedEnvelope: string): bool { return root.phoneTarget(encodedEnvelope) }
        function configureScrcpy(revision: string,
                                 encodedConfiguration: string): bool {
            return root.configureScrcpy(revision, encodedConfiguration)
        }
    }

    WidgetButton {
        id: button
        anchors.fill: parent
        bar: root.bar
        text: "󰄜"
        tooltipText: "Omarchy Android"
        onPressed: function(button) {
            if (button === Qt.LeftButton) root.togglePanel()
        }
    }
}
