import QtQuick
import QtMultimedia
import qs.Commons

pragma ComponentBehavior: Bound

Item {
    id: root

    property bool captureRequested: false
    property bool inputEnabled: false
    property string helperEpoch: ""
    property string sessionGeneration: "0"
    property string applicationState: "closed"
    readonly property string deviceId: "/dev/video42"
    readonly property string deviceDescription: "Droid Peek"
    property var videoInputs: mediaDevices.videoInputs
    readonly property var popupPalette: Color.popups
    property color foreground: popupPalette.text
    property color background: popupPalette.background
    property bool firstValidFrameReceived: false
    property bool captureSourceAcknowledged: false
    property int captureEpoch: 0
    property int framedWidth: 0
    property int framedHeight: 0
    readonly property var capturePipeline: captureLoader.item
    readonly property int deviceIndex: findDeviceIndex(
                                           videoInputs, deviceId,
                                           deviceDescription)
    readonly property bool deviceAvailable: deviceIndex >= 0
    readonly property bool captureAvailable: deviceAvailable
                                                && captureSourceAcknowledged
    readonly property bool active: capturePipeline !== null
                                      && capturePipeline.cameraActive
    readonly property bool inputFocused: activeFocus
    readonly property bool previewInputEnabled: inputEnabled && captureRequested
    readonly property bool inputActive: previewInputEnabled
                                          && applicationState === "interactive"
    readonly property rect displayedContent: capturePipeline !== null
                                                ? capturePipeline.contentRect
                                                : Qt.rect(0, 0, 0, 0)
    readonly property int displayWidth: framedWidth > 0
                                            ? framedWidth
                                            : (capturePipeline !== null
                                               ? Math.round(capturePipeline.sourceRect.width)
                                               : 0)
    readonly property int displayHeight: framedHeight > 0
                                             ? framedHeight
                                             : (capturePipeline !== null
                                                ? Math.round(capturePipeline.sourceRect.height)
                                                : 0)
    readonly property bool interactionReady: captureAvailable && active
                                                && firstValidFrameReceived
                                                && displayWidth > 0
                                                && displayHeight > 0
                                                && previewInputEnabled

    signal tapRequested(real x, real y, int displayWidth, int displayHeight,
                        string helperEpoch, string sessionGeneration)
    signal swipeRequested(real startX, real startY, real endX, real endY,
                          int displayWidth, int displayHeight, int durationMs,
                          string helperEpoch, string sessionGeneration)
    signal keyRequested(string key, string helperEpoch,
                        string sessionGeneration)
    signal textRequested(string text, string helperEpoch,
                         string sessionGeneration)

    implicitWidth: 240
    implicitHeight: 360
    clip: true
    activeFocusOnTab: inputActive

    function cameraIdString(value) {
        return String(value);
    }


    function findDeviceIndex(inputs, id, description) {
        var matchIndex = -1;
        var idMatches = 0;
        for (var index = 0; index < inputs.length; ++index) {
            if (cameraIdString(inputs[index].id) !== id)
                continue;
            ++idMatches;
            if (inputs[index].description === description)
                matchIndex = index;
        }
        return idMatches === 1 ? matchIndex : -1;
    }

    function validIdentity(value) {
        return typeof value === "string" && /^(0|[1-9][0-9]*)$/.test(value);
    }

    function normalizedPoint(x, y, contentRect) {
        if (contentRect.width <= 0 || contentRect.height <= 0
                || x < contentRect.x || y < contentRect.y
                || x > contentRect.x + contentRect.width
                || y > contentRect.y + contentRect.height)
            return null;
        return Qt.point((x - contentRect.x) / contentRect.width,
                        (y - contentRect.y) / contentRect.height);
    }

    function dispatchPointer(startX, startY, endX, endY, durationMs,
                             contentRect, sourceWidth, sourceHeight,
                             eventHelperEpoch, eventSessionGeneration) {
        eventHelperEpoch = eventHelperEpoch === undefined
                ? helperEpoch : eventHelperEpoch;
        eventSessionGeneration = eventSessionGeneration === undefined
                ? sessionGeneration : eventSessionGeneration;
        if (sourceWidth <= 0 || sourceHeight <= 0
                || eventHelperEpoch !== helperEpoch
                || eventSessionGeneration !== sessionGeneration
                || !validIdentity(eventHelperEpoch)
                || !validIdentity(eventSessionGeneration))
            return false;
        var start = normalizedPoint(startX, startY, contentRect);
        var end = normalizedPoint(endX, endY, contentRect);
        if (start === null || end === null)
            return false;
        var distance = Math.hypot(endX - startX, endY - startY);
        if (distance <= 8) {
            tapRequested(end.x, end.y, sourceWidth, sourceHeight,
                         eventHelperEpoch, eventSessionGeneration);
        } else {
            swipeRequested(start.x, start.y, end.x, end.y,
                           sourceWidth, sourceHeight,
                           Math.max(1, Math.min(60000,
                                                Math.round(durationMs))),
                           eventHelperEpoch, eventSessionGeneration);
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

    function dispatchKeyEvent(keyCode, modifiers, text) {
        if (!inputActive || !validIdentity(helperEpoch)
                || !validIdentity(sessionGeneration))
            return false;
        var compositorModifiers = Qt.ControlModifier | Qt.AltModifier
                | Qt.MetaModifier | Qt.ShiftModifier;
        if (modifiers & compositorModifiers)
            return false;
        var androidKey = androidKeyForQtKey(keyCode);
        if (androidKey !== "") {
            keyRequested(androidKey, helperEpoch, sessionGeneration);
            return true;
        }
        if (text !== "" && text.length <= 2) {
            textRequested(text, helperEpoch, sessionGeneration);
            return true;
        }
        return false;
    }

    function applyInputFocus(focused) {
        if (focused)
            forceActiveFocus();
        else
            focus = false;
    }

    function resetCurrentCaptureReadiness() {
        captureSourceAcknowledged = false;
        firstValidFrameReceived = false;
        framedWidth = 0;
        framedHeight = 0;
    }

    function recreateCapturePipeline() {
        resetCurrentCaptureReadiness();
        var pipelineEpoch = ++captureEpoch;
        captureLoader.sourceComponent = null;
        captureLoader.sourceComponent = capturePipelineComponent;
        if (captureLoader.item !== null) {
            captureLoader.item.epoch = pipelineEpoch;
            captureLoader.item.helperEpochSnapshot = helperEpoch;
            captureLoader.item.sessionGenerationSnapshot = sessionGeneration;
            captureLoader.item.initialized = true;
        }
    }

    function acceptCaptureSource(epoch, eventHelperEpoch,
                                 eventSessionGeneration, id, description) {
        if (epoch !== captureEpoch
                || eventHelperEpoch !== helperEpoch
                || eventSessionGeneration !== sessionGeneration
                || !captureRequested
                || id !== deviceId || description !== deviceDescription)
            return false;
        captureSourceAcknowledged = true;
        return true;
    }

    function acceptRenderedFrame(epoch, eventHelperEpoch,
                                 eventSessionGeneration, width, height) {
        if (epoch !== captureEpoch
                || eventHelperEpoch !== helperEpoch
                || eventSessionGeneration !== sessionGeneration
                || !captureRequested || !captureSourceAcknowledged
                || width <= 0 || height <= 0)
            return false;
        framedWidth = width;
        framedHeight = height;
        firstValidFrameReceived = true;
        return true;
    }

    Keys.onPressed: function (event) {
        event.accepted = root.dispatchKeyEvent(event.key, event.modifiers,
                                               event.text);
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
    onCaptureRequestedChanged: {
        if (!captureRequested) {
            resetCurrentCaptureReadiness();
        } else if (capturePipeline !== null) {
            acceptCaptureSource(capturePipeline.epoch,
                                capturePipeline.helperEpochSnapshot,
                                capturePipeline.sessionGenerationSnapshot,
                                capturePipeline.sourceDeviceId,
                                capturePipeline.sourceDeviceDescription);
        }
    }
    onDeviceIndexChanged: recreateCapturePipeline()
    onHelperEpochChanged: recreateCapturePipeline()
    onSessionGenerationChanged: recreateCapturePipeline()
    Component.onCompleted: recreateCapturePipeline()

    MediaDevices {
        id: mediaDevices
    }

    // The shell may cache the loopback's pre-producer format. Reopen the
    // camera once after scrcpy has negotiated the live sink format.
    Timer {
        interval: 750
        repeat: false
        running: root.captureRequested && root.deviceAvailable
                 && !root.firstValidFrameReceived
        onTriggered: root.recreateCapturePipeline()
    }




    Component {
        id: capturePipelineComponent

        Item {
            id: pipeline
            property int epoch: -1
            property string helperEpochSnapshot: ""
            property string sessionGenerationSnapshot: ""
            property bool initialized: false
            readonly property bool cameraActive: camera.active
            readonly property rect contentRect: videoOutput.contentRect
            readonly property string sourceDeviceId:
                root.cameraIdString(camera.cameraDevice.id)
            readonly property string sourceDeviceDescription:
                camera.cameraDevice.description
            readonly property rect sourceRect: videoOutput.sourceRect

            Camera {
                id: camera
                cameraDevice: root.deviceAvailable
                              ? root.videoInputs[root.deviceIndex]
                              : mediaDevices.defaultVideoInput
                active: pipeline.initialized && root.captureRequested
                        && root.deviceAvailable
                onCameraDeviceChanged: {
                    root.acceptCaptureSource(
                                pipeline.epoch,
                                pipeline.helperEpochSnapshot,
                                pipeline.sessionGenerationSnapshot,
                                pipeline.sourceDeviceId,
                                pipeline.sourceDeviceDescription);
                }
                onActiveChanged: {
                    if (active) {
                        root.acceptCaptureSource(
                                    pipeline.epoch,
                                    pipeline.helperEpochSnapshot,
                                    pipeline.sessionGenerationSnapshot,
                                    pipeline.sourceDeviceId,
                                    pipeline.sourceDeviceDescription);
                    } else if (pipeline.epoch === root.captureEpoch) {
                        root.resetCurrentCaptureReadiness();
                    }
                }
            }

            CaptureSession {
                camera: camera
                videoOutput: videoOutput
            }

            VideoOutput {
                id: videoOutput
                anchors.fill: parent
                fillMode: VideoOutput.PreserveAspectFit
                onSourceRectChanged: root.acceptRenderedFrame(
                                         pipeline.epoch,
                                         pipeline.helperEpochSnapshot,
                                         pipeline.sessionGenerationSnapshot,
                                         sourceRect.width,
                                         sourceRect.height)
            }

            Connections {
                target: videoOutput.videoSink

                function onVideoFrameChanged() {
                    var size = videoOutput.videoSink.videoSize;
                    root.acceptRenderedFrame(
                                pipeline.epoch,
                                pipeline.helperEpochSnapshot,
                                pipeline.sessionGenerationSnapshot,
                                size.width, size.height);
                }
            }
        }
    }

    Rectangle {
        anchors.fill: parent
        color: root.background
    }

    Loader {
        id: captureLoader
        anchors.fill: parent
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
        property string pressHelperEpoch: ""
        property string pressSessionGeneration: ""

        onPressed: function (mouse) {
            root.forceActiveFocus();
            pressX = mouse.x;
            pressY = mouse.y;
            pressedAt = Date.now();
            pressHelperEpoch = root.helperEpoch;
            pressSessionGeneration = root.sessionGeneration;
        }
        onReleased: function (mouse) {
            root.dispatchPointer(pressX, pressY, mouse.x, mouse.y,
                                 Date.now() - pressedAt,
                                 root.displayedContent,
                                 root.displayWidth, root.displayHeight,
                                 pressHelperEpoch, pressSessionGeneration);
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
