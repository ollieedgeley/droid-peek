pragma ComponentBehavior: Bound
import QtQuick
import QtMultimedia
import qs.Commons

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
    property var retainedImageResult: null
    property bool retainedImageCapturePending: false
    property var retainedImageGrabber: null
    property int retainedImageCaptureSerial: 0
    property int pendingRetainedCaptureEpoch: -1
    property string pendingRetainedHelperEpoch: ""
    property string pendingRetainedSessionGeneration: ""
    property int presentationSerial: 0
    property bool retainedImageReleasePending: false
    property int retainedImageReleaseSerial: -1
    property bool liveFormatRefreshArmed: false
    property bool liveFormatRefreshScheduled: false
    property int scheduledLiveFormatRefreshEpoch: -1
    property string scheduledLiveFormatRefreshHelperEpoch: ""
    property string scheduledLiveFormatRefreshSessionGeneration: ""
    property int capturePipelineReleaseDelayMs: 100
    property bool capturePipelineCreationPending: false
    property int pendingCapturePipelineEpoch: -1
    property string pendingCapturePipelineHelperEpoch: ""
    property string pendingCapturePipelineSessionGeneration: ""
    readonly property bool retainedImageAvailable: retainedImageResult !== null
    readonly property var capturePipeline: captureLoader.item
    readonly property int deviceIndex: findDeviceIndex(videoInputs, deviceId, deviceDescription)
    readonly property bool deviceAvailable: deviceIndex >= 0
    readonly property bool captureAvailable: deviceAvailable && captureSourceAcknowledged
    readonly property bool active: capturePipeline !== null && capturePipeline.cameraActive
    readonly property bool inputFocused: activeFocus
    readonly property bool previewInputEnabled: inputEnabled && captureRequested
    readonly property bool inputActive: previewInputEnabled && applicationState === "interactive"
    readonly property rect displayedContent: capturePipeline !== null ? capturePipeline.contentRect : Qt.rect(0, 0, 0, 0)
    readonly property int displayWidth: framedWidth > 0 ? framedWidth : (capturePipeline !== null ? Math.round(capturePipeline.sourceRect.width) : 0)
    readonly property int displayHeight: framedHeight > 0 ? framedHeight : (capturePipeline !== null ? Math.round(capturePipeline.sourceRect.height) : 0)

    signal tapRequested(real x, real y, int displayWidth, int displayHeight, string helperEpoch, string sessionGeneration)
    signal swipeRequested(real startX, real startY, real endX, real endY, int displayWidth, int displayHeight, int durationMs, string helperEpoch, string sessionGeneration)
    signal keyRequested(string key, string helperEpoch, string sessionGeneration)
    signal textRequested(string text, string helperEpoch, string sessionGeneration)
    signal retainedImageCaptureCompleted(bool retained, int captureEpoch, string helperEpoch, string sessionGeneration)

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
        if (contentRect.width <= 0 || contentRect.height <= 0 || x < contentRect.x || y < contentRect.y || x > contentRect.x + contentRect.width || y > contentRect.y + contentRect.height)
            return null;
        return Qt.point((x - contentRect.x) / contentRect.width, (y - contentRect.y) / contentRect.height);
    }

    function dispatchPointer(startX, startY, endX, endY, durationMs, contentRect, sourceWidth, sourceHeight, eventHelperEpoch, eventSessionGeneration) {
        eventHelperEpoch = eventHelperEpoch === undefined ? helperEpoch : eventHelperEpoch;
        eventSessionGeneration = eventSessionGeneration === undefined ? sessionGeneration : eventSessionGeneration;
        if (sourceWidth <= 0 || sourceHeight <= 0 || eventHelperEpoch !== helperEpoch || eventSessionGeneration !== sessionGeneration || !validIdentity(eventHelperEpoch) || !validIdentity(eventSessionGeneration))
            return false;
        var start = normalizedPoint(startX, startY, contentRect);
        var end = normalizedPoint(endX, endY, contentRect);
        if (start === null || end === null)
            return false;
        var distance = Math.hypot(endX - startX, endY - startY);
        if (distance <= 8) {
            tapRequested(end.x, end.y, sourceWidth, sourceHeight, eventHelperEpoch, eventSessionGeneration);
        } else {
            swipeRequested(start.x, start.y, end.x, end.y, sourceWidth, sourceHeight, Math.max(1, Math.min(60000, Math.round(durationMs))), eventHelperEpoch, eventSessionGeneration);
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
        if (!inputActive || !validIdentity(helperEpoch) || !validIdentity(sessionGeneration))
            return false;
        var compositorModifiers = Qt.ControlModifier | Qt.AltModifier | Qt.MetaModifier;
        if (modifiers & compositorModifiers)
            return false;
        var androidKey = androidKeyForQtKey(keyCode);
        if (androidKey !== "") {
            if (modifiers & Qt.ShiftModifier)
                return false;
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

    function clearPendingRetainedImageCapture() {
        retainedImageCapturePending = false;
        pendingRetainedCaptureEpoch = -1;
        pendingRetainedHelperEpoch = "";
        pendingRetainedSessionGeneration = "";
    }

    function clearRetainedImageRelease() {
        retainedImageReleasePending = false;
        retainedImageReleaseSerial = -1;
    }

    function completeRetainedImageRelease() {
        if (!retainedImageReleasePending)
            return false;
        var releaseIsCurrent = inputEnabled && retainedImageReleaseSerial === presentationSerial;
        clearRetainedImageRelease();
        if (releaseIsCurrent)
            retainedImageResult = null;
        return releaseIsCurrent;
    }

    function cancelPendingRetainedImageCapture() {
        var wasPending = retainedImageCapturePending;
        var capturedEpoch = pendingRetainedCaptureEpoch;
        var capturedHelperEpoch = pendingRetainedHelperEpoch;
        var capturedSessionGeneration = pendingRetainedSessionGeneration;
        if (wasPending)
            ++retainedImageCaptureSerial;
        clearPendingRetainedImageCapture();
        clearRetainedImageRelease();
        retainedImageResult = null;
        if (wasPending)
            retainedImageCaptureCompleted(false, capturedEpoch, capturedHelperEpoch, capturedSessionGeneration);
    }

    function resetCurrentCaptureReadiness() {
        cancelPendingRetainedImageCapture();
        captureSourceAcknowledged = false;
        firstValidFrameReceived = false;
        framedWidth = 0;
        framedHeight = 0;
    }

    function completeRetainedImageCapture(serial, result) {
        if (!retainedImageCapturePending || serial !== retainedImageCaptureSerial)
            return false;
        var capturedEpoch = pendingRetainedCaptureEpoch;
        var capturedHelperEpoch = pendingRetainedHelperEpoch;
        var capturedSessionGeneration = pendingRetainedSessionGeneration;
        clearPendingRetainedImageCapture();
        var identityIsCurrent = capturedEpoch === captureEpoch && capturedHelperEpoch === helperEpoch && capturedSessionGeneration === sessionGeneration;
        var retained = identityIsCurrent && result !== null && result !== undefined && result.url !== undefined;
        clearRetainedImageRelease();
        retainedImageResult = retained ? result : null;
        retainedImageCaptureCompleted(retained, capturedEpoch, capturedHelperEpoch, capturedSessionGeneration);
        return retained;
    }

    function captureRetainedImage() {
        var pipeline = capturePipeline;
        if (retainedImageAvailable || retainedImageCapturePending || !captureRequested || !captureSourceAcknowledged || !firstValidFrameReceived || framedWidth <= 0 || framedHeight <= 0 || pipeline === null || pipeline.epoch !== captureEpoch || pipeline.helperEpochSnapshot !== helperEpoch || pipeline.sessionGenerationSnapshot !== sessionGeneration || !validIdentity(helperEpoch) || !validIdentity(sessionGeneration))
            return false;
        var videoOutput = pipeline.videoOutputItem;
        var targetWidth = Math.round(videoOutput.width);
        var targetHeight = Math.round(videoOutput.height);
        if (targetWidth <= 0 || targetHeight <= 0)
            return false;

        var serial = ++retainedImageCaptureSerial;
        retainedImageCapturePending = true;
        pendingRetainedCaptureEpoch = captureEpoch;
        pendingRetainedHelperEpoch = helperEpoch;
        pendingRetainedSessionGeneration = sessionGeneration;
        var callback = function (result) {
            root.completeRetainedImageCapture(serial, result);
        };
        var targetSize = Qt.size(targetWidth, targetHeight);
        var started = false;
        try {
            started = typeof retainedImageGrabber === "function" ? retainedImageGrabber(callback, targetSize) : videoOutput.grabToImage(callback, targetSize);
        } catch (error) {
            started = false;
        }
        if (!started && retainedImageCapturePending && serial === retainedImageCaptureSerial) {
            ++retainedImageCaptureSerial;
            clearPendingRetainedImageCapture();
            retainedImageResult = null;
        }
        return started;
    }

    function handleCaptureActivityChanged(epoch, isActive) {
        if (epoch === captureEpoch && !isActive)
            resetCurrentCaptureReadiness();
    }

    function handleCaptureFailure(epoch) {
        if (epoch === captureEpoch)
            resetCurrentCaptureReadiness();
    }

    function clearScheduledLiveFormatRefresh() {
        liveFormatRefreshScheduled = false;
        scheduledLiveFormatRefreshEpoch = -1;
        scheduledLiveFormatRefreshHelperEpoch = "";
        scheduledLiveFormatRefreshSessionGeneration = "";
    }

    function armLiveFormatRefresh() {
        clearScheduledLiveFormatRefresh();
        liveFormatRefreshArmed = true;
    }

    function completeLiveFormatRefresh(epoch, eventHelperEpoch, eventSessionGeneration) {
        if (!liveFormatRefreshScheduled || scheduledLiveFormatRefreshEpoch !== epoch || scheduledLiveFormatRefreshHelperEpoch !== eventHelperEpoch || scheduledLiveFormatRefreshSessionGeneration !== eventSessionGeneration)
            return false;
        var refreshIsCurrent = epoch === captureEpoch && eventHelperEpoch === helperEpoch && eventSessionGeneration === sessionGeneration && captureRequested;
        clearScheduledLiveFormatRefresh();
        if (!refreshIsCurrent)
            return false;
        releaseCapturePipeline();
        return true;
    }

    function scheduleLiveFormatRefresh(epoch, eventHelperEpoch, eventSessionGeneration) {
        liveFormatRefreshArmed = false;
        liveFormatRefreshScheduled = true;
        scheduledLiveFormatRefreshEpoch = epoch;
        scheduledLiveFormatRefreshHelperEpoch = eventHelperEpoch;
        scheduledLiveFormatRefreshSessionGeneration = eventSessionGeneration;
        Qt.callLater(function () {
            root.completeLiveFormatRefresh(epoch, eventHelperEpoch, eventSessionGeneration);
        });
    }

    function clearPendingCapturePipelineCreation() {
        capturePipelineReleaseTimer.stop();
        capturePipelineCreationPending = false;
        pendingCapturePipelineEpoch = -1;
        pendingCapturePipelineHelperEpoch = "";
        pendingCapturePipelineSessionGeneration = "";
    }

    function cancelPendingCapturePipelineCreation() {
        clearPendingCapturePipelineCreation();
    }

    function createCapturePipeline(pipelineEpoch, pipelineHelperEpoch, pipelineSessionGeneration) {
        if (pipelineEpoch !== captureEpoch || pipelineHelperEpoch !== helperEpoch || pipelineSessionGeneration !== sessionGeneration)
            return false;
        captureLoader.sourceComponent = capturePipelineComponent;
        if (captureLoader.item === null)
            return false;
        captureLoader.item.epoch = pipelineEpoch;
        captureLoader.item.helperEpochSnapshot = pipelineHelperEpoch;
        captureLoader.item.sessionGenerationSnapshot = pipelineSessionGeneration;
        captureLoader.item.initialized = true;
        return true;
    }

    function scheduleCapturePipelineCreation(pipelineEpoch, pipelineHelperEpoch, pipelineSessionGeneration) {
        capturePipelineReleaseTimer.stop();
        pendingCapturePipelineEpoch = pipelineEpoch;
        pendingCapturePipelineHelperEpoch = pipelineHelperEpoch;
        pendingCapturePipelineSessionGeneration = pipelineSessionGeneration;
        capturePipelineCreationPending = true;
        capturePipelineReleaseTimer.restart();
    }

    function completeCapturePipelineCreation() {
        if (!capturePipelineCreationPending)
            return false;
        var pipelineEpoch = pendingCapturePipelineEpoch;
        var pipelineHelperEpoch = pendingCapturePipelineHelperEpoch;
        var pipelineSessionGeneration = pendingCapturePipelineSessionGeneration;
        var creationIsCurrent = pipelineEpoch === captureEpoch
                && pipelineHelperEpoch === helperEpoch
                && pipelineSessionGeneration === sessionGeneration
                && captureRequested;
        clearPendingCapturePipelineCreation();
        if (!creationIsCurrent)
            return false;
        return createCapturePipeline(pipelineEpoch, pipelineHelperEpoch, pipelineSessionGeneration);
    }

    function releaseCapturePipeline() {
        var pipelineEpoch = ++captureEpoch;
        resetCurrentCaptureReadiness();
        captureLoader.sourceComponent = null;
        scheduleCapturePipelineCreation(pipelineEpoch, helperEpoch, sessionGeneration);
    }

    function recreateCapturePipelineInternal() {
        clearScheduledLiveFormatRefresh();
        if (captureRequested) {
            releaseCapturePipeline();
            return;
        }
        var pipelineEpoch = ++captureEpoch;
        resetCurrentCaptureReadiness();
        captureLoader.sourceComponent = null;
        cancelPendingCapturePipelineCreation();
        createCapturePipeline(pipelineEpoch, helperEpoch, sessionGeneration);
    }

    function recreateCapturePipeline() {
        armLiveFormatRefresh();
        if (capturePipelineCreationPending || (captureRequested && captureLoader.item === null)) {
            recreateCapturePipelineInternal();
            return;
        }
        var pipelineEpoch = ++captureEpoch;
        resetCurrentCaptureReadiness();
        captureLoader.sourceComponent = null;
        cancelPendingCapturePipelineCreation();
        createCapturePipeline(pipelineEpoch, helperEpoch, sessionGeneration);
    }

    function acceptCaptureSource(epoch, eventHelperEpoch, eventSessionGeneration, id, description) {
        if (epoch !== captureEpoch || eventHelperEpoch !== helperEpoch || eventSessionGeneration !== sessionGeneration || !captureRequested || id !== deviceId || description !== deviceDescription)
            return false;
        captureSourceAcknowledged = true;
        return true;
    }
    function acceptRenderedFrame(epoch, eventHelperEpoch, eventSessionGeneration, width, height, newVideoFrame) {
        if (newVideoFrame !== true || epoch !== captureEpoch || eventHelperEpoch !== helperEpoch || eventSessionGeneration !== sessionGeneration || !captureRequested || !captureSourceAcknowledged || width <= 0 || height <= 0)
            return false;
        if (liveFormatRefreshScheduled)
            return false;
        if (liveFormatRefreshArmed) {
            scheduleLiveFormatRefresh(epoch, eventHelperEpoch, eventSessionGeneration);
            return false;
        }
        framedWidth = width;
        framedHeight = height;
        firstValidFrameReceived = true;
        if (inputEnabled && retainedImageAvailable) {
            retainedImageReleasePending = true;
            retainedImageReleaseSerial = presentationSerial;
        }
        return true;
    }

    Keys.onPressed: function (event) {
        event.accepted = root.dispatchKeyEvent(event.key, event.modifiers, event.text);
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
    onInputEnabledChanged: {
        ++presentationSerial;
        if (!inputEnabled)
            clearRetainedImageRelease();
    }
    onCaptureRequestedChanged: {
        if (!captureRequested) {
            clearScheduledLiveFormatRefresh();
            liveFormatRefreshArmed = false;
            cancelPendingCapturePipelineCreation();
            resetCurrentCaptureReadiness();
        } else {
            recreateCapturePipeline();
        }
    }
    onDeviceIndexChanged: recreateCapturePipeline()
    onHelperEpochChanged: recreateCapturePipeline()
    onSessionGenerationChanged: recreateCapturePipeline()
    Component.onCompleted: {
        if (capturePipeline === null && !capturePipelineCreationPending)
            recreateCapturePipeline();
    }

    MediaDevices {
        id: mediaDevices
    }

    Timer {
        id: capturePipelineReleaseTimer
        interval: root.capturePipelineReleaseDelayMs
        repeat: false
        onTriggered: root.completeCapturePipelineCreation()
    }

    // The shell may cache the loopback's pre-producer format. Reopen the
    // camera once after scrcpy has negotiated the live sink format.
    Timer {
        interval: 750
        repeat: false
        running: root.captureRequested && root.deviceAvailable && !root.firstValidFrameReceived && !root.capturePipelineCreationPending
        onTriggered: root.recreateCapturePipelineInternal()
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
            readonly property string sourceDeviceId: root.cameraIdString(camera.cameraDevice.id)
            readonly property string sourceDeviceDescription: camera.cameraDevice.description
            readonly property rect sourceRect: videoOutput.sourceRect
            readonly property var videoOutputItem: videoOutput

            Camera {
                id: camera
                cameraDevice: root.deviceAvailable ? root.videoInputs[root.deviceIndex] : mediaDevices.defaultVideoInput
                active: pipeline.initialized && root.captureRequested && root.deviceAvailable
                onCameraDeviceChanged: {
                    root.acceptCaptureSource(pipeline.epoch, pipeline.helperEpochSnapshot, pipeline.sessionGenerationSnapshot, pipeline.sourceDeviceId, pipeline.sourceDeviceDescription);
                }
                onActiveChanged: {
                    if (active) {
                        root.acceptCaptureSource(pipeline.epoch, pipeline.helperEpochSnapshot, pipeline.sessionGenerationSnapshot, pipeline.sourceDeviceId, pipeline.sourceDeviceDescription);
                    }
                    root.handleCaptureActivityChanged(pipeline.epoch, active);
                }
                onErrorOccurred: root.handleCaptureFailure(pipeline.epoch)
            }

            CaptureSession {
                camera: camera
                videoOutput: videoOutput
            }

            VideoOutput {
                id: videoOutput
                objectName: "phoneVideoOutput"
                anchors.fill: parent
                fillMode: VideoOutput.PreserveAspectFit
                onSourceRectChanged: root.acceptRenderedFrame(pipeline.epoch, pipeline.helperEpochSnapshot, pipeline.sessionGenerationSnapshot, sourceRect.width, sourceRect.height)
            }

            Image {
                id: retainedPreviewImage
                objectName: "retainedPreviewImage"
                z: 1
                anchors.fill: parent
                source: root.retainedImageAvailable ? root.retainedImageResult.url : ""
                fillMode: Image.PreserveAspectFit
                visible: root.retainedImageAvailable
                cache: false
            }

            Connections {
                target: root.Window.window
                enabled: root.retainedImageReleasePending

                function onFrameSwapped() {
                    root.completeRetainedImageRelease();
                }
            }

            Connections {
                target: videoOutput.videoSink

                function onVideoFrameChanged() {
                    var size = videoOutput.videoSink.videoSize;
                    root.acceptRenderedFrame(pipeline.epoch, pipeline.helperEpochSnapshot, pipeline.sessionGenerationSnapshot, size.width, size.height, true);
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
            root.dispatchPointer(pressX, pressY, mouse.x, mouse.y, Date.now() - pressedAt, root.displayedContent, root.displayWidth, root.displayHeight, pressHelperEpoch, pressSessionGeneration);
        }
    }

    Text {
        visible: root.captureRequested && !root.deviceAvailable
        anchors.centerIn: parent
        width: parent.width * 0.8
        color: root.foreground
        text: "Android device video unavailable"
        horizontalAlignment: Text.AlignHCenter
        wrapMode: Text.Wrap
    }
}
