import Foundation

public enum LanguageModelBackendKind:
    String,
    CaseIterable,
    Codable,
    Hashable,
    Sendable
{
    case qwen
    case foundationModels

    public static let defaultValue: Self = .qwen

    public var displayName: String {
        switch self {
        case .qwen:
            return "Qwen"
        case .foundationModels:
            return "Foundation Models"
        }
    }
}

public struct LanguageModelPreferenceStore {
    public static let key = "languageModelBackend"

    private let defaults: UserDefaults
    private let key: String

    public init(
        defaults: UserDefaults = .standard,
        key: String = Self.key
    ) {
        self.defaults = defaults
        self.key = key
    }

    public func load() -> LanguageModelBackendKind {
        guard let rawValue = defaults.string(forKey: key),
              let backend = LanguageModelBackendKind(rawValue: rawValue) else {
            return .defaultValue
        }
        return backend
    }

    public func save(_ backend: LanguageModelBackendKind) {
        defaults.set(backend.rawValue, forKey: key)
    }
}

public struct LanguageModelBackendDescriptor: Equatable, Sendable {
    public let kind: LanguageModelBackendKind
    public let title: String
    public let detail: String

    public init(
        kind: LanguageModelBackendKind,
        title: String,
        detail: String
    ) {
        self.kind = kind
        self.title = title
        self.detail = detail
    }
}

public enum LanguageModelBackendAvailability: Equatable, Sendable {
    case available
    case unavailable(String)
}

public enum LanguageModelLifecycleState: Equatable, Sendable {
    case notInstalled
    case downloading(Double)
    case loading
    case ready
    case removing
    case unavailable(String)
    case failed(String)

    public var isBusy: Bool {
        switch self {
        case .downloading, .loading, .removing:
            return true
        default:
            return false
        }
    }

    public var allowsDownload: Bool {
        switch self {
        case .notInstalled, .unavailable, .failed:
            return true
        default:
            return false
        }
    }

    public var allowsRemoval: Bool {
        self == .ready
    }
}

public struct ManagedModelStorage: Sendable {
    public let rootDirectory: URL
    public let repositoryDirectoryName: String

    public init(
        rootDirectory: URL,
        repositoryDirectoryName: String
    ) {
        self.rootDirectory = rootDirectory
        self.repositoryDirectoryName = repositoryDirectoryName
    }

    public var artifactDirectories: [URL] {
        [
            rootDirectory.appendingPathComponent(
                repositoryDirectoryName,
                isDirectory: true
            ),
            rootDirectory
                .appendingPathComponent(".metadata", isDirectory: true)
                .appendingPathComponent(
                    repositoryDirectoryName,
                    isDirectory: true
                ),
            rootDirectory
                .appendingPathComponent(".locks", isDirectory: true)
                .appendingPathComponent(
                    repositoryDirectoryName,
                    isDirectory: true
                )
        ]
    }

    public func removeArtifacts(
        fileManager: FileManager = .default
    ) throws {
        for directory in artifactDirectories
        where fileManager.fileExists(atPath: directory.path) {
            try fileManager.removeItem(at: directory)
        }
    }
}

public protocol ManagedLanguageModelAsset: Sendable {
    func isInstalled() async -> Bool
    func removeFiles() async throws
}

public protocol LanguageModelBackend: LocalLanguageModelService {
    nonisolated var descriptor: LanguageModelBackendDescriptor { get }
    nonisolated var managedAsset: (any ManagedLanguageModelAsset)? { get }

    func availability() async -> LanguageModelBackendAvailability
    func prepare(
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> Double
    func unload() async
}

public final class ActiveBackendProxy:
    LocalLanguageModelService,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var backend: any LocalLanguageModelService

    public init(_ backend: any LocalLanguageModelService) {
        self.backend = backend
    }

    public func setBackend(_ backend: any LocalLanguageModelService) {
        lock.withLock {
            self.backend = backend
        }
    }

    public func generate(prompt: String) async throws -> ModelGenerationOutput {
        let current = lock.withLock { backend }
        return try await current.generate(prompt: prompt)
    }

    public func generate(
        prompt: String,
        onProgress: @escaping @Sendable (ModelGenerationProgress) -> Void
    ) async throws -> ModelGenerationOutput {
        let current = lock.withLock { backend }
        return try await current.generate(
            prompt: prompt,
            onProgress: onProgress
        )
    }
}
