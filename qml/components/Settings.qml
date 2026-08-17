pragma ComponentBehavior: Bound

import QtQuick
import qs.Commons
import qs.Ui

Column {
    id: root

    property bool keepConnected: false
    property int previewScale: 100
    property string videoQuality: "high"
    property var quickActions: ["back", "home", "recent-apps"]
    property color foreground: Color.foreground

    signal preferencesRequested(bool keepConnected, int previewScale, string videoQuality, var quickActions)
    signal startOverRequested()

    readonly property var qualityOptions: [
        { value: "low", label: "Low" },
        { value: "medium", label: "Medium" },
        { value: "high", label: "High" }
    ]
    readonly property var actionOptions: [
        { value: "back", label: "Back" },
        { value: "home", label: "Home" },
        { value: "recent-apps", label: "Recent apps" }
    ]

    spacing: Style.space(12)

    function request(keepConnectedValue, scale, quality, actions) {
        preferencesRequested(keepConnectedValue, scale, quality, actions.slice())
    }

    function replaceAction(index, action) {
        var actions = quickActions.slice()
        actions[index] = action
        request(keepConnected, previewScale, videoQuality, actions)
    }

    Text {
        width: parent.width
        text: "CONNECTION"
        color: Qt.darker(root.foreground, 1.35)
        font.family: Style.fontFamily
        font.pixelSize: Style.fontBaseSize * 0.85
        font.bold: true
        font.letterSpacing: 1.2
    }

    Item {
        width: parent.width
        height: Math.max(connectionCopy.implicitHeight, keepConnectedSwitch.implicitHeight)

        Column {
            id: connectionCopy
            width: parent.width - keepConnectedSwitch.width - Style.space(12)
            spacing: Style.space(3)

            Text {
                width: parent.width
                text: "Keep phone connected"
                color: root.foreground
                font.family: Style.fontFamily
                font.pixelSize: Style.fontBaseSize
                font.bold: true
                wrapMode: Text.Wrap
            }

            Text {
                width: parent.width
                text: "Keeps the private phone session running when this panel closes."
                color: Qt.darker(root.foreground, 1.35)
                font.family: Style.fontFamily
                font.pixelSize: Style.fontBaseSize * 0.85
                wrapMode: Text.Wrap
            }
        }

        ToggleSwitch {
            id: keepConnectedSwitch
            objectName: "keepConnectedSwitch"
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            checked: root.keepConnected
            foreground: root.foreground
            onToggled: root.request(!root.keepConnected, root.previewScale,
                                    root.videoQuality, root.quickActions)
        }
    }

    Item {
        width: parent.width
        height: Math.max(startOverCopy.implicitHeight, startOverButton.implicitHeight)

        Column {
            id: startOverCopy
            width: parent.width - startOverButton.width - Style.space(12)
            spacing: Style.space(3)

            Text {
                width: parent.width
                text: "Pair a different phone"
                color: root.foreground
                font.family: Style.fontFamily
                font.pixelSize: Style.fontBaseSize
                font.bold: true
                wrapMode: Text.Wrap
            }

            Text {
                width: parent.width
                text: "Stops this session and forgets this phone on this computer."
                color: Qt.darker(root.foreground, 1.35)
                font.family: Style.fontFamily
                font.pixelSize: Style.fontBaseSize * 0.85
                wrapMode: Text.Wrap
            }
        }

        Button {
            id: startOverButton
            objectName: "startOverButton"
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            text: "Start over"
            onClicked: root.startOverRequested()
        }
    }

    NumberField {
        objectName: "previewScaleField"
        width: parent.width
        label: "Preview scale (%)"
        value: root.previewScale
        from: 50
        to: 150
        stepSize: 5
        foreground: root.foreground
        onModified: function(value) {
            root.request(root.keepConnected, value, root.videoQuality, root.quickActions)
        }
    }

    Text {
        width: parent.width
        text: "The embedded viewport follows this width scale. "
              + "The phone image is centered and fitted without cropping."
        color: Qt.darker(root.foreground, 1.35)
        font.family: Style.fontFamily
        font.pixelSize: Style.fontBaseSize * 0.85
        wrapMode: Text.Wrap
    }

    Dropdown {
        width: parent.width
        label: "Video quality"
        value: root.videoQuality
        options: root.qualityOptions
        foreground: root.foreground
        onChanged: function(value) {
            root.request(root.keepConnected, root.previewScale, value, root.quickActions)
        }
    }

    Text {
        width: parent.width
        text: "Quality changes restart the private phone stream. Pairing remains intact."
        color: Qt.darker(root.foreground, 1.35)
        font.family: Style.fontFamily
        font.pixelSize: Style.fontBaseSize * 0.85
        wrapMode: Text.Wrap
    }

    Text {
        width: parent.width
        text: "QUICK ACTIONS"
        color: Qt.darker(root.foreground, 1.35)
        font.family: Style.fontFamily
        font.pixelSize: Style.fontBaseSize * 0.85
        font.bold: true
        font.letterSpacing: 1.2
    }

    Repeater {
        model: 3

        Dropdown {
            required property int index
            width: root.width
            label: "Slot " + (index + 1)
            value: root.quickActions[index]
            options: root.actionOptions
            foreground: root.foreground
            onChanged: function(value) {
                root.replaceAction(index, value)
            }
        }
    }
}
