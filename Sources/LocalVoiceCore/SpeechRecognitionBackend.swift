import Foundation

/// Identifies which speech-recognition implementation is active.
///
/// `apple` is the OS-provided `SFSpeechRecognizer` (zero download, always
/// available). `whisper` is the downloadable / bundled WhisperKit model, which
/// handles Chinese–English code-switching far better than Apple's `zh-CN`
/// on-device model. See the route-B design in `docs/plans`.
public enum SpeechRecognitionBackendKind:
    String,
    CaseIterable,
    Codable,
    Hashable,
    Sendable
{
    case apple
    case whisper

    public static let defaultValue: Self = .apple

    public var displayName: String {
        switch self {
        case .apple:
            return "Apple 语音"
        case .whisper:
            return "Whisper"
        }
    }
}

public struct SpeechRecognitionPreferenceStore {
    public static let key = "speechRecognitionBackend"

    private let defaults: UserDefaults
    private let key: String

    public init(
        defaults: UserDefaults = .standard,
        key: String = Self.key
    ) {
        self.defaults = defaults
        self.key = key
    }

    public func load() -> SpeechRecognitionBackendKind {
        guard let rawValue = defaults.string(forKey: key),
              let kind = SpeechRecognitionBackendKind(rawValue: rawValue) else {
            return .defaultValue
        }
        return kind
    }

    public func save(_ kind: SpeechRecognitionBackendKind) {
        defaults.set(kind.rawValue, forKey: key)
    }
}

/// A swappable speech-recognition engine.
///
/// The contract is intentionally identical to what `AppModel` already consumed
/// from the concrete Apple service so that backends are drop-in:
/// - `onPartial(text, isFinal, suspects)` streams partial transcripts during
///   capture and one final result. `suspects` carries low-confidence Latin
///   spans (see `SuspectSpan`) used by the LLM cleanup stage for contextual
///   correction; a backend with no per-segment confidence returns `[]`.
/// - `onLevel(level)` drives the live waveform meter, `0...1`.
/// - `onError(error)` reports a terminal capture/recognition failure.
///
/// Implementations must be safe to `start` again after `stop()`/`cancel()`.
public protocol SpeechRecognitionBackend: AnyObject {
    typealias PartialHandler = @Sendable (String, Bool, [SuspectSpan]) -> Void
    typealias LevelHandler = @Sendable (Float) -> Void
    typealias ErrorHandler = @Sendable (Error) -> Void

    /// Identifies the concrete engine, for UI and telemetry.
    var kind: SpeechRecognitionBackendKind { get }

    /// How long the session controller waits after `stop()` before finalizing
    /// with whatever partial text accumulated, in case no final result arrives.
    ///
    /// Streaming engines (Apple) deliver a final within a few hundred ms, so the
    /// grace is short. Chunk-decoded engines (Whisper) run inference over the
    /// whole clip on `stop()` and may take seconds; their final still arrives via
    /// `onPartial(isFinal: true)` and is what triggers processing — this grace is
    /// only the hang safety net, so it is much longer.
    var finalizationGrace: Duration { get }

    /// Begin audio capture and recognition.
    /// - Parameter contextualStrings: vocabulary hints (glossary terms, names)
    ///   the engine may bias toward. Engines that cannot use hints ignore them.
    func start(
        contextualStrings: [String],
        onPartial: @escaping PartialHandler,
        onLevel: @escaping LevelHandler,
        onError: @escaping ErrorHandler
    ) throws

    /// Stop capture and flush a final result through `onPartial`.
    func stop()

    /// Abort immediately; deliver no further partial, final, or error.
    func cancel()
}

public extension SpeechRecognitionBackend {
    /// Default grace tuned for streaming recognizers that finalize quickly.
    var finalizationGrace: Duration { .milliseconds(700) }
}
