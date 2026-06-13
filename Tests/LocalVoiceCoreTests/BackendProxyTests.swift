import Foundation
import Testing
@testable import LocalVoiceCore

/// `ActiveBackendProxy` is the seam that lets the drafting pipeline hold one stable
/// service while `LocalModelManager` swaps the concrete backend (system model vs.
/// downloadable model) underneath it.
@Test func activeBackendProxyForwardsToInitialBackend() async throws {
    let proxy = ActiveBackendProxy(StubBackend(tag: "system"))

    let output = try await proxy.generate(prompt: "hi")

    #expect(output.text == "system")
}

@Test func activeBackendProxyRoutesToTheBackendSetMostRecently() async throws {
    let proxy = ActiveBackendProxy(StubBackend(tag: "downloadable"))

    proxy.setBackend(StubBackend(tag: "system"))
    let output = try await proxy.generate(prompt: "hi")

    #expect(output.text == "system")
}

@Test func activeBackendProxyPropagatesBackendErrors() async {
    let proxy = ActiveBackendProxy(StubBackend(tag: "x", error: ProxyTestError.failed))

    await #expect(throws: ProxyTestError.failed) {
        _ = try await proxy.generate(prompt: "hi")
    }
}

private enum ProxyTestError: Error {
    case failed
}

private actor StubBackend: LocalLanguageModelService {
    let tag: String
    let error: Error?

    init(tag: String, error: Error? = nil) {
        self.tag = tag
        self.error = error
    }

    func generate(prompt: String) async throws -> ModelGenerationOutput {
        if let error { throw error }
        return ModelGenerationOutput(text: tag)
    }
}
