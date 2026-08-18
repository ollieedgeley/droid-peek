function closeAction(helperRunning, sessionMayExist, keepConnected) {
    if (!helperRunning)
        return "none"
    if (!sessionMayExist)
        return "cancel-pairing"
    return keepConnected ? "retain" : "stop-session"
}
