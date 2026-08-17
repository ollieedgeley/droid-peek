pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import qs.Commons
import qs.Ui

Item {
    id: root

    property var actions: ["back", "home", "recent-apps"]
    property bool settingsOpen: false
    property bool controlsEnabled: true
    property color foreground: Color.foreground

    signal actionRequested(string action)
    signal settingsRequested()
    signal backRequested()

    function actionLabel(action) {
        switch (action) {
        case "back": return "Back"
        case "home": return "Home"
        case "recent-apps": return "Recent apps"
        default: return "Android action"
        }
    }

    function actionIcon(action) {
        switch (action) {
        case "back": return "󰁍"
        case "home": return "󰋜"
        case "recent-apps": return "󰒍"
        default: return "󰄜"
        }
    }

    implicitHeight: toolbar.implicitHeight

    RowLayout {
        id: toolbar
        anchors.fill: parent
        spacing: Style.space(6)

        PanelActionButton {
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
            text: "Render settings"
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
            visible: !root.settingsOpen
            focusable: true
            bordered: true
            iconText: "󰒓"
            tooltipText: "Render settings"
            foreground: root.foreground
            onClicked: root.settingsRequested()
        }
    }
}
