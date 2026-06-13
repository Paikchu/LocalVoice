import Foundation

/// Identifies a concrete LLM backend. New backends (e.g. Ollama) add a case here
/// and a corresponding `LanguageModelBackend` implementation; nothing in the
/// drafting pipeline needs to change.
public enum BackendKind: String, Sendable, Codable, CaseIterable {
    /// Apple's on-device system model exposed through the FoundationModels framework.
    case foundationModels
    /// A model we download and run locally (MLX / Hugging Face).
    case downloadableLocal
}

/// How a backend presents itself in the UI.
public struct BackendDescriptor: Sendable, Equatable {
    public let kind: BackendKind
    public let displayName: String
    public let detail: String

    public init(kind: BackendKind, displayName: String, detail: String) {
        self.kind = kind
        self.displayName = displayName
        self.detail = detail
    }
}

/// Whether a backend can serve requests on this machine right now. The reason is a
/// localized, user-facing string (e.g. "请在系统设置中开启 Apple 智能").
public enum BackendAvailability: Sendable, Equatable {
    case available
    case unavailable(reason: String)
}

/// Optional capability implemented only by backends that own a removable on-disk
/// asset (the downloadable model). OS-provided backends like FoundationModels
/// return `nil` from `LanguageModelBackend.managedAsset` and never implement this.
public protocol ManagedModelAsset: Sendable {
    func isInstalled() async -> Bool
    func installedRevision() async -> String
    func removeFiles() async throws
}

/// The full contract for a swappable backend: generation (inherited from
/// `LocalLanguageModelService`, which is all the drafting pipeline depends on) plus
/// identity, availability and load/unload lifecycle.
public protocol LanguageModelBackend: LocalLanguageModelService {
    nonisolated var descriptor: BackendDescriptor { get }
    func availability() async -> BackendAvailability

    /// Make the backend ready to generate. Returns load seconds (0 when N/A).
    /// `progress` reports 0…1 for backends that download; backends with nothing to
    /// fetch call it once with `1`.
    func prepare(progress: @escaping @Sendable (Double) -> Void) async throws -> Double
    func unload() async

    /// Non-nil only for backends that manage a removable on-disk asset.
    nonisolated var managedAsset: ManagedModelAsset? { get }
}

/// A stable `LocalLanguageModelService` the drafting pipeline can hold for its whole
/// lifetime while the active backend is swapped underneath it. `DraftProcessingService`
/// is constructed once with this proxy; `LocalModelManager` repoints it as backends
/// are resolved or switched.
public final class ActiveBackendProxy: LocalLanguageModelService, @unchecked Sendable {
    private let lock = NSLock()
    private var backend: any LocalLanguageModelService

    public init(_ backend: any LocalLanguageModelService) {
        self.backend = backend
    }

    public func setBackend(_ backend: any LocalLanguageModelService) {
        lock.withLock { self.backend = backend }
    }

    public func generate(prompt: String) async throws -> ModelGenerationOutput {
        let current = lock.withLock { backend }
        return try await current.generate(prompt: prompt)
    }
}
