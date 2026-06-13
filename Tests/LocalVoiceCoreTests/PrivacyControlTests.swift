import Foundation
import Testing
@testable import LocalVoiceCore

@Test func disabledProfileStoreDoesNotLoadLearnOrPersist() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }

    let fileURL = directory.appendingPathComponent("profile.json")
    let existing = UserProfile()
    let existingData = try JSONEncoder().encode(existing)
    try existingData.write(to: fileURL)

    let store = UserProfileStore(fileURL: fileURL, isEnabled: false)
    await store.load()
    await store.ingest(
        ProfileIngestInput(
            finalText: "联系我 test@example.com",
            mode: .dictation,
            wasEmail: false,
            usedFallback: false
        )
    )
    await store.flushNow()

    #expect(await store.snapshot().isEmpty)
    #expect(try Data(contentsOf: fileURL) == existingData)
}

@Test func clearingProfileStoreRemovesAllProfileArtifacts() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }

    let fileURL = directory.appendingPathComponent("profile.json")
    for suffix in ["", ".tmp", ".corrupt"] {
        try Data("private".utf8).write(
            to: URL(fileURLWithPath: fileURL.path + suffix)
        )
    }

    let store = UserProfileStore(fileURL: fileURL, isEnabled: true)
    try await store.clear()

    #expect(await store.snapshot().isEmpty)
    #expect(!FileManager.default.fileExists(atPath: fileURL.path))
    #expect(!FileManager.default.fileExists(atPath: fileURL.path + ".tmp"))
    #expect(!FileManager.default.fileExists(atPath: fileURL.path + ".corrupt"))
}

@Test func localModelUsesPinnedRevision() {
    #expect(LocalModelDescriptor.id == "mlx-community/Qwen3-4B-Instruct-2507-4bit")
    #expect(LocalModelDescriptor.revision == "50d427756c6b1b2fe0c0a10f67fbda1fc8e82c1b")
    #expect(LocalModelDescriptor.revision.count == 40)
    #expect(LocalModelDescriptor.revision.allSatisfy { $0.isHexDigit })
}

private func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(
        at: url,
        withIntermediateDirectories: true
    )
    return url
}
