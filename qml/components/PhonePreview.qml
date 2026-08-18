import QtQuick
import QtMultimedia

Item {
    id: root

    property bool captureRequested: false
    property bool inputEnabled: false
    readonly property string deviceId: "/dev/video42"
    readonly property string deviceDescription: "Omarchy Android"
    property color foreground: "white"
    property color background: "#101418"
    property bool firstValidFrameReceived: false
    readonly property int deviceIndex: findDeviceIndex(mediaDevices.videoInputs, deviceId, deviceDescription)
    readonly property bool deviceAvailable: deviceIndex >= 0
    readonly property bool active: camera.active
    readonly property bool inputFocused: activeFocus
    readonly property bool inputActive: inputEnabled && captureRequested && deviceAvailable
    readonly property rect displayedContent: videoOutput.contentRect
    readonly property int displayWidth: Math.round(videoOutput.sourceRect.width)
    readonly property int displayHeight: Math.round(videoOutput.sourceRect.height)
    readonly property bool interactionReady: active && firstValidFrameReceived
                                                && displayWidth > 0 && displayHeight > 0

    signal tapRequested(real x, real y, int displayWidth, int displayHeight)
    signal swipeRequested(real startX, real startY, real endX, real endY, int displayWidth, int displayHeight, int durationMs)
    signal keyRequested(string key)
    signal textRequested(string text)

    implicitWidth: 240
    implicitHeight: 360
    clip: true
    activeFocusOnTab: inputActive

    function findDeviceIndex(inputs, id, description) {
        var matchIndex = -1;
        var idMatches = 0;
        for (var index = 0; index < inputs.length; ++index) {
            if (inputs[index].id !== id)
                continue;
            ++idMatches;
            if (inputs[index].description === description)
                matchIndex = index;
        }
        return idMatches === 1 ? matchIndex : -1;
    }

    function normalizedPoint(x, y, contentRect) {
        if (contentRect.width <= 0 || contentRect.height <= 0 || x < contentRect.x || y < contentRect.y || x > contentRect.x + contentRect.width || y > contentRect.y + contentRect.height)
            return null;
        return Qt.point((x - contentRect.x) / contentRect.width, (y - contentRect.y) / contentRect.height);
    }

    function dispatchPointer(startX, startY, endX, endY, durationMs, contentRect, sourceWidth, sourceHeight) {
        if (sourceWidth <= 0 || sourceHeight <= 0)
            return false;
        var start = normalizedPoint(startX, startY, contentRect);
        var end = normalizedPoint(endX, endY, contentRect);
        if (start === null || end === null)
            return false;
        var distance = Math.hypot(endX - startX, endY - startY);
        if (distance <= 8) {
            tapRequested(end.x, end.y, sourceWidth, sourceHeight);
        } else {
            swipeRequested(start.x, start.y, end.x, end.y, sourceWidth, sourceHeight, Math.max(1, Math.min(60000, Math.round(durationMs))));
        }
        return true;
    }

    function androidKeyForQtKey(key) {
        switch (key) {
        case Qt.Key_Escape:
            return "back";
        case Qt.Key_Home:
            return "home";
        case Qt.Key_Return:
        case Qt.Key_Enter:
            return "enter";
        case Qt.Key_Backspace:
        case Qt.Key_Delete:
            return "delete";
        case Qt.Key_Up:
            return "arrow-up";
        case Qt.Key_Down:
            return "arrow-down";
        case Qt.Key_Left:
            return "arrow-left";
        case Qt.Key_Right:
            return "arrow-right";
        case Qt.Key_Tab:
        case Qt.Key_Backtab:
            return "tab";
        case Qt.Key_Space:
            return "space";
        default:
            return "";
        }
    }
    function applyInputFocus(active) {
        if (active)
            forceActiveFocus();
        else
            focus = false;
    }
    function resetCurrentCaptureReadiness() {
        firstValidFrameReceived = false;
    }

    Keys.onPressed: function (event) {
        if (!root.inputActive)
            return;
        var key = root.androidKeyForQtKey(event.key);
        if (key !== "") {
            root.keyRequested(key);
            event.accepted = true;
            return;
        }
        var blockedModifiers = Qt.ControlModifier | Qt.AltModifier | Qt.MetaModifier;
        if (!(event.modifiers & blockedModifiers) && event.text !== "" && event.text.length <= 2) {
            root.textRequested(event.text);
            event.accepted = true;
        }
    }

    onInputActiveChanged: {
        if (!inputActive) {
            applyInputFocus(false);
            return;
        }
        Qt.callLater(function () {
            root.applyInputFocus(root.inputActive);
        });
    }

    onCaptureRequestedChanged: resetCurrentCaptureReadiness()
    onDeviceIndexChanged: resetCurrentCaptureReadiness()
    onActiveChanged: {
        if (!active)
            resetCurrentCaptureReadiness();
    }

    MediaDevices {
        id: mediaDevices
    }

    CaptureSession {
        camera: Camera {
            id: camera
            cameraDevice: root.deviceAvailable ? mediaDevices.videoInputs[root.deviceIndex] : mediaDevices.defaultVideoInput
            onCameraDeviceChanged: root.resetCurrentCaptureReadiness()
            active: root.captureRequested && root.deviceAvailable
        }
        videoOutput: videoOutput
    }

    Rectangle {
        anchors.fill: parent
        color: root.background
    }

    VideoOutput {
        id: videoOutput
        anchors.fill: parent
        fillMode: VideoOutput.PreserveAspectFit
    }

    MouseArea {
        id: inputArea
        anchors.fill: parent
        enabled: root.inputActive
        acceptedButtons: Qt.LeftButton
        preventStealing: true
        property real pressX: 0
        property real pressY: 0
        property double pressedAt: 0

        onPressed: function (mouse) {
            root.forceActiveFocus();
            pressX = mouse.x;
            pressY = mouse.y;
            pressedAt = Date.now();
        }
        onReleased: function (mouse) {
            root.dispatchPointer(pressX, pressY, mouse.x, mouse.y, Date.now() - pressedAt, root.displayedContent, root.displayWidth, root.displayHeight);
        }
    }

    Connections {
        target: videoOutput.videoSink
        function onVideoFrameChanged(frame) {
            if (root.captureRequested && root.deviceAvailable && frame.isValid())
                root.firstValidFrameReceived = true;
        }
    }

    Text {
        visible: root.captureRequested && !root.deviceAvailable
        anchors.centerIn: parent
        width: parent.width * 0.8
        color: root.foreground
        text: "Phone video device unavailable"
        horizontalAlignment: Text.AlignHCenter
        wrapMode: Text.Wrap
    }
}
