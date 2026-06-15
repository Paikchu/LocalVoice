import Foundation
import Testing
@testable import LocalVoiceCore

@Test func backendPreferenceDefaultsToQwen() {
    let defaults = isolatedDefaults()
    let store = LanguageModelPreferenceStore(defaults: defaults)

    #expect(store.load() == .qwen)
}

@Test func backendPreferencePersistsFoundationModels() {
    let defaults = isolatedDefaults()
    let store = LanguageModelPreferenceStore(defaults: defaults)

    store.save(.foundationModels)

    #expect(store.load() == .foundationModels)
}

@Test func activeBackendProxyUsesTheMostRecentlySelectedBackend() async throws {
    let proxy = ActiveBackendProxy(StubLanguageModel(tag: "qwen"))

    proxy.setBackend(StubLanguageModel(tag: "foundation"))
    let output = try await proxy.generate(prompt: "test")

    #expect(output.text == "foundation")
}

private func isolatedDefaults() -> UserDefaults {
    let suiteName = "LanguageModelBackendTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)
    return defaults
}

private actor StubLanguageModel: LocalLanguageModelService {
    let tag: String

    init(tag: String) {
        self.tag = tag
    }

    func generate(prompt: String) async throws -> ModelGenerationOutput {
        ModelGenerationOutput(text: tag)
    }
}
