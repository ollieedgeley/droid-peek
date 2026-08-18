pragma Singleton

import QtQuick

QtObject {
    readonly property int cornerRadius: 0
    readonly property int gapsOut: 5
    readonly property string fontFamily: "monospace"
    readonly property int fontBaseSize: 12

    readonly property QtObject font: QtObject {
        readonly property int caption: 10
        readonly property int body: 12
        readonly property int title: 16
        readonly property int icon: 16
    }

    readonly property QtObject spacing: QtObject {
        readonly property int controlPaddingX: 10
        readonly property int controlPaddingY: 6
        readonly property int controlHeight: 28
        readonly property int popupPadding: 14
    }

    readonly property QtObject bar: QtObject {
        readonly property int iconSize: 16
        readonly property int horizontalSize: 26
        readonly property int verticalSize: 26
        readonly property int iconSlot: 27
        readonly property int sizeHorizontal: 26
    }

    function space(value) {
        var number = Number(value)
        if (!isFinite(number) || number <= 0)
            return 0
        return Math.max(1, Math.round(number))
    }

    function translucent(color, alpha) {
        return Qt.rgba(color.r, color.g, color.b, alpha)
    }

    function selectedFillFor(foreground, accent) {
        return translucent(accent || foreground, 0.18)
    }

    function controlFill(focused, hot, foreground, accent) {
        if (focused || hot)
            return translucent(accent || foreground, focused ? 0.12 : 0.08)
        return "transparent"
    }
}
