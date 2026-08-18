pragma Singleton

import QtQuick

QtObject {
    property color foreground: "#123456"
    property color background: "#f0e1d2"
    property color accent: "#345678"
    property color urgent: "#cc3344"
    property color muted: "#667788"
    property var shellValues: ({})

    readonly property QtObject tooltip: QtObject {
        property color text: "#123456"
        property color background: "#f0e1d2"
        property color border: "#345678"
    }
    readonly property QtObject popups: QtObject {
        property color text: "#123456"
        property color background: "#f0e1d2"
        property color border: "#345678"
    }
}
