function closeAction(keepConnected, sessionState, pairingStage, helperRunning) {
    if (!helperRunning)
        return "none"

    if (keepConnected
            && (sessionState === "ready"
                || pairingStage === "connected"
                || pairingStage === "session-starting"))
        return "retain"

    if (sessionState === "ready"
            || pairingStage === "connected"
            || pairingStage === "session-starting")
        return "stop-session"

    return "cancel-pairing"
}
