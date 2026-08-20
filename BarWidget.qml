import QtQuick
import qs.Ui
import "qml/session/SessionRegistry.js" as SessionRegistry

BarWidget {
    id: root

    moduleName: "ollieedgeley.droidpeek"
    property var panel: null
    readonly property bool opened: panel && panel.opened === true
                                   && panel.hostWidget === root

    function bindSharedPanel() {
        SessionRegistry.ensurePanel(Qt.resolvedUrl("Panel.qml"), function (created) {
            root.panel = created
        })
    }

    function open() {
        SessionRegistry.ensurePanel(Qt.resolvedUrl("Panel.qml"), function (created) {
            root.panel = created
            if (!root.panel)
                return
            root.panel.hostWidget = root
            root.panel.anchorItem = button
            if ("bar" in root.panel)
                root.panel.bar = root.bar
            injectPanel()
            if (root.panel.opened !== true)
                root.panel.open()
        })
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
        if (opened)
            close();
        else
            open();
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
        if (!root.panel)
            bindSharedPanel();
        var request = decodePhoneTarget(encodedEnvelope);
        if (request === null || !root.panel
                || !("acceptPhoneTarget" in root.panel))
            return false;
        return root.panel.acceptPhoneTarget(request);
    }

    function configureScrcpy(revision, encodedConfiguration) {
        if (!root.panel)
            bindSharedPanel();
        var scrcpyArguments = decodeEnvelope(encodedConfiguration, 24000);
        if (typeof revision !== "string" || !/^[0-9a-f]{16}$/.test(revision)
                || scrcpyArguments === null || !root.panel
                || !("setScrcpyConfiguration" in root.panel))
            return false;
        return root.panel.setScrcpyConfiguration(revision, scrcpyArguments);
    }

    function injectPanel() {
        if (!root.panel) return
        if ("bar" in root.panel) root.panel.bar = root.bar
        if ("anchorItem" in root.panel) root.panel.anchorItem = button
        if ("hostWidget" in root.panel) root.panel.hostWidget = root
    }

    implicitWidth: button.implicitWidth
    implicitHeight: button.implicitHeight

    Component.onCompleted: {
        SessionRegistry.registerHost()
        bindSharedPanel()
    }
    Component.onDestruction: SessionRegistry.unregisterHost()
    onBarChanged: bindSharedPanel()

    WidgetButton {
        id: button
        anchors.fill: parent
        bar: root.bar
        text: "󰄜"
        tooltipText: "Droid Peek"
        onPressed: function(button) {
            if (button === Qt.LeftButton) root.togglePanel()
        }
    }
}
