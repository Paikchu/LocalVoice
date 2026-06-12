import AppKit
import AVFoundation
import Speech

enum PermissionCoordinator {
    static var accessibilityGranted: Bool {
        AXIsProcessTrusted()
    }

    static var summary: String {
        let microphone = AVCaptureDevice.authorizationStatus(for: .audio)
        let speech = SFSpeechRecognizer.authorizationStatus()
        let accessibility = accessibilityGranted
        return microphone == .authorized
            && speech == .authorized
            && accessibility
            ? "权限正常"
            : "需要授权"
    }

    static func requestAll() async -> Bool {
        let microphone = await requestMicrophone()
        let speech = await requestSpeech()
        let accessibility = requestAccessibility()
        return microphone && speech && accessibility
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
    private static func requestAccessibility() -> Bool {
        if AXIsProcessTrusted() { return true }
        let options = [
            "AXTrustedCheckOptionPrompt": true
        ] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }
}
