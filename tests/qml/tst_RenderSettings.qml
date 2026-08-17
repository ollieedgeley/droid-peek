import QtQuick
import QtTest
import "../../qml/components"

TestCase {
    name: "RenderSettings"

    RenderSettings {
        id: settings
        width: 320
    }

    SignalSpy {
        id: preferencesSpy
        target: settings
        signalName: "preferencesRequested"
    }

    function init() {
        settings.previewScale = 100
        settings.videoQuality = "high"
        settings.quickActions = ["back", "home", "recent-apps"]
        preferencesSpy.clear()
    }

    function test_preview_scale_uses_bounded_percentage_control() {
        compare(settings.previewScale, 100)
        var field = findChild(settings, "previewScaleField")
        verify(field !== null)
        compare(field.from, 50)
        compare(field.to, 150)
        compare(field.value, 100)

        field.modified(150)
        compare(preferencesSpy.count, 1)
        compare(preferencesSpy.signalArguments[0][0], 150)
        compare(preferencesSpy.signalArguments[0][1], "high")
        compare(preferencesSpy.signalArguments[0][2], ["back", "home", "recent-apps"])
    }
}
