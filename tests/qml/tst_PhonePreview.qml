import QtQuick
import QtTest
import qs.Commons
import "../../qml/components"
import "../../qml/PreviewGeometry.js" as PreviewGeometry

TestCase {
    name: "PhonePreview"
    when: windowShown
    width: 320
    height: 480

    Item {
        id: fallbackFocus
        focus: true
    }

    PhonePreview {
        id: preview
        captureRequested: false
        helperEpoch: "17"
        sessionGeneration: "1"
        applicationState: "closed"
        videoInputs: []
        capturePipelineReleaseDelayMs: 20
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

    SignalSpy {
        id: keySpy
        target: preview
        signalName: "keyRequested"
    }

    SignalSpy {
        id: textSpy
        target: preview
        signalName: "textRequested"
    }

    function init() {
        preview.captureRequested = false
        preview.inputEnabled = false
        preview.helperEpoch = "17"
        preview.sessionGeneration = "1"
        preview.applicationState = "closed"
        tapSpy.clear()
        swipeSpy.clear()
        keySpy.clear()
        textSpy.clear()
        fallbackFocus.forceActiveFocus()
        wait(0)
    }
    function waitForCapturePipeline() {
        tryVerify(function () {
            return !preview.capturePipelineCreationPending
                    && preview.capturePipeline !== null
        }, 500)
    }


    function test_default_surface_uses_live_popup_roles() {
        compare(Color.popups.text, "#123456")
        compare(Color.popups.background, "#f0e1d2")

        Color.popups.text = "#abcdef"
        Color.popups.background = "#010203"
        wait(0)
        compare(preview.foreground, "#abcdef")
        compare(preview.background, "#010203")

        Color.popups.text = "#123456"
        Color.popups.background = "#f0e1d2"
    }


    function test_capture_identity_is_exact_and_unique() {
        compare(preview.deviceId, "/dev/video42")
        compare(preview.deviceDescription, "Droid Peek")
        var inputs = [
            { id: "/dev/video0", description: "USB Camera" },
            { id: preview.deviceId, description: preview.deviceDescription },
            { id: "/dev/video43", description: "Droid Peek Backup" }
        ]

        compare(preview.findDeviceIndex(inputs, preview.deviceId,
                                        preview.deviceDescription), 1)
        inputs.push({ id: preview.deviceId,
                      description: preview.deviceDescription })
        compare(preview.findDeviceIndex(inputs, preview.deviceId,
                                        preview.deviceDescription), -1)
    }

    function test_capture_identity_normalizes_qml_camera_ids() {
        var cameraId = {
            toString: function () {
                return preview.deviceId
            }
        }
        var inputs = [
            { id: cameraId, description: preview.deviceDescription }
        ]

        compare(preview.findDeviceIndex(inputs, preview.deviceId,
                                        preview.deviceDescription), 0)
        inputs.push({ id: preview.deviceId,
                      description: preview.deviceDescription })
        compare(preview.findDeviceIndex(inputs, preview.deviceId,
                                        preview.deviceDescription), -1)
    }

    function test_capture_is_off_until_requested() {
        compare(preview.active, false)
        compare(preview.firstValidFrameReceived, false)
        compare(preview.captureAvailable, false)
        compare(preview.displayWidth, 0)
        compare(preview.displayHeight, 0)
    }

    function establishCaptureReadiness(eventSessionGeneration) {
        var preRefreshEpoch = preview.captureEpoch
        verify(preview.acceptCaptureSource(
                   preRefreshEpoch, preview.helperEpoch, eventSessionGeneration,
                   preview.deviceId, preview.deviceDescription))
        verify(!preview.acceptRenderedFrame(
                   preRefreshEpoch, preview.helperEpoch, eventSessionGeneration,
                   1080, 2392, true))
        compare(preview.captureEpoch, preRefreshEpoch)
        wait(0)
        compare(preview.captureEpoch, preRefreshEpoch + 1)
        compare(preview.capturePipelineCreationPending, true)
        compare(preview.capturePipeline, null)
        waitForCapturePipeline()

        var currentCaptureEpoch = preview.captureEpoch
        compare(currentCaptureEpoch, preRefreshEpoch + 1)
        verify(preview.acceptCaptureSource(
                   currentCaptureEpoch, preview.helperEpoch,
                   eventSessionGeneration,
                   preview.deviceId, preview.deviceDescription))
        verify(preview.acceptRenderedFrame(
                   currentCaptureEpoch, preview.helperEpoch,
                   eventSessionGeneration, 1080, 2392, true))
        compare(preview.firstValidFrameReceived, true)
        return currentCaptureEpoch
    }

    function test_geometry_notifications_do_not_establish_readiness() {
        preview.captureRequested = true
        var currentCaptureEpoch = preview.captureEpoch
        verify(preview.acceptCaptureSource(
                   currentCaptureEpoch, "17", "1",
                   preview.deviceId, preview.deviceDescription))

        verify(!preview.acceptRenderedFrame(
                   currentCaptureEpoch, "17", "1", 1080, 2392))
        verify(!preview.acceptRenderedFrame(
                   currentCaptureEpoch, "17", "1", 1080, 2392, false))
        compare(preview.firstValidFrameReceived, false)
        compare(preview.displayWidth, 0)
        compare(preview.displayHeight, 0)
        wait(0)
        compare(preview.captureEpoch, currentCaptureEpoch)
    }

    function test_first_real_frame_refreshes_once_before_readiness() {
        preview.captureRequested = true
        var preRefreshEpoch = preview.captureEpoch
        verify(preview.acceptCaptureSource(
                   preRefreshEpoch, "17", "1",
                   preview.deviceId, preview.deviceDescription))
        verify(!preview.acceptRenderedFrame(
                   preRefreshEpoch, "17", "1", 1080, 2392, true))
        compare(preview.firstFrameRecoveryArmed, false)
        compare(preview.captureEpoch, preRefreshEpoch)
        compare(preview.firstValidFrameReceived, false)
        wait(0)

        compare(preview.captureEpoch, preRefreshEpoch + 1)
        compare(preview.capturePipelineCreationPending, true)
        compare(preview.capturePipeline, null)
        var currentCaptureEpoch = preview.captureEpoch
        verify(!preview.acceptCaptureSource(
                   preRefreshEpoch, "17", "1",
                   preview.deviceId, preview.deviceDescription))
        verify(!preview.acceptRenderedFrame(
                   preRefreshEpoch, "17", "1", 1080, 2392, true))

        waitForCapturePipeline()
        compare(preview.captureEpoch, currentCaptureEpoch)
        compare(preview.capturePipeline.epoch, currentCaptureEpoch)
        verify(preview.acceptCaptureSource(
                   currentCaptureEpoch, "17", "1",
                   preview.deviceId, preview.deviceDescription))
        verify(preview.acceptRenderedFrame(
                   currentCaptureEpoch, "17", "1", 1080, 2392, true))
        compare(preview.firstValidFrameReceived, true)
        compare(preview.displayWidth, 1080)
        compare(preview.displayHeight, 2392)

        verify(preview.acceptRenderedFrame(
                   currentCaptureEpoch, "17", "1", 720, 1600, true))
        wait(0)
        compare(preview.captureEpoch, currentCaptureEpoch)
        compare(preview.capturePipelineCreationPending, false)
        compare(preview.displayWidth, 720)
        compare(preview.displayHeight, 1600)
    }

    function test_internal_recreation_preserves_armed_format_refresh() {
        preview.captureRequested = true
        var armedCaptureEpoch = preview.captureEpoch

        preview.recreateCapturePipelineInternal()
        var preRefreshEpoch = preview.captureEpoch
        compare(preRefreshEpoch, armedCaptureEpoch + 1)
        compare(preview.firstValidFrameReceived, false)
        verify(preview.acceptCaptureSource(
                   preRefreshEpoch, "17", "1",
                   preview.deviceId, preview.deviceDescription))

        verify(!preview.acceptRenderedFrame(
                   preRefreshEpoch, "17", "1", 1080, 2392, true))
        compare(preview.captureEpoch, preRefreshEpoch)
        compare(preview.firstValidFrameReceived, false)
        wait(0)

        var readyCaptureEpoch = preview.captureEpoch
        compare(readyCaptureEpoch, preRefreshEpoch + 1)
        verify(preview.acceptCaptureSource(
                   readyCaptureEpoch, "17", "1",
                   preview.deviceId, preview.deviceDescription))
        verify(preview.acceptRenderedFrame(
                   readyCaptureEpoch, "17", "1", 1080, 2392, true))
        compare(preview.firstValidFrameReceived, true)
        wait(0)
        compare(preview.captureEpoch, readyCaptureEpoch)
    }

    function test_first_frame_recovery_is_consumed_before_recreation() {
        preview.captureRequested = true
        waitForCapturePipeline()
        var armedCaptureEpoch = preview.captureEpoch
        compare(preview.firstFrameRecoveryArmed, true)

        verify(preview.consumeFirstFrameRecovery())
        compare(preview.firstFrameRecoveryArmed, false)
        compare(preview.captureEpoch, armedCaptureEpoch + 1)
        compare(preview.capturePipelineCreationPending, true)
        compare(preview.capturePipeline, null)

        verify(preview.completeCapturePipelineCreation())
        compare(preview.capturePipelineCreationPending, false)
        var recoveredCaptureEpoch = preview.captureEpoch
        verify(!preview.consumeFirstFrameRecovery())
        compare(preview.captureEpoch, recoveredCaptureEpoch)
        compare(preview.capturePipeline.epoch, recoveredCaptureEpoch)
    }

    function test_new_session_identity_rearms_first_frame_recovery() {
        preview.captureRequested = true
        waitForCapturePipeline()
        verify(preview.consumeFirstFrameRecovery())
        verify(preview.completeCapturePipelineCreation())
        compare(preview.firstFrameRecoveryArmed, false)

        preview.sessionGeneration = "2"

        compare(preview.firstFrameRecoveryArmed, true)
        var newIdentityCaptureEpoch = preview.captureEpoch
        verify(preview.consumeFirstFrameRecovery())
        compare(preview.firstFrameRecoveryArmed, false)
        compare(preview.captureEpoch, newIdentityCaptureEpoch + 1)
    }

    function test_capture_and_session_transitions_rearm_format_refresh() {
        preview.captureRequested = true
        establishCaptureReadiness("1")

        preview.captureRequested = false
        preview.captureRequested = true
        var restartedCaptureEpoch = preview.captureEpoch
        verify(preview.acceptCaptureSource(
                   restartedCaptureEpoch, "17", "1",
                   preview.deviceId, preview.deviceDescription))
        verify(!preview.acceptRenderedFrame(
                   restartedCaptureEpoch, "17", "1", 1080, 2392, true))
        wait(0)
        compare(preview.captureEpoch, restartedCaptureEpoch + 1)

        var readyCaptureEpoch = preview.captureEpoch
        verify(preview.acceptCaptureSource(
                   readyCaptureEpoch, "17", "1",
                   preview.deviceId, preview.deviceDescription))
        verify(preview.acceptRenderedFrame(
                   readyCaptureEpoch, "17", "1", 1080, 2392, true))

        preview.sessionGeneration = "2"
        var newIdentityEpoch = preview.captureEpoch
        verify(newIdentityEpoch > readyCaptureEpoch)
        verify(preview.acceptCaptureSource(
                   newIdentityEpoch, "17", "2",
                   preview.deviceId, preview.deviceDescription))
        verify(!preview.acceptRenderedFrame(
                   newIdentityEpoch, "17", "2", 1080, 2392, true))
        compare(preview.captureEpoch, newIdentityEpoch)
        wait(0)
        compare(preview.captureEpoch, newIdentityEpoch + 1)
    }

    function test_generation_change_recreates_capture_pipeline_and_clears_facts() {
        preview.captureRequested = true
        var oldCaptureEpoch = establishCaptureReadiness("1")
        var oldCapturePipeline = preview.capturePipeline

        preview.sessionGeneration = "2"

        verify(preview.captureEpoch > oldCaptureEpoch)
        verify(preview.capturePipeline !== oldCapturePipeline)
        compare(preview.firstValidFrameReceived, false)
        compare(preview.capturePipeline.epoch, preview.captureEpoch)
        compare(preview.capturePipeline.helperEpochSnapshot, "17")
        compare(preview.capturePipeline.sessionGenerationSnapshot, "2")
        compare(preview.captureAvailable, false)
        compare(preview.active, false)
        compare(preview.displayWidth, 0)
        compare(preview.displayHeight, 0)
    }

    function test_old_capture_callbacks_cannot_adopt_the_new_identity() {
        preview.captureRequested = true
        var oldCaptureEpoch = preview.captureEpoch
        verify(preview.acceptCaptureSource(
                   oldCaptureEpoch, "17", "1",
                   preview.deviceId, preview.deviceDescription))

        preview.sessionGeneration = "2"
        var identityCaptureEpoch = preview.captureEpoch

        verify(!preview.acceptCaptureSource(
                   identityCaptureEpoch, "17", "1",
                   preview.deviceId, preview.deviceDescription))
        verify(!preview.acceptRenderedFrame(
                   identityCaptureEpoch, "17", "1", 1080, 2392, true))
        compare(preview.firstValidFrameReceived, false)
        verify(preview.acceptCaptureSource(
                   identityCaptureEpoch, "17", "2",
                   preview.deviceId, preview.deviceDescription))
        verify(!preview.acceptRenderedFrame(
                   identityCaptureEpoch, "17", "2", 1080, 2392, true))
        wait(0)

        var currentCaptureEpoch = preview.captureEpoch
        verify(currentCaptureEpoch > identityCaptureEpoch)
        verify(!preview.acceptRenderedFrame(
                   identityCaptureEpoch, "17", "2", 1080, 2392, true))
        verify(preview.acceptCaptureSource(
                   currentCaptureEpoch, "17", "2",
                   preview.deviceId, preview.deviceDescription))
        verify(preview.acceptRenderedFrame(
                   currentCaptureEpoch, "17", "2", 1080, 2392, true))
        compare(preview.firstValidFrameReceived, true)
    }

    function test_wrong_epoch_or_source_cannot_acknowledge_capture() {
        preview.captureRequested = true
        var currentCaptureEpoch = preview.captureEpoch

        verify(!preview.acceptCaptureSource(
                   currentCaptureEpoch - 1, "17", "1",
                   preview.deviceId, preview.deviceDescription))
        verify(!preview.acceptCaptureSource(
                   currentCaptureEpoch, "17", "1",
                   "/dev/video41", preview.deviceDescription))
        verify(!preview.acceptRenderedFrame(
                   currentCaptureEpoch, "17", "1", 1080, 2392, true))
        compare(preview.firstValidFrameReceived, false)
    }

    function test_source_acknowledgement_is_not_a_valid_frame() {
        preview.captureRequested = true
        var preRefreshEpoch = preview.captureEpoch
        verify(preview.acceptCaptureSource(
                   preRefreshEpoch, "17", "1",
                   preview.deviceId, preview.deviceDescription))

        compare(preview.firstValidFrameReceived, false)
        compare(preview.captureAvailable, false)
        compare(preview.active, false)
        compare(preview.displayWidth, 0)
        compare(preview.displayHeight, 0)
        verify(!preview.acceptRenderedFrame(
                   preRefreshEpoch, "17", "1", 1080, 2392, true))
        wait(0)

        var currentCaptureEpoch = preview.captureEpoch
        verify(currentCaptureEpoch > preRefreshEpoch)
        verify(preview.acceptCaptureSource(
                   currentCaptureEpoch, "17", "1",
                   preview.deviceId, preview.deviceDescription))
        verify(preview.acceptRenderedFrame(
                   currentCaptureEpoch, "17", "1", 1080, 2392, true))
        compare(preview.firstValidFrameReceived, true)
    }

    function test_zero_sized_frame_is_not_capture_ready() {
        preview.captureRequested = true
        var currentCaptureEpoch = preview.captureEpoch
        verify(preview.acceptCaptureSource(
                   currentCaptureEpoch, "17", "1",
                   preview.deviceId, preview.deviceDescription))

        verify(!preview.acceptRenderedFrame(
                   currentCaptureEpoch, "17", "1", 0, 2392, true))
        verify(!preview.acceptRenderedFrame(
                   currentCaptureEpoch, "17", "1", 1080, 0, true))
        compare(preview.firstValidFrameReceived, false)
    }

    function test_stopping_capture_clears_current_capture_readiness() {
        preview.captureRequested = true
        establishCaptureReadiness("1")

        preview.captureRequested = false
        compare(preview.firstFrameRecoveryArmed, false)

        compare(preview.firstValidFrameReceived, false)
        compare(preview.captureAvailable, false)
        compare(preview.active, false)
        compare(preview.displayWidth, 0)
        compare(preview.displayHeight, 0)
    }
    function test_stopping_capture_during_release_cancels_pending_replacement() {
        preview.captureRequested = true
        var preRefreshEpoch = preview.captureEpoch
        verify(preview.acceptCaptureSource(
                   preRefreshEpoch, "17", "1",
                   preview.deviceId, preview.deviceDescription))
        verify(!preview.acceptRenderedFrame(
                   preRefreshEpoch, "17", "1", 1080, 2392, true))
        wait(0)

        var releaseEpoch = preview.captureEpoch
        compare(releaseEpoch, preRefreshEpoch + 1)
        compare(preview.capturePipelineCreationPending, true)
        compare(preview.capturePipeline, null)
        preview.captureRequested = false
        compare(preview.capturePipelineCreationPending, false)
        wait(preview.capturePipelineReleaseDelayMs * 2)
        compare(preview.captureEpoch, releaseEpoch)
        compare(preview.capturePipelineCreationPending, false)
        compare(preview.capturePipeline, null)
    }

    function test_generation_change_during_release_cancels_old_replacement() {
        preview.captureRequested = true
        var oldPreRefreshEpoch = preview.captureEpoch
        verify(preview.acceptCaptureSource(
                   oldPreRefreshEpoch, "17", "1",
                   preview.deviceId, preview.deviceDescription))
        verify(!preview.acceptRenderedFrame(
                   oldPreRefreshEpoch, "17", "1", 1080, 2392, true))
        wait(0)

        var oldReleaseEpoch = preview.captureEpoch
        compare(oldReleaseEpoch, oldPreRefreshEpoch + 1)
        compare(preview.capturePipelineCreationPending, true)
        compare(preview.capturePipeline, null)
        preview.sessionGeneration = "2"
        var newIdentityEpoch = preview.captureEpoch
        verify(newIdentityEpoch > oldReleaseEpoch)
        compare(preview.capturePipelineCreationPending, true)
        compare(preview.capturePipeline, null)

        waitForCapturePipeline()
        compare(preview.captureEpoch, newIdentityEpoch)
        compare(preview.capturePipeline.epoch, newIdentityEpoch)
        compare(preview.capturePipeline.helperEpochSnapshot, "17")
        compare(preview.capturePipeline.sessionGenerationSnapshot, "2")
        verify(!preview.acceptCaptureSource(
                   oldReleaseEpoch, "17", "1",
                   preview.deviceId, preview.deviceDescription))
    }


    function test_pointer_mapping_excludes_letterbox_and_normalizes_content() {
        var topLeft = preview.normalizedPoint(20, 40, Qt.rect(20, 40, 200, 400))
        compare(topLeft, Qt.point(0, 0))
        var center = preview.normalizedPoint(120, 240,
                                             Qt.rect(20, 40, 200, 400))
        compare(center, Qt.point(0.5, 0.5))
        compare(preview.normalizedPoint(10, 240,
                                        Qt.rect(20, 40, 200, 400)), null)
    }

    function test_pointer_release_preserves_current_identity() {
        var content = Qt.rect(20, 40, 200, 400)
        verify(preview.dispatchPointer(
                   120, 240, 122, 242, 80, content, 1080, 2400))
        compare(tapSpy.count, 1)
        compare(tapSpy.signalArguments[0][4], "17")
        compare(tapSpy.signalArguments[0][5], "1")

        verify(preview.dispatchPointer(
                   40, 80, 200, 400, 320, content, 1080, 2400))
        compare(swipeSpy.count, 1)
        compare(swipeSpy.signalArguments[0][7], "17")
        compare(swipeSpy.signalArguments[0][8], "1")
    }
    function test_pointer_release_from_old_generation_is_rejected() {
        var content = Qt.rect(20, 40, 200, 400)
        preview.sessionGeneration = "2"

        verify(!preview.dispatchPointer(
                   120, 240, 122, 242, 80, content, 1080, 2400,
                   "17", "1"))
        compare(tapSpy.count, 0)
    }


    function test_ordinary_unmodified_text_and_keys_remain_eligible() {
        preview.applicationState = "interactive"
        preview.inputEnabled = true
        preview.captureRequested = true
        verify(preview.dispatchKeyEvent(Qt.Key_A, Qt.NoModifier, "a"))
        verify(preview.dispatchKeyEvent(Qt.Key_Left, Qt.NoModifier, ""))

        compare(textSpy.count, 1)
        compare(textSpy.signalArguments[0][0], "a")
        compare(textSpy.signalArguments[0][1], "17")
        compare(textSpy.signalArguments[0][2], "1")
        compare(keySpy.count, 1)
        compare(keySpy.signalArguments[0][0], "arrow-left")
        compare(keySpy.signalArguments[0][1], "17")
        compare(keySpy.signalArguments[0][2], "1")
    }

    function test_modified_shortcut_chords_are_not_swallowed_as_phone_text() {
        preview.applicationState = "interactive"
        preview.inputEnabled = true
        verify(!preview.dispatchKeyEvent(Qt.Key_W, Qt.MetaModifier, "w"))
        compare(textSpy.count, 0)
        compare(keySpy.count, 0)
    }

    function test_shift_letter_is_phone_text_not_a_compositor_chord() {
        preview.applicationState = "interactive"
        preview.inputEnabled = true
        preview.captureRequested = true
        verify(preview.dispatchKeyEvent(Qt.Key_A, Qt.ShiftModifier, "A"))
        compare(textSpy.count, 1)
        compare(textSpy.signalArguments[0][0], "A")
        compare(textSpy.signalArguments[0][1], "17")
        compare(textSpy.signalArguments[0][2], "1")
        compare(keySpy.count, 0)

        verify(!preview.dispatchKeyEvent(Qt.Key_Tab, Qt.ShiftModifier, ""))
        compare(keySpy.count, 0)
        compare(textSpy.count, 1)
    }

    function test_ctrl_and_alt_chords_are_not_swallowed_as_phone_text() {
        preview.applicationState = "interactive"
        preview.inputEnabled = true
        verify(!preview.dispatchKeyEvent(Qt.Key_C, Qt.ControlModifier, "c"))
        verify(!preview.dispatchKeyEvent(Qt.Key_F, Qt.AltModifier, "f"))
        compare(textSpy.count, 0)
        compare(keySpy.count, 0)
    }

    function test_live_frame_ratio_defines_the_viewport() {
        var portrait = PreviewGeometry.scaledAspectSize(
                    1080, 2392, 288, 1000, 1000, 100)
        compare(portrait.width, 288)
        verify(Math.abs(portrait.height - 637.8666667) < 0.001)
        verify(Math.abs(portrait.width / portrait.height - 1080 / 2392)
               < 0.000001)
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
