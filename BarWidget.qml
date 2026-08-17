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
        if (panel) panel.close()
    }

    function togglePanel() {
        if (panel) panel.toggle()
    }

    function runSemanticAction(actionId) {
        if (actionId === "toggle-android-panel") {
            root.togglePanel()
            return true
        }
        if (root.panel && "triggerSemanticAction" in root.panel)
            return root.panel.triggerSemanticAction(actionId)
        return false
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
        function action(actionId: string): bool { return root.runSemanticAction(actionId) }
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
