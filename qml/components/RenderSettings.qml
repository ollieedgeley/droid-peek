pragma ComponentBehavior: Bound

import QtQuick
import qs.Commons
import qs.Ui

Column {
    id: root

    property int previewScale: 100
    property string videoQuality: "high"
    property var quickActions: ["back", "home", "recent-apps"]
    property color foreground: Color.foreground

    signal preferencesRequested(int previewScale, string videoQuality, var quickActions)

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

    function request(scale, quality, actions) {
        preferencesRequested(scale, quality, actions.slice())
    }

    function replaceAction(index, action) {
        var actions = quickActions.slice()
        actions[index] = action
        request(previewScale, videoQuality, actions)
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
            root.request(value, root.videoQuality, root.quickActions)
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
            root.request(root.previewScale, value, root.quickActions)
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
