pragma Singleton

import QtQuick

QtObject {
    function env(name) {
        if (name === "HOME")
            return "/tmp/droid-peek-test-home"
        return ""
    }

    function execDetached(command) {
    }
}
