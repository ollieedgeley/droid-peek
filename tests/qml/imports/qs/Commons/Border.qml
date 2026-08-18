pragma Singleton

import QtQuick

QtObject {
    function sideWidth(spec, side) {
        if (!spec || !spec.widths)
            return 0
        var width = Number(spec.widths[side])
        return isFinite(width) ? Math.max(0, width) : 0
    }

    function top(spec) {
        return sideWidth(spec, "top")
    }

    function right(spec) {
        return sideWidth(spec, "right")
    }

    function bottom(spec) {
        return sideWidth(spec, "bottom")
    }

    function left(spec) {
        return sideWidth(spec, "left")
    }

    function uniformSpec(color, width) {
        var normalizedWidth = Math.max(0, Number(width) || 0)
        return {
            color: color,
            widths: {
                top: normalizedWidth,
                right: normalizedWidth,
                bottom: normalizedWidth,
                left: normalizedWidth
            }
        }
    }

    function surfaceSpec(surface, role, color, width) {
        return uniformSpec(color, width)
    }

    function controlSpec(state, foreground, accent) {
        var color = accent || foreground
        return uniformSpec(color, state === "selected" ? 0 : 1)
    }
}
