import Foundation

public enum LanguageModelBackendKind:
    String,
    CaseIterable,
    Codable,
    Hashable,
    Sendable
{
    case foundationModels

    public static let defaultValue: Self = .foundationModels

    public var displayName: String {
        switch self {
        case .foundationModels:
            return "Foundation Models"
        }
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
    case loading
    case ready
    case unavailable(String)
    case failed(String)

    public var isBusy: Bool {
        self == .loading
    }
}

public protocol LanguageModelBackend: LocalLanguageModelService {
    nonisolated var descriptor: LanguageModelBackendDescriptor { get }

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
