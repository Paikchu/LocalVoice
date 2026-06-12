import Foundation
import HuggingFace
import LocalVoiceCore
import MLXLLM
import MLXLMCommon
import Tokenizers

actor MLXLanguageModelService: LocalLanguageModelService {
    static let modelID = "mlx-community/Qwen3-4B-Instruct-2507-4bit"

    private let cache: HubCache
    private let hubClient: HubClient
    private var container: ModelContainer?
    private(set) var lastLoadSeconds: Double = 0

    init(
        cacheDirectory: URL = MLXLanguageModelService.defaultCacheDirectory
    ) {
        cache = HubCache(cacheDirectory: cacheDirectory)
        hubClient = HubClient(cache: cache)
    }

    func isInstalled() -> Bool {
        guard let repo = Repo.ID(rawValue: Self.modelID) else { return false }
        let snapshots = cache.snapshotsDirectory(repo: repo, kind: .model)
        guard let revisions = try? FileManager.default.contentsOfDirectory(
            at: snapshots,
            includingPropertiesForKeys: nil
        ) else {
            return false
        }
        return revisions.contains { revision in
            FileManager.default.fileExists(
                atPath: revision.appendingPathComponent("config.json").path
            ) && FileManager.default.fileExists(
                atPath: revision.appendingPathComponent("model.safetensors").path
            )
        }
    }

    func installedRevision() -> String {
        guard let repo = Repo.ID(rawValue: Self.modelID) else {
            return "unknown"
        }
        let snapshots = cache.snapshotsDirectory(repo: repo, kind: .model)
        let revisions = try? FileManager.default.contentsOfDirectory(
            at: snapshots,
            includingPropertiesForKeys: nil
        )
        return revisions?.first?.lastPathComponent ?? "unknown"
    }

    func prepare(
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> Double {
        if container != nil {
            progress(1)
            return lastLoadSeconds
        }

        let clock = ContinuousClock()
        let start = clock.now
        let configuration = ModelConfiguration(id: Self.modelID)
        container = try await LLMModelFactory.shared.loadContainer(
            from: HuggingFaceDownloader(hubClient),
            using: HuggingFaceTokenizerLoader(),
            configuration: configuration,
            useLatest: false
        ) { downloadProgress in
            progress(downloadProgress.fractionCompleted)
        }
        lastLoadSeconds = Self.seconds(from: start, to: clock.now)
        progress(1)
        return lastLoadSeconds
    }

    func unload() {
        container = nil
    }

    func removeFiles() throws {
        container = nil
        guard let repo = Repo.ID(rawValue: Self.modelID) else { return }
        let directory = cache.repoDirectory(repo: repo, kind: .model)
        if FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.removeItem(at: directory)
        }
    }

    func generate(prompt: String) async throws -> ModelGenerationOutput {
        guard let container else {
            throw LocalModelError.notLoaded
        }

        let clock = ContinuousClock()
        let start = clock.now
        let input = try await container.prepare(input: UserInput(prompt: prompt))
        let stream = try await container.generate(
            input: input,
            parameters: GenerateParameters(
                maxTokens: 2_048,
                temperature: 0.1,
                topP: 0.9,
                repetitionPenalty: 1.05
            )
        )

        var text = ""
        var firstTokenSeconds = 0.0
        var info: GenerateCompletionInfo?
        for await event in stream {
            try Task.checkCancellation()
            switch event {
            case .chunk(let chunk):
                if text.isEmpty {
                    firstTokenSeconds = Self.seconds(
                        from: start,
                        to: clock.now
                    )
                }
                text += chunk
            case .info(let completion):
                info = completion
            case .toolCall:
                break
            }
        }

        guard !text.isEmpty else {
            throw LocalModelError.emptyOutput
        }
        return ModelGenerationOutput(
            text: text,
            inputTokens: info?.promptTokenCount ?? 0,
            outputTokens: info?.generationTokenCount ?? 0,
            promptPrefillSeconds: info?.promptTime ?? 0,
            firstTokenSeconds: firstTokenSeconds,
            generationSeconds: info?.generateTime ?? 0
        )
    }

    static var defaultCacheDirectory: URL {
        let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!
        return applicationSupport
            .appendingPathComponent("LocalVoice", isDirectory: true)
            .appendingPathComponent("Models", isDirectory: true)
    }

    private static func seconds(
        from start: ContinuousClock.Instant,
        to end: ContinuousClock.Instant
    ) -> Double {
        let components = start.duration(to: end).components
        return Double(components.seconds)
            + Double(components.attoseconds) / 1_000_000_000_000_000_000
    }
}

enum LocalModelError: LocalizedError {
    case notLoaded
    case emptyOutput
    case invalidRepository

    var errorDescription: String? {
        switch self {
        case .notLoaded:
            return "本地模型尚未加载"
        case .emptyOutput:
            return "本地模型未返回内容"
        case .invalidRepository:
            return "本地模型地址无效"
        }
    }
}

private struct HuggingFaceDownloader: Downloader {
    let client: HubClient

    init(_ client: HubClient) {
        self.client = client
    }

    func download(
        id: String,
        revision: String?,
        matching patterns: [String],
        useLatest: Bool,
        progressHandler: @Sendable @escaping (Progress) -> Void
    ) async throws -> URL {
        guard let repo = Repo.ID(rawValue: id) else {
            throw LocalModelError.invalidRepository
        }
        return try await client.downloadSnapshot(
            of: repo,
            revision: revision ?? "main",
            matching: patterns,
            progressHandler: { @MainActor progress in
                progressHandler(progress)
            }
        )
    }
}

private struct HuggingFaceTokenizerLoader: TokenizerLoader {
    func load(from directory: URL) async throws -> any MLXLMCommon.Tokenizer {
        let tokenizer = try await Tokenizers.AutoTokenizer.from(
            modelFolder: directory
        )
        return HuggingFaceTokenizer(tokenizer)
    }
}

private struct HuggingFaceTokenizer: MLXLMCommon.Tokenizer {
    let upstream: any Tokenizers.Tokenizer

    init(_ upstream: any Tokenizers.Tokenizer) {
        self.upstream = upstream
    }

    func encode(text: String, addSpecialTokens: Bool) -> [Int] {
        upstream.encode(text: text, addSpecialTokens: addSpecialTokens)
    }

    func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String {
        upstream.decode(
            tokens: tokenIds,
            skipSpecialTokens: skipSpecialTokens
        )
    }

    func convertTokenToId(_ token: String) -> Int? {
        upstream.convertTokenToId(token)
    }

    func convertIdToToken(_ id: Int) -> String? {
        upstream.convertIdToToken(id)
    }

    var bosToken: String? { upstream.bosToken }
    var eosToken: String? { upstream.eosToken }
    var unknownToken: String? { upstream.unknownToken }

    func applyChatTemplate(
        messages: [[String: any Sendable]],
        tools: [[String: any Sendable]]?,
        additionalContext: [String: any Sendable]?
    ) throws -> [Int] {
        do {
            return try upstream.applyChatTemplate(
                messages: messages,
                tools: tools,
                additionalContext: additionalContext
            )
        } catch Tokenizers.TokenizerError.missingChatTemplate {
            throw MLXLMCommon.TokenizerError.missingChatTemplate
        }
    }
}
