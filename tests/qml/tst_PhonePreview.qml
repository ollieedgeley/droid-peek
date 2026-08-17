import QtQuick
import QtTest
import "../../qml/components"
import "../../qml/PreviewGeometry.js" as PreviewGeometry

TestCase {
    name: "PhonePreview"

    PhonePreview {
        id: preview
        captureRequested: false
    }

    SignalSpy {
        id: tapSpy
        target: preview
        signalName: "tapRequested"
    }

    SignalSpy {
        id: swipeSpy
        target: preview
        signalName: "swipeRequested"
    }
    function init() {
        preview.captureRequested = false
        preview.deviceDescription = "Omarchy Android"
        preview.frameCount = 0
        tapSpy.clear()
        swipeSpy.clear()
    }


    function test_target_device_selection_is_exact() {
        var inputs = [
            { description: "USB Camera" },
            { description: "Omarchy Android" },
            { description: "Omarchy Android Backup" }
        ]

        compare(preview.findDeviceIndex(inputs, "Omarchy Android"), 1)
        compare(preview.findDeviceIndex(inputs, "Missing device"), -1)
        compare(preview.findDeviceIndex([], "Omarchy Android"), -1)
    }

    function test_capture_is_off_until_requested() {
        compare(preview.captureRequested, false)
        compare(preview.active, false)
        compare(preview.frameCount, 0)
    }

    function test_stopping_capture_clears_ephemeral_frame_state() {
        preview.deviceDescription = "Missing test device"
        preview.captureRequested = true
        preview.frameCount = 7
        preview.captureRequested = false

        compare(preview.active, false)
        compare(preview.frameCount, 0)
    }

    function test_pointer_mapping_excludes_letterbox_and_normalizes_content() {
        var topLeft = preview.normalizedPoint(20, 40, Qt.rect(20, 40, 200, 400))
        verify(topLeft !== null)
        compare(topLeft.x, 0)
        compare(topLeft.y, 0)

        var center = preview.normalizedPoint(120, 240, Qt.rect(20, 40, 200, 400))
        verify(center !== null)
        compare(center.x, 0.5)
        compare(center.y, 0.5)

        compare(preview.normalizedPoint(10, 240, Qt.rect(20, 40, 200, 400)), null)
        compare(preview.normalizedPoint(120, 500, Qt.rect(20, 40, 200, 400)), null)
    }

    function test_letterbox_viewport_scales_like_a_window_width() {
        compare(PreviewGeometry.scaledViewportSize(320, 560, 1000, 1000, 50),
                Qt.size(160, 280))
        compare(PreviewGeometry.scaledViewportSize(320, 560, 1000, 1000, 100),
                Qt.size(320, 560))
        compare(PreviewGeometry.scaledViewportSize(320, 560, 430, 700, 150),
                Qt.size(400, 700))
    }

    function test_letterbox_content_preserves_android_aspect_ratio() {
        var portrait = preview.fittedSize(320, 560, 1080, 2392)
        compare(portrait.width, 253)
        compare(portrait.height, 560)

        var landscape = preview.fittedSize(320, 560, 2392, 1080)
        compare(landscape.width, 320)
        compare(landscape.height, 144)
    }

    function test_pointer_release_distinguishes_taps_and_swipes() {
        var content = Qt.rect(20, 40, 200, 400)
        verify(preview.dispatchPointer(120, 240, 122, 242, 80, content, 1080, 2400))
        compare(tapSpy.count, 1)
        compare(swipeSpy.count, 0)
        compare(tapSpy.signalArguments[0][0], 0.51)
        compare(tapSpy.signalArguments[0][1], 0.505)
        compare(tapSpy.signalArguments[0][2], 1080)
        compare(tapSpy.signalArguments[0][3], 2400)

        verify(preview.dispatchPointer(40, 80, 200, 400, 320, content, 1080, 2400))
        compare(tapSpy.count, 1)
        compare(swipeSpy.count, 1)
        compare(swipeSpy.signalArguments[0][0], 0.1)
        compare(swipeSpy.signalArguments[0][1], 0.1)
        compare(swipeSpy.signalArguments[0][2], 0.9)
        compare(swipeSpy.signalArguments[0][3], 0.9)
        compare(swipeSpy.signalArguments[0][6], 320)
    }

    function test_keyboard_mapping_is_semantic_and_bounded() {
        compare(preview.androidKeyForQtKey(Qt.Key_Escape), "back")
        compare(preview.androidKeyForQtKey(Qt.Key_Home), "home")
        compare(preview.androidKeyForQtKey(Qt.Key_Return), "enter")
        compare(preview.androidKeyForQtKey(Qt.Key_Backspace), "delete")
        compare(preview.androidKeyForQtKey(Qt.Key_Left), "arrow-left")
        compare(preview.androidKeyForQtKey(Qt.Key_A), "")
    }
}
