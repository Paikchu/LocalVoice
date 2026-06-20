import Foundation

/// Identifies which speech-recognition implementation is active.
///
/// `openRouter` is the cloud STT path. `apple` is the OS-provided
/// `SFSpeechRecognizer` fallback.
public enum SpeechRecognitionBackendKind:
    String,
    CaseIterable,
    Codable,
    Hashable,
    Sendable
{
    case openRouter
    case apple

    public static let defaultValue: Self = .openRouter

    public var displayName: String {
        switch self {
        case .openRouter:
            return "OpenRouter"
        case .apple:
            return "Apple 语音"
        }
    }
}

public struct OpenRouterTranscriptionRequest: Encodable, Sendable {
    public struct InputAudio: Encodable, Equatable, Sendable {
        public let data: String
        public let format: String
    }

    public let model: String
    public let inputAudio: InputAudio
    public let language: String?
    public let temperature: Double?

    public init(
        model: String,
        audio: Data,
        format: String,
        language: String? = nil,
        temperature: Double? = nil
    ) {
        self.model = model
        inputAudio = InputAudio(
            data: audio.base64EncodedString(),
            format: format
        )
        self.language = language
        self.temperature = temperature
    }

    private enum CodingKeys: String, CodingKey {
        case model
        case inputAudio = "input_audio"
        case language
        case temperature
    }
}

public struct OpenRouterTranscriptionResponse: Decodable, Equatable, Sendable {
    public struct Usage: Decodable, Equatable, Sendable {
        public let seconds: Double?
        public let totalTokens: Int?
        public let inputTokens: Int?
        public let outputTokens: Int?
        public let cost: Double?

        private enum CodingKeys: String, CodingKey {
            case seconds
            case totalTokens = "total_tokens"
            case inputTokens = "input_tokens"
            case outputTokens = "output_tokens"
            case cost
        }
    }

    public let text: String
    public let usage: Usage?
}

public enum OpenRouterTranscriptionError: LocalizedError, Equatable {
    case missingAPIKey
    case invalidResponse
    case requestFailed(Int, String)
    case emptyTranscript

    public var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "未配置 OpenRouter API key"
        case .invalidResponse:
            return "OpenRouter 返回格式无效"
        case .requestFailed(let status, let message):
            return "OpenRouter 转写失败（\(status)）：\(message)"
        case .emptyTranscript:
            return "OpenRouter 未返回文字"
        }
    }
}

public struct OpenRouterTranscriptionClient: Sendable {
    public static let defaultEndpoint = URL(
        string: "https://openrouter.ai/api/v1/audio/transcriptions"
    )!

    private let apiKey: String
    private let endpoint: URL
    private let session: URLSession

    public init(
        apiKey: String,
        endpoint: URL = Self.defaultEndpoint,
        session: URLSession = .shared
    ) {
        self.apiKey = apiKey
        self.endpoint = endpoint
        self.session = session
    }

    public func transcribe(
        wavAudio: Data,
        model: String,
        language: String? = "zh"
    ) async throws -> OpenRouterTranscriptionResponse {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue(
            "Bearer \(apiKey)",
            forHTTPHeaderField: "Authorization"
        )
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(
            OpenRouterTranscriptionRequest(
                model: model,
                audio: wavAudio,
                format: "wav",
                language: language,
                temperature: 0
            )
        )

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw OpenRouterTranscriptionError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            let message = String(decoding: data, as: UTF8.self)
            throw OpenRouterTranscriptionError.requestFailed(
                http.statusCode,
                message
            )
        }
        let decoded = try JSONDecoder().decode(
            OpenRouterTranscriptionResponse.self,
            from: data
        )
        guard !decoded.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw OpenRouterTranscriptionError.emptyTranscript
        }
        return decoded
    }
}

public enum PCM16WAVEncoder {
    public static func encode(samples: [Float], sampleRate: Int) -> Data {
        var data = Data()
        let byteRate = UInt32(sampleRate * 2)
        let blockAlign: UInt16 = 2
        let bitsPerSample: UInt16 = 16
        let sampleBytes = UInt32(samples.count * 2)

        data.appendASCII("RIFF")
        data.appendLE(UInt32(36) + sampleBytes)
        data.appendASCII("WAVE")
        data.appendASCII("fmt ")
        data.appendLE(UInt32(16))
        data.appendLE(UInt16(1))
        data.appendLE(UInt16(1))
        data.appendLE(UInt32(sampleRate))
        data.appendLE(byteRate)
        data.appendLE(blockAlign)
        data.appendLE(bitsPerSample)
        data.appendASCII("data")
        data.appendLE(sampleBytes)

        for sample in samples {
            let clipped = max(-1, min(1, sample))
            let value = Int16(clipped * Float(Int16.max))
            data.appendLE(value)
        }
        return data
    }
}

private extension Data {
    mutating func appendASCII(_ value: String) {
        append(contentsOf: value.utf8)
    }

    mutating func appendLE(_ value: UInt16) {
        var copy = value.littleEndian
        Swift.withUnsafeBytes(of: &copy) { append(contentsOf: $0) }
    }

    mutating func appendLE(_ value: Int16) {
        var copy = value.littleEndian
        Swift.withUnsafeBytes(of: &copy) { append(contentsOf: $0) }
    }

    mutating func appendLE(_ value: UInt32) {
        var copy = value.littleEndian
        Swift.withUnsafeBytes(of: &copy) { append(contentsOf: $0) }
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

    /// Begin loading the underlying model in the background.
    /// Call `onReady` on the main actor when the model is ready to transcribe.
    /// Engines with no model to load call `onReady` immediately.
    func preload(onReady: @escaping @MainActor @Sendable () -> Void)
}

public extension SpeechRecognitionBackend {
    /// Default grace tuned for streaming recognizers that finalize quickly.
    var finalizationGrace: Duration { .milliseconds(700) }

    /// Default: no model to load — ready immediately.
    func preload(onReady: @escaping @MainActor @Sendable () -> Void) {
        Task { @MainActor in onReady() }
    }
}
