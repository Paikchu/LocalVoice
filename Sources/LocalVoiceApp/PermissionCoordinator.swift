import AppKit
import AVFoundation
import LocalVoiceCore
import Speech

enum PermissionCoordinator {
    private static let accessibilityPromptedKey =
        "didPromptForAccessibility"

    static var accessibilityGranted: Bool {
        AXIsProcessTrusted()
    }

    static var summary: String {
        let state = currentState
        if state.canRecord && state.canInsertText {
            return "权限正常"
        }
        if state.canRecord {
            return "可录音，需辅助功能权限"
        }
        return "需要麦克风和语音识别权限"
    }

    static var currentState: VoicePermissionState {
        VoicePermissionState(
            microphoneGranted: AVCaptureDevice.authorizationStatus(
                for: .audio
            ) == .authorized,
            speechRecognitionGranted:
                SFSpeechRecognizer.authorizationStatus() == .authorized,
            accessibilityGranted: accessibilityGranted
        )
    }

    static func requestRecording() async -> Bool {
        let microphone = await requestMicrophone()
        let speech = await requestSpeech()
        return microphone && speech
    }

    @discardableResult
    static func requestAccessibilityOnce() -> Bool {
        if accessibilityGranted { return true }
        guard !UserDefaults.standard.bool(
            forKey: accessibilityPromptedKey
        ) else {
            return false
        }
        UserDefaults.standard.set(
            true,
            forKey: accessibilityPromptedKey
        )
        return requestAccessibility()
    }

    private static func requestMicrophone() async -> Bool {
        if AVCaptureDevice.authorizationStatus(for: .audio) == .authorized {
            return true
        }
        return await AVCaptureDevice.requestAccess(for: .audio)
    }

    private static func requestSpeech() async -> Bool {
        if SFSpeechRecognizer.authorizationStatus() == .authorized {
            return true
        }
        return await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }
    }

    @discardableResult
    static func requestAccessibility() -> Bool {
        if AXIsProcessTrusted() { return true }
        let options = [
            "AXTrustedCheckOptionPrompt": true
        ] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }
}
