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

@Test func removingModelBlocksDownloadAndRemovalActions() {
    let state = LanguageModelLifecycleState.removing

    #expect(state.isBusy)
    #expect(!state.allowsDownload)
    #expect(!state.allowsRemoval)
}

@Test func managedModelStorageRemovesRepositoryMetadataAndLocks() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let storage = ManagedModelStorage(
        rootDirectory: root,
        repositoryDirectoryName: "models--mlx-community--Qwen"
    )
    let unrelated = root.appendingPathComponent(
        "models--other--Model",
        isDirectory: true
    )

    for directory in storage.artifactDirectories + [unrelated] {
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        try Data("test".utf8).write(
            to: directory.appendingPathComponent("artifact")
        )
    }

    try storage.removeArtifacts()

    for directory in storage.artifactDirectories {
        #expect(!FileManager.default.fileExists(atPath: directory.path))
    }
    #expect(FileManager.default.fileExists(atPath: unrelated.path))
}

@Test func qwenRemovalRequiresExplicitConfirmation() throws {
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let source = try String(
        contentsOf: root.appendingPathComponent(
            "Sources/LocalVoiceApp/MenuBarContentView.swift"
        ),
        encoding: .utf8
    )

    #expect(source.contains("showsModelRemovalConfirmation"))
    #expect(source.contains("移除 Qwen 模型？"))
    #expect(source.contains("manager.remove()"))
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
