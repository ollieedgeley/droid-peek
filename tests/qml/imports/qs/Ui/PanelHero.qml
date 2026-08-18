import QtQuick
import qs.Commons

Item {
    property string title: ""
    property string meta: ""
    property string detail: ""
    property color foreground: "white"

    implicitHeight: titleText.implicitHeight + metaText.implicitHeight
                    + Style.space(2)

    Column {
        anchors.fill: parent
        spacing: Style.space(2)

        Text {
            id: titleText
            text: title
            font.family: Style.fontFamily
            font.pixelSize: Style.font.title
            font.bold: true
        }

        Text {
            id: metaText
            text: meta
            font.family: Style.fontFamily
            font.pixelSize: Style.font.caption
        }
    }
}
