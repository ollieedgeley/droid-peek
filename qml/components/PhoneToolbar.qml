pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import qs.Commons
import qs.Ui

NestedEscapeScope {
    id: root

    property var actions: ["back", "home", "recent-apps"]
    property bool keepConnected: false
    property bool settingsOpen: false
    property string applicationState: "closed"
    readonly property bool controlsEnabled: applicationState === "interactive"
    property color foreground: Color.foreground

    signal actionRequested(string action)
    signal settingsRequested
    signal keepConnectedRequested(bool keepConnected)
    signal backRequested

    escapeEnabled: settingsOpen
    onEscapeRequested: root.backRequested()

    function actionLabel(action) {
        switch (action) {
        case "back":
            return "Back";
        case "home":
            return "Home";
        case "recent-apps":
            return "Recent apps";
        default:
            return "Android action";
        }
    }

    function actionIcon(action) {
        switch (action) {
        case "back":
            return "󰁍";
        case "home":
            return "󰋜";
        case "recent-apps":
            return "󰒍";
        default:
            return "󰄜";
        }
    }

    function forceSettingsFocus() {
        settingsBackButton.forceActiveFocus();
    }

    implicitHeight: toolbar.implicitHeight

    RowLayout {
        id: toolbar
        anchors.fill: parent
        spacing: Style.space(6)

        PanelActionButton {
            id: settingsBackButton
            objectName: "settingsBackButton"
            visible: root.settingsOpen
            focusable: true
            bordered: true
            iconText: "󰁍"
            tooltipText: "Back to phone"
            foreground: root.foreground
            onClicked: root.backRequested()
        }

        Text {
            visible: root.settingsOpen
            text: "Settings"
            color: root.foreground
            font.family: Style.fontFamily
            font.pixelSize: Style.fontBaseSize
            font.bold: true
        }

        Repeater {
            model: root.settingsOpen ? [] : root.actions

            PanelActionButton {
                required property string modelData
                focusable: true
                bordered: true
                enabled: root.controlsEnabled
                iconText: root.actionIcon(modelData)
                tooltipText: root.actionLabel(modelData)
                foreground: root.foreground
                onClicked: root.actionRequested(modelData)
            }
        }

        Item {
            Layout.fillWidth: true
            implicitHeight: 1
        }

        PanelActionButton {
            objectName: "keepConnectedButton"
            visible: !root.settingsOpen
            focusable: true
            bordered: true
            iconText: "󰌷"
            tooltipText: root.keepConnected ? "Keep connected when panel closes: on" : "Keep connected when panel closes: off"
            foreground: root.foreground
            hoverColor: root.keepConnected ? Color.accent : root.foreground
            color: root.keepConnected ? Style.selectedFillFor(root.foreground, Color.accent) : "transparent"
            borderSpec: root.keepConnected ? Border.controlSpec("selected", root.foreground, Color.accent) : Border.controlSpec("normal", root.foreground, Color.accent)
            onClicked: root.keepConnectedRequested(!root.keepConnected)
        }

        PanelActionButton {
            visible: !root.settingsOpen
            focusable: true
            bordered: true
            iconText: "󰒓"
            tooltipText: "Settings"
            foreground: root.foreground
            onClicked: root.settingsRequested()
        }
    }
}
