pragma ComponentBehavior: Bound

import QtQuick
import qs.Commons
import qs.Ui

Column {
    id: root

    property string previewSize: "medium"
    property string videoQuality: "high"
    property var quickActions: ["back", "home", "recent-apps"]
    property color foreground: Color.foreground

    signal preferencesRequested(string previewSize, string videoQuality, var quickActions)

    readonly property var sizeOptions: [
        { value: "small", label: "Small" },
        { value: "medium", label: "Medium" },
        { value: "large", label: "Large" }
    ]
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

    function request(size, quality, actions) {
        preferencesRequested(size, quality, actions.slice())
    }

    function replaceAction(index, action) {
        var actions = quickActions.slice()
        actions[index] = action
        request(previewSize, videoQuality, actions)
    }

    Dropdown {
        width: parent.width
        label: "Preview size"
        value: root.previewSize
        options: root.sizeOptions
        foreground: root.foreground
        onChanged: function(value) {
            root.request(value, root.videoQuality, root.quickActions)
        }
    }

    Dropdown {
        width: parent.width
        label: "Video quality"
        value: root.videoQuality
        options: root.qualityOptions
        foreground: root.foreground
        onChanged: function(value) {
            root.request(root.previewSize, value, root.quickActions)
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
