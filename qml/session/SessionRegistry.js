.pragma library

var panel = null
var inflight = null
var waiters = []
var hostCount = 0

// QQmlComponent::Status. The JS library has no Component import.
var StatusReady = 1
var StatusError = 3

function ensurePanel(componentUrl, parent, onReady) {
    if (typeof onReady === "function")
        waiters.push(onReady)
    if (panel !== null) {
        flushWaiters()
        return panel
    }
    if (inflight === null)
        startLoad(componentUrl, parent)
    return panel
}

function startLoad(componentUrl, parent) {
    var component = Qt.createComponent(componentUrl)
    if (component.status === StatusReady) {
        finish(component, parent)
        return
    }
    if (component.status === StatusError) {
        console.warn("Droid Peek: failed to load panel:", component.errorString())
        waiters = []
        return
    }
    inflight = component
    component.statusChanged.connect(function () {
        if (inflight !== component)
            return
        inflight = null
        if (component.status === StatusReady)
            finish(component, parent)
        else if (component.status === StatusError) {
            console.warn("Droid Peek: failed to load panel:",
                         component.errorString())
            waiters = []
        }
    })
}

function finish(component, parent) {
    if (panel === null)
        panel = component.createObject(null)
    if (panel === null)
        console.warn("Droid Peek: failed to create panel object")
    flushWaiters()
}

function flushWaiters() {
    var pending = waiters
    waiters = []
    for (var i = 0; i < pending.length; ++i) {
        if (typeof pending[i] === "function")
            pending[i](panel)
    }
}

function registerHost() {
    hostCount += 1
}

function unregisterHost() {
    if (hostCount <= 0)
        return
    hostCount -= 1
    if (hostCount === 0)
        teardownPanel()
}

function teardownPanel() {
    waiters = []
    inflight = null
    if (!panel)
        return
    if (typeof panel.teardownSession === "function")
        panel.teardownSession()
    panel.destroy()
    panel = null
}

function resetForTests() {
    waiters = []
    inflight = null
    hostCount = 0
    if (panel) {
        panel.destroy()
        panel = null
    }
}
