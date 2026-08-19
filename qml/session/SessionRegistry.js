.pragma library

var panel = null

function ensurePanel(componentUrl, parent) {
    if (panel === null)
        panel = Qt.createComponent(componentUrl).createObject(parent)
    return panel
}

function resetForTests() {
    if (panel) {
        panel.destroy()
        panel = null
    }
}
