.pragma library

function scaledAspectSize(sourceWidth, sourceHeight, baseWidth, maxWidth,
                          maxHeight, percent) {
    if (!(sourceWidth > 0) || !(sourceHeight > 0)
            || !(baseWidth > 0) || !(percent > 0))
        return Qt.size(1, 1)

    var requestedWidth = baseWidth * percent / 100
    var requestedHeight = requestedWidth * sourceHeight / sourceWidth
    var widthLimit = maxWidth > 0 ? maxWidth : requestedWidth
    var heightLimit = maxHeight > 0 ? maxHeight : requestedHeight
    var fit = Math.min(1, widthLimit / requestedWidth,
                      heightLimit / requestedHeight)
    return Qt.size(Math.max(1, requestedWidth * fit),
                   Math.max(1, requestedHeight * fit))
}
