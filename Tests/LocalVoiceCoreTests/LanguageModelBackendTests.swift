import Testing
@testable import LocalVoiceCore

@Test func languageModelBackendDefaultsToFoundationModels() {
    #expect(LanguageModelBackendKind.defaultValue == .foundationModels)
    #expect(LanguageModelBackendKind.foundationModels.displayName == "Foundation Models")
}

@Test func foundationModelsLifecycleLoadingIsTheOnlyBusyState() {
    #expect(LanguageModelLifecycleState.loading.isBusy)
    #expect(!LanguageModelLifecycleState.ready.isBusy)
    #expect(!LanguageModelLifecycleState.unavailable("missing").isBusy)
    #expect(!LanguageModelLifecycleState.failed("failed").isBusy)
}

@Test func activeBackendProxyUsesTheMostRecentlySelectedBackend() async throws {
    let proxy = ActiveBackendProxy(StubLanguageModel(tag: "foundation"))

    proxy.setBackend(StubLanguageModel(tag: "replacement"))
    let output = try await proxy.generate(prompt: "test")

    #expect(output.text == "replacement")
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
