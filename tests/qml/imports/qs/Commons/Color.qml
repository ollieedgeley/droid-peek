pragma Singleton

import QtQuick

QtObject {
    readonly property QtObject popups: QtObject {
        property color text: "#123456"
        property color background: "#f0e1d2"
    }
}
