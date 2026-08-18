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

    function decodePhoneTarget(encodedEnvelope) {
        if (typeof encodedEnvelope !== "string" || encodedEnvelope.length === 0
                || encodedEnvelope.length > 4096
                || !/^[A-Za-z0-9_-]+$/.test(encodedEnvelope))
            return null;
        var base64 = encodedEnvelope.replace(/-/g, "+").replace(/_/g, "/");
        while (base64.length % 4 !== 0)
            base64 += "=";
        try {
            return JSON.parse(Qt.atob(base64));
        } catch (error) {
            return null;
        }
    }

    function phoneTarget(encodedEnvelope) {
        var request = decodePhoneTarget(encodedEnvelope);
        if (request === null || !root.panel
                || !("acceptPhoneTarget" in root.panel))
            return false;
        return root.panel.acceptPhoneTarget(request);
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
