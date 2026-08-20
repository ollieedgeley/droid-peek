pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import qs.Commons
import qs.Ui

NestedEscapeScope {
    id: toolbarRoot

    property var bar: null
    property var actions: ["back", "home", "recent-apps"]
    property bool keepConnected: false
    property bool settingsOpen: false
    property string applicationState: "closed"
    readonly property bool controlsEnabled: applicationState === "interactive"
    property color foreground: Color.foreground
    readonly property var barMetrics: Style.bar
    readonly property var guiStyleHints: Qt.styleHints

    signal actionRequested(string action)
    signal settingsRequested
    signal keepConnectedRequested(bool keepConnected)
    signal backRequested

    escapeEnabled: settingsOpen
    onEscapeRequested: toolbarRoot.backRequested()

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
            return "\uf053";
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

    component ToolbarIconButton: BarIconButton {
        id: toolbarButton
        property double lastPointerActivationAt: 0
        property bool keyboardActivationInProgress: false

        signal activated

        bar: toolbarRoot.bar
        fixedWidth: toolbarRoot.barMetrics.iconSlot
        fixedHeight: toolbarRoot.barMetrics.sizeHorizontal
        activeFocusOnTab: true
        PanelToolTip {
            objectName: toolbarButton.objectName + "-tooltip"
            visible: toolbarButton.tooltipHovered && toolbarButton.tooltipText !== ""
            text: toolbarButton.tooltipText
        }

        function activateFromKeyboard(event) {
            if (!enabled || !interactive)
                return;
            keyboardActivationInProgress = true;
            triggerPress(Qt.LeftButton);
            keyboardActivationInProgress = false;
            event.accepted = true;
        }

        function acceptActivation(button) {
            if (button !== Qt.LeftButton || !enabled || !interactive)
                return false;
            if (keyboardActivationInProgress)
                return true;

            var now = Date.now();
            if (now - lastPointerActivationAt <= toolbarRoot.guiStyleHints.mouseDoubleClickInterval) {
                lastPointerActivationAt = 0;
                return false;
            }
            lastPointerActivationAt = now;
            return true;
        }

        onPressed: function (button) {
            if (acceptActivation(button))
                activated();
        }
        Keys.onReturnPressed: event => activateFromKeyboard(event)
        Keys.onEnterPressed: event => activateFromKeyboard(event)
        Keys.onSpacePressed: event => activateFromKeyboard(event)
    }

    implicitHeight: toolbarRoot.settingsOpen ? toolbar.implicitHeight : toolbarRoot.barMetrics.sizeHorizontal

    Rectangle {
        id: toolbarSurface
        objectName: "toolbarSurface"
        anchors.fill: parent
        color: !toolbarRoot.settingsOpen && toolbarRoot.bar && !toolbarRoot.bar.transparent ? toolbarRoot.bar.background : "transparent"

        MouseArea {
            anchors.fill: parent
            acceptedButtons: Qt.LeftButton
            enabled: !toolbarRoot.settingsOpen && toolbarRoot.bar !== null

            onDoubleClicked: function (mouse) {
                if (mouse.button === Qt.LeftButton) {
                    toolbarRoot.bar.toggleTransparency();
                    mouse.accepted = true;
                }
            }
        }
    }

    RowLayout {
        id: toolbar
        z: 1
        anchors.fill: parent
        spacing: 0

        PanelActionButton {
            id: settingsBackButton
            objectName: "settingsBackButton"
            visible: toolbarRoot.settingsOpen
            focusable: true
            bordered: true
            iconText: "\uf053"
            tooltipText: "Back to device"
            foreground: toolbarRoot.foreground
            onClicked: toolbarRoot.backRequested()
        }

        Text {
            visible: toolbarRoot.settingsOpen
            Layout.leftMargin: Style.space(6)
            text: "Settings"
            color: toolbarRoot.foreground
            font.family: Style.fontFamily
            font.pixelSize: Style.fontBaseSize
            font.bold: true
        }

        Repeater {
            model: toolbarRoot.settingsOpen ? [] : toolbarRoot.actions

            ToolbarIconButton {
                required property string modelData
                objectName: "quickActionButton-" + modelData
                interactive: toolbarRoot.controlsEnabled
                enabled: toolbarRoot.controlsEnabled
                text: toolbarRoot.actionIcon(modelData)
                tooltipText: toolbarRoot.actionLabel(modelData)
                onActivated: toolbarRoot.actionRequested(modelData)
            }
        }

        Item {
            Layout.fillWidth: true
            implicitWidth: 0
            implicitHeight: 1
        }

        ToolbarIconButton {
            objectName: "keepConnectedButton"
            visible: !toolbarRoot.settingsOpen
            text: "󰌷"
            tooltipText: toolbarRoot.keepConnected ? "Keep connected when panel closes: on" : "Keep connected when panel closes: off"
            dimmed: !toolbarRoot.keepConnected
            useActiveColor: false
            onActivated: toolbarRoot.keepConnectedRequested(!toolbarRoot.keepConnected)
        }

        ToolbarIconButton {
            objectName: "settingsButton"
            visible: !toolbarRoot.settingsOpen
            text: "󰒓"
            tooltipText: "Settings"
            onActivated: toolbarRoot.settingsRequested()
        }
    }
}
