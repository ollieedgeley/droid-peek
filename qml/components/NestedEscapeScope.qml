import QtQuick

Item {
    id: root

    property bool escapeEnabled: true

    signal escapeRequested

    Keys.priority: Keys.AfterItem
    Keys.onPressed: function (event) {
        if (!root.escapeEnabled || event.key !== Qt.Key_Escape)
            return;
        root.escapeRequested();
        event.accepted = true;
    }
}
