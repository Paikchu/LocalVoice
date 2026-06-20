import Foundation
import Testing
@testable import LocalVoiceCore

@Test func speechRecognitionDefaultsToOpenRouter() {
    let defaults = isolatedDefaults()
    let store = SpeechRecognitionPreferenceStore(defaults: defaults)

    #expect(store.load() == .openRouter)
}

@Test func speechRecognitionPreferencePersistsAppleFallback() {
    let defaults = isolatedDefaults()
    let store = SpeechRecognitionPreferenceStore(defaults: defaults)

    store.save(.apple)

    #expect(store.load() == .apple)
}

@Test func openRouterTranscriptionRequestCarriesModelAndBase64Audio() throws {
    let request = OpenRouterTranscriptionRequest(
        model: "openai/gpt-4o-mini-transcribe",
        audio: Data([0x01, 0x02, 0x03]),
        format: "wav",
        language: "zh"
    )

    let data = try JSONEncoder().encode(request)
    let json = try #require(
        JSONSerialization.jsonObject(with: data) as? [String: Any]
    )
    let inputAudio = try #require(json["input_audio"] as? [String: Any])

    #expect(json["model"] as? String == "openai/gpt-4o-mini-transcribe")
    #expect(json["language"] as? String == "zh")
    #expect(inputAudio["format"] as? String == "wav")
    #expect(inputAudio["data"] as? String == "AQID")
}

@Test func pcm16WAVEncoderWritesMonoHeaderAndSamples() throws {
    let wav = PCM16WAVEncoder.encode(
        samples: [-1, 0, 1],
        sampleRate: 16_000
    )

    #expect(String(decoding: wav[0..<4], as: UTF8.self) == "RIFF")
    #expect(String(decoding: wav[8..<12], as: UTF8.self) == "WAVE")
    #expect(String(decoding: wav[12..<16], as: UTF8.self) == "fmt ")
    #expect(String(decoding: wav[36..<40], as: UTF8.self) == "data")
    #expect(wav.count == 44 + 6)
}

private func isolatedDefaults() -> UserDefaults {
    let suiteName = "OpenRouterSpeechBackendTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)
    return defaults
}
