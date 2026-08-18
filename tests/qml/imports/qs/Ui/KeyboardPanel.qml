import QtQuick
import qs.Commons

Item {
    id: root
    objectName: "boundedKeyboardPanel"

    required property Item anchorItem
    required property QtObject bar
    property var owner: null
    property Item focusTarget: null
    property bool open: false
    property int gap: Style.gapsOut
    property int margin: Style.gapsOut
    property int padding: Style.spacing.popupPadding
    property int contentWidth: Style.space(280)
    property int contentHeight: Style.space(200)
    property var borderSpec: ({
        widths: {
            top: Style.space(2),
            right: Style.space(2),
            bottom: Style.space(2),
            left: Style.space(2)
        }
    })

    readonly property real screenW: anchorItem
                                        ? anchorItem.outputWidth
                                          / anchorItem.outputScale : 0
    readonly property real screenH: anchorItem
                                        ? anchorItem.outputHeight
                                          / anchorItem.outputScale : 0
    readonly property string barPos: bar ? bar.position : "top"
    readonly property real barW: bar ? bar.barSize : 0
    readonly property real barH: bar ? bar.barSize : 0
    readonly property real availableCardWidth: Math.max(
                                                   120,
                                                   screenW
                                                   - ((barPos === "left"
                                                       || barPos === "right")
                                                      ? barW + gap + margin
                                                      : margin * 2))
    readonly property real availableCardHeight: Math.max(
                                                    120,
                                                    screenH
                                                    - ((barPos === "top"
                                                        || barPos === "bottom")
                                                       ? barH + gap + margin
                                                       : margin * 2))
    readonly property real verticalContentInset: padding * 2
                                                  + Border.top(borderSpec)
                                                  + Border.bottom(borderSpec)
    readonly property rect contentBounds: Qt.rect(
                                              card.x + contentHolder.x,
                                              card.y + contentHolder.y,
                                              contentHolder.width,
                                              contentHolder.height)

    default property alias contentItem: contentHolder.children

    parent: anchorItem
    width: screenW
    height: screenH
    visible: open
    enabled: open

    onOpenChanged: {
        if (open && focusTarget) {
            Qt.callLater(function () {
                if (root.open && root.focusTarget)
                    root.focusTarget.forceActiveFocus()
            })
        }
    }

    function fittedContentWidth(implicitWidth, cap) {
        var desired = Math.max(1, Number(implicitWidth) || 1)
        var maximum = availableCardWidth > 0 ? availableCardWidth : desired
        if (cap !== undefined && Number(cap) > 0)
            maximum = Math.min(maximum, Number(cap))
        return Math.round(Math.min(desired, maximum))
    }

    function fittedContentHeight(implicitHeight, cap) {
        var desired = Math.max(verticalContentInset,
                               (Number(implicitHeight) || 0)
                               + verticalContentInset)
        var maximum = availableCardHeight > 0 ? availableCardHeight : desired
        if (cap !== undefined && Number(cap) > 0)
            maximum = Math.min(maximum, Number(cap))
        return Math.round(Math.min(desired, maximum))
    }

    Item {
        id: card
        x: root.barPos === "left" ? root.barW + root.gap : root.margin
        y: root.barPos === "top" ? root.barH + root.gap : root.margin
        width: root.contentWidth
        height: root.contentHeight
        clip: true

        Item {
            id: contentHolder
            x: root.padding + Border.left(root.borderSpec)
            y: root.padding + Border.top(root.borderSpec)
            width: Math.max(0, card.width - x - root.padding
                            - Border.right(root.borderSpec))
            height: Math.max(0, card.height - y - root.padding
                             - Border.bottom(root.borderSpec))
        }
    }
}
