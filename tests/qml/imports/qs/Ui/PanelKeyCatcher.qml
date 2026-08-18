import QtQuick

FocusScope {
    property bool blocked: false

    signal activateRequested()
    signal closeRequested()
    signal textKey(string text)

    focus: true
    Keys.onReturnPressed: if (!blocked) activateRequested()
    Keys.onEnterPressed: if (!blocked) activateRequested()
}
