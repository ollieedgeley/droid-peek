import QtQuick

QtObject {
    id: root

    property bool panelOpen: false
    property bool managementOpen: false
    property bool helperReady: false
    property bool hasTrustedDevice: false
    property string helperEpoch: ""
    property string sessionGeneration: ""
    property bool sessionStarted: false
    property bool captureAvailable: false
    property bool captureActive: false
    property bool firstValidFrameReceived: false
    property int displayWidth: 0
    property int displayHeight: 0
    property bool previewInputEnabled: false
    property bool factsExternallyManaged: false
    property string helperActivity: ""
    property string helperReason: ""
    readonly property bool captureSurfaceRequired: panelOpen
                                                    && !managementOpen
                                                    && sessionStarted

    readonly property bool previewUsable: helperReady
                                                  && sessionStarted
                                                  && captureAvailable
                                                  && captureActive
                                                  && firstValidFrameReceived
                                                  && displayWidth > 0
                                                  && displayHeight > 0
                                                  && previewInputEnabled
    readonly property string availabilityState: !hasTrustedDevice
                                                    ? "setup"
                                                    : (previewUsable
                                                       ? "interactive"
                                                       : "recovering")
    readonly property string applicationState: !panelOpen
                                                   ? "closed"
                                                   : (managementOpen
                                                      ? "management"
                                                      : availabilityState)
    readonly property string activity: helperActivity !== ""
                                           ? helperActivity
                                           : (availabilityState === "recovering"
                                              && sessionStarted
                                              && !previewUsable
                                              ? "starting-preview"
                                              : "")
    readonly property string reason: helperReason

    function clearSessionFacts() {
        sessionStarted = false;
        captureAvailable = false;
        captureActive = false;
        firstValidFrameReceived = false;
        displayWidth = 0;
        displayHeight = 0;
        previewInputEnabled = false;
    }

    function reset() {
        panelOpen = false;
        managementOpen = false;
        if (!factsExternallyManaged) {
            helperReady = false;
            hasTrustedDevice = false;
            helperEpoch = "";
            sessionGeneration = "";
            helperActivity = "";
            helperReason = "";
            clearSessionFacts();
        }
    }

    onHelperEpochChanged: {
        if (!factsExternallyManaged) {
            helperReady = false;
            sessionGeneration = helperEpoch === "" ? "" : "0";
            helperActivity = "";
            helperReason = "";
            clearSessionFacts();
        }
    }

    onSessionGenerationChanged: {
        if (!factsExternallyManaged)
            clearSessionFacts();
    }
}
