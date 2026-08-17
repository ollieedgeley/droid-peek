.pragma library

function scaledViewportSize(baseWidth, baseHeight, maxWidth, maxHeight, percent) {
    if (!(baseWidth > 0) || !(baseHeight > 0) || !(percent > 0))
        return Qt.size(1, 1)

    var requestedWidth = baseWidth * percent / 100
    var requestedHeight = baseHeight * percent / 100
    var widthLimit = maxWidth > 0 ? maxWidth : requestedWidth
    var heightLimit = maxHeight > 0 ? maxHeight : requestedHeight
    var fit = Math.min(1, widthLimit / requestedWidth,
                      heightLimit / requestedHeight)
    return Qt.size(Math.max(1, Math.round(requestedWidth * fit)),
                   Math.max(1, Math.round(requestedHeight * fit)))
}
