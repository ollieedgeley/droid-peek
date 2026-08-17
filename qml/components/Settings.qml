pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls as Controls
import qs.Commons
import qs.Ui

NestedEscapeScope {
    id: root

    property bool keepConnected: false
    property int previewScale: 100
    property string videoQuality: "high"
    property var quickActions: ["back", "home", "recent-apps"]
    property bool androidModeShortcuts: false
    property bool commandPassthrough: false
    property color foreground: Color.foreground
    property real maximumHeight: Number.POSITIVE_INFINITY

    signal backRequested
    signal preferencesRequested(bool keepConnected, int previewScale, string videoQuality, var quickActions, bool androidModeShortcuts, bool commandPassthrough)
    signal startOverRequested

    readonly property var qualityOptions: [
        {
            value: "low",
            label: "Low"
        },
        {
            value: "medium",
            label: "Medium"
        },
        {
            value: "high",
            label: "High"
        }
    ]
    readonly property var actionOptions: [
        {
            value: "back",
            label: "Back"
        },
        {
            value: "home",
            label: "Home"
        },
        {
            value: "recent-apps",
            label: "Recent apps"
        }
    ]

    implicitWidth: Style.space(360)
    implicitHeight: Math.min(settingsContent.implicitHeight, maximumHeight)

    function request(keepConnectedValue, scale, quality, actions, androidModeShortcutsValue, commandPassthroughValue) {
        preferencesRequested(keepConnectedValue, scale, quality, actions.slice(), androidModeShortcutsValue, commandPassthroughValue);
    }

    function replaceAction(index, action) {
        var actions = quickActions.slice();
        actions[index] = action;
        request(keepConnected, previewScale, videoQuality, actions, androidModeShortcuts, commandPassthrough);
    }

    function qualityLabel(value) {
        for (var index = 0; index < qualityOptions.length; ++index) {
            if (qualityOptions[index].value === value)
                return qualityOptions[index].label;
        }
        return value;
    }

    function setPreviewScale(value) {
        var next = Math.max(50, Math.min(150, Math.round(value / 5) * 5));
        if (next !== previewScale)
            request(keepConnected, next, videoQuality, quickActions, androidModeShortcuts, commandPassthrough);
    }

    onEscapeRequested: root.backRequested()

    Controls.ScrollView {
        id: settingsScroll
        anchors.fill: parent
        clip: true
        contentWidth: availableWidth
        contentHeight: settingsContent.implicitHeight
        Controls.ScrollBar.horizontal.policy: Controls.ScrollBar.AlwaysOff
        Controls.ScrollBar.vertical.policy: Controls.ScrollBar.AsNeeded

        Column {
            id: settingsContent
            width: settingsScroll.availableWidth
            spacing: Style.space(12)

            PanelSectionHeader {
                width: parent.width
                text: "CONNECTION"
                foreground: root.foreground
            }

            Toggle {
                id: keepConnectedControl
                objectName: "keepConnectedControl"
                width: parent.width
                label: "Keep phone connected"
                checked: root.keepConnected
                foreground: root.foreground
                onClicked: root.request(!root.keepConnected, root.previewScale, root.videoQuality, root.quickActions, root.androidModeShortcuts, root.commandPassthrough)

                property bool pointerHovered: false
                onHovered: function (isHovered) {
                    pointerHovered = isHovered;
                }

                PanelToolTip {
                    visible: keepConnectedControl.pointerHovered || keepConnectedControl.activeFocus
                    text: "Keep the phone session running when this panel closes."
                }
            }

            Toggle {
                id: androidModeShortcutsControl
                objectName: "androidModeShortcutsControl"
                width: parent.width
                label: "Android-mode shortcuts"
                checked: root.androidModeShortcuts
                foreground: root.foreground
                onClicked: root.request(root.keepConnected, root.previewScale, root.videoQuality, root.quickActions, !root.androidModeShortcuts, root.commandPassthrough)

                property bool pointerHovered: false
                onHovered: function (isHovered) {
                    pointerHovered = isHovered;
                }

                PanelToolTip {
                    visible: androidModeShortcutsControl.pointerHovered || androidModeShortcutsControl.activeFocus
                    text: "Enable Android-aware routing for configured Omarchy actions."
                }
            }

            Toggle {
                id: commandPassthroughControl
                objectName: "commandPassthroughControl"
                width: parent.width
                label: "Command passthrough"
                checked: root.commandPassthrough
                foreground: root.foreground
                onClicked: root.request(root.keepConnected, root.previewScale, root.videoQuality, root.quickActions, root.androidModeShortcuts, !root.commandPassthrough)

                property bool pointerHovered: false
                onHovered: function (isHovered) {
                    pointerHovered = isHovered;
                }

                PanelToolTip {
                    visible: commandPassthroughControl.pointerHovered || commandPassthroughControl.activeFocus
                    text: "Let configured Omarchy actions reach the focused phone instead of the desktop."
                }
            }

            PanelSeparator {
                foreground: root.foreground
            }

            PanelSectionHeader {
                width: parent.width
                text: "VIDEO"
                foreground: root.foreground
            }

            Column {
                width: parent.width
                spacing: Style.space(6)

                Row {
                    width: parent.width

                    Text {
                        width: parent.width - previewScaleValue.width
                        text: "Preview scale"
                        color: root.foreground
                        font.family: Style.fontFamily
                        font.pixelSize: Style.fontBaseSize
                        font.bold: true
                    }

                    Text {
                        id: previewScaleValue
                        text: Math.round(previewScaleSlider.liveValue) + "%"
                        color: Qt.darker(root.foreground, 1.25)
                        font.family: Style.fontFamily
                        font.pixelSize: Style.fontBaseSize
                    }
                }

                BorderSurface {
                    id: previewScaleControl
                    objectName: "previewScaleControl"
                    width: parent.width
                    height: previewScaleSlider.implicitHeight + Style.space(8)
                    radius: Style.cornerRadius
                    activeFocusOnTab: true
                    color: Style.controlFill(activeFocus, previewScaleHover.hovered, root.foreground, Color.accent)
                    borderSpec: Border.controlSpec(activeFocus ? "focus" : (previewScaleHover.hovered ? "hover-cursor" : "normal"), root.foreground, Color.accent)

                    function moveBy(delta) {
                        root.setPreviewScale(root.previewScale + delta);
                    }

                    Keys.onPressed: function (event) {
                        if (event.isAutoRepeat) {
                            event.accepted = true;
                            return;
                        }
                        if (event.key === Qt.Key_Left) {
                            moveBy(-5);
                            event.accepted = true;
                        } else if (event.key === Qt.Key_Right) {
                            moveBy(5);
                            event.accepted = true;
                        } else if (event.key === Qt.Key_Home) {
                            root.setPreviewScale(50);
                            event.accepted = true;
                        } else if (event.key === Qt.Key_End) {
                            root.setPreviewScale(150);
                            event.accepted = true;
                        }
                    }

                    HoverHandler {
                        id: previewScaleHover
                    }

                    PanelSlider {
                        id: previewScaleSlider
                        anchors.left: parent.left
                        anchors.right: parent.right
                        anchors.verticalCenter: parent.verticalCenter
                        anchors.leftMargin: Style.space(8)
                        anchors.rightMargin: Style.space(8)
                        value: root.previewScale
                        minimum: 50
                        maximum: 150
                        step: 5
                        integer: true
                        tickCount: 5
                        fillColor: root.foreground
                        knobColor: root.foreground
                        onReleased: function (value) {
                            root.setPreviewScale(value);
                        }
                    }

                    PanelToolTip {
                        visible: previewScaleHover.hovered || previewScaleControl.activeFocus
                        text: "Changes the embedded phone preview size."
                    }
                }
            }

            Column {
                width: parent.width
                spacing: Style.space(6)

                Row {
                    width: parent.width

                    Text {
                        width: parent.width - qualityValue.width
                        text: "Quality"
                        color: root.foreground
                        font.family: Style.fontFamily
                        font.pixelSize: Style.fontBaseSize
                        font.bold: true
                    }

                    Text {
                        id: qualityValue
                        text: root.qualityLabel(root.videoQuality)
                        color: Qt.darker(root.foreground, 1.25)
                        font.family: Style.fontFamily
                        font.pixelSize: Style.fontBaseSize
                    }
                }

                Row {
                    id: qualityButtons
                    width: parent.width
                    spacing: Style.space(6)

                    Repeater {
                        model: root.qualityOptions

                        Button {
                            required property var modelData
                            width: (qualityButtons.width - qualityButtons.spacing * 2) / 3
                            text: modelData.label
                            selected: root.videoQuality === modelData.value
                            bordered: true
                            focusable: true
                            foreground: root.foreground
                            tooltipText: "Restarts mirroring; pairing stays intact."
                            onClicked: root.request(root.keepConnected, root.previewScale, modelData.value, root.quickActions, root.androidModeShortcuts, root.commandPassthrough)
                        }
                    }
                }
            }

            PanelSeparator {
                foreground: root.foreground
            }

            PanelSectionHeader {
                width: parent.width
                text: "QUICK ACTIONS"
                foreground: root.foreground
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
                    onChanged: function (value) {
                        root.replaceAction(index, value);
                    }
                }
            }

            PanelSeparator {
                foreground: root.foreground
            }

            PanelSectionHeader {
                width: parent.width
                text: "PHONE"
                foreground: root.foreground
            }

            Column {
                width: parent.width
                spacing: Style.space(6)

                Text {
                    width: parent.width
                    text: "Pair a different phone"
                    color: root.foreground
                    font.family: Style.fontFamily
                    font.pixelSize: Style.fontBaseSize
                    font.bold: true
                }

                Button {
                    objectName: "startOverButton"
                    width: parent.width
                    text: "Start over"
                    bordered: true
                    focusable: true
                    foreground: root.foreground
                    tooltipText: "Stops this session and forgets this phone on this computer."
                    onClicked: root.startOverRequested()
                }
            }
        }
    }
}
