import Testing
@testable import LocalVoiceCore

@Test func reportsSilentMicrophoneWhenNoAudioWasCaptured() {
    let activity = SpeechCaptureActivity(
        peakLevel: 0.01,
        receivedTranscript: false
    )

    #expect(activity.failureMessage == "未检测到麦克风声音")
}

@Test func reportsRecognitionFailureWhenAudioHasNoTranscript() {
    let activity = SpeechCaptureActivity(
        peakLevel: 0.25,
        receivedTranscript: false
    )

    #expect(activity.failureMessage == "检测到声音，但未识别到文字")
}

@Test func acceptsCaptureWithRecognizedTranscript() {
    let activity = SpeechCaptureActivity(
        peakLevel: 0.25,
        receivedTranscript: true
    )

    #expect(activity.failureMessage == nil)
}
