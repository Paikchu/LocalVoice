import AVFoundation
import Foundation
import LocalVoiceCore
import Security
import Speech

@main
enum LocalVoiceQualityBench {
    static func main() async throws {
        let launchRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let options = Options.parse(root: launchRoot)
        let samples = try loadManifest(options.manifestURL)
        try FileManager.default.createDirectory(
            at: options.reportURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: options.jsonURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let environment = EnvironmentSnapshot.capture(root: options.rootURL)
        let model = FoundationModelBackend()
        let modelStatus = await prepareFoundationModel(model)
        let speechStatus = options.asrProvider == .apple
            ? await FileSpeechRecognizer.authorize()
            : nil
        let speechAuthorization = speechStatus?.description ?? "not used"

        var rows: [CaseResult] = []
        for (index, sample) in samples.enumerated() {
            print("[\(index + 1)/\(samples.count)] \(sample.id)")
            let audioURL = resolve(sample.audioPath, relativeTo: options.rootURL)
            let duration = audioDurationSeconds(audioURL)
            let recognition = await recognize(
                audioURL: audioURL,
                provider: options.asrProvider,
                openRouterModel: options.openRouterModel,
                authorization: speechStatus
            )
            let asrScore = recognition.transcript.map {
                ASRQualityEvaluator.evaluate(
                    reference: sample.verbatimReference,
                    hypothesis: $0,
                    audioDurationSeconds: duration,
                    recognitionSeconds: recognition.seconds
                )
            }
            let fromASR = await processIfPossible(
                transcript: recognition.transcript ?? "",
                sample: sample,
                model: model,
                modelStatus: modelStatus
            )
            let oracle = await processIfPossible(
                transcript: sample.verbatimReference,
                sample: sample,
                model: model,
                modelStatus: modelStatus
            )
            rows.append(
                CaseResult(
                    sample: sample,
                    rawTranscript: recognition.transcript,
                    asr: asrScore,
                    llmFromASR: fromASR,
                    llmOracle: oracle,
                    recognitionError: recognition.error,
                    audioDurationSeconds: duration
                )
            )
        }

        let report = BenchmarkReport(
            environment: environment,
            model: modelStatus,
            speechProvider: options.asrProvider.description,
            speechAuthorization: speechAuthorization,
            rows: rows
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(report).write(to: options.jsonURL)
        try makeMarkdown(report)
            .write(to: options.reportURL, atomically: true, encoding: .utf8)
        print("JSON: \(options.jsonURL.path)")
        print("Report: \(options.reportURL.path)")
    }

    private static func loadManifest(_ url: URL) throws -> [AudioBenchmarkSample] {
        let text = try String(contentsOf: url, encoding: .utf8)
        let decoder = JSONDecoder()
        return try text
            .split(whereSeparator: \.isNewline)
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .map { line in
                try decoder.decode(
                    AudioBenchmarkSample.self,
                    from: Data(String(line).utf8)
                )
            }
    }

    private static func prepareFoundationModel(
        _ model: FoundationModelBackend
    ) async -> ModelStatus {
        let descriptor = model.descriptor
        switch await model.availability() {
        case .available:
            do {
                let loadSeconds = try await model.prepare { _ in }
                return ModelStatus(
                    id: descriptor.title,
                    revision: "system",
                    loadSeconds: loadSeconds,
                    error: nil
                )
            } catch {
                return ModelStatus(
                    id: descriptor.title,
                    revision: "system",
                    loadSeconds: 0,
                    error: error.localizedDescription
                )
            }
        case .unavailable(let message):
            return ModelStatus(
                id: descriptor.title,
                revision: "system",
                loadSeconds: 0,
                error: message
            )
        }
    }

    private static func processIfPossible(
        transcript: String,
        sample: AudioBenchmarkSample,
        model: FoundationModelBackend,
        modelStatus: ModelStatus
    ) async -> ProcessedResult? {
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let error = modelStatus.error {
            return ProcessedResult(
                outputText: "",
                evaluation: nil,
                totalSeconds: 0,
                generationAttempts: 0,
                usedFallback: false,
                error: error
            )
        }
        let processor = DraftProcessingService(
            languageModel: model,
            timeout: .seconds(30)
        )
        let outcome = await processor.process(
            transcript: trimmed,
            mode: sample.mode,
            signature: ""
        )
        let evaluation = ProcessingQualityEvaluatorV2.evaluate(
            outcome.result,
            against: sample
        )
        return ProcessedResult(
            outputText: outcome.result.outputText,
            evaluation: evaluation,
            totalSeconds: outcome.totalSeconds,
            generationAttempts: outcome.generationAttempts,
            usedFallback: outcome.usedFallback,
            error: nil
        )
    }

    private static func audioDurationSeconds(_ url: URL) -> Double {
        guard let file = try? AVAudioFile(forReading: url) else { return 0 }
        let sampleRate = file.processingFormat.sampleRate
        guard sampleRate > 0 else { return 0 }
        return Double(file.length) / sampleRate
    }

    private static func resolve(_ path: String, relativeTo root: URL) -> URL {
        if path.hasPrefix("/") {
            return URL(fileURLWithPath: path)
        }
        return root.appendingPathComponent(path)
    }

    private static func recognize(
        audioURL: URL,
        provider: ASRProvider,
        openRouterModel: String,
        authorization: SFSpeechRecognizerAuthorizationStatus?
    ) async -> RecognitionResult {
        switch provider {
        case .apple:
            return await FileSpeechRecognizer().recognize(
                audioURL: audioURL,
                authorization: authorization ?? .denied
            )
        case .openRouter:
            return await OpenRouterFileRecognizer(model: openRouterModel)
                .recognize(audioURL: audioURL)
        }
    }
}

private struct Options {
    let rootURL: URL
    let manifestURL: URL
    let reportURL: URL
    let jsonURL: URL
    let asrProvider: ASRProvider
    let openRouterModel: String

    static func parse(root: URL) -> Self {
        let timestamp = Self.timestamp()
        let date = String(timestamp.prefix(10))
        var manifest = root.appendingPathComponent(
            "benchmark-data/fleurs-zh_cn/smoke.jsonl"
        )
        var report = root.appendingPathComponent(
            "docs/reports/\(date)-localvoice-quality-benchmark.md"
        )
        var json = root.appendingPathComponent(
            "benchmark-results/\(timestamp)-\(commandOutput("/usr/bin/git", ["rev-parse", "--short", "HEAD"])).json"
        )
        var asrProvider = ASRProvider.apple
        var openRouterModel = "openai/gpt-4o-mini-transcribe"

        var index = 1
        let args = CommandLine.arguments
        while index < args.count {
            let key = args[index]
            let value = index + 1 < args.count ? args[index + 1] : nil
            switch key {
            case "--manifest":
                if let value { manifest = root.appendingPathComponent(value) }
                index += 2
            case "--report":
                if let value { report = root.appendingPathComponent(value) }
                index += 2
            case "--json":
                if let value { json = root.appendingPathComponent(value) }
                index += 2
            case "--asr":
                if let value, let provider = ASRProvider(rawValue: value) {
                    asrProvider = provider
                }
                index += 2
            case "--openrouter-model":
                if let value { openRouterModel = value }
                index += 2
            default:
                index += 1
            }
        }
        return Self(
            rootURL: inferRoot(fromManifest: manifest) ?? root,
            manifestURL: manifest,
            reportURL: report,
            jsonURL: json,
            asrProvider: asrProvider,
            openRouterModel: openRouterModel
        )
    }

    private static func inferRoot(fromManifest manifest: URL) -> URL? {
        let marker = "/benchmark-data/"
        guard let range = manifest.path.range(of: marker) else { return nil }
        return URL(fileURLWithPath: String(manifest.path[..<range.lowerBound]))
    }

    private static func timestamp() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
    }
}

private enum ASRProvider: String {
    case apple
    case openRouter = "openrouter"

    var description: String {
        switch self {
        case .apple:
            return "Apple Speech"
        case .openRouter:
            return "OpenRouter"
        }
    }
}

private final class FileSpeechRecognizer {
    static func authorize() async -> SFSpeechRecognizerAuthorizationStatus {
        await withCheckedContinuation { continuation in
            let box = SpeechAuthorizationContinuationBox(
                continuation: continuation
            )
            SFSpeechRecognizer.requestAuthorization { status in
                box.resume(status)
            }
            Task {
                try? await Task.sleep(for: .seconds(15))
                box.resume(.notDetermined)
            }
        }
    }

    func recognize(
        audioURL: URL,
        authorization: SFSpeechRecognizerAuthorizationStatus
    ) async -> RecognitionResult {
        guard authorization == .authorized else {
            return RecognitionResult(
                transcript: nil,
                seconds: 0,
                error: "Speech authorization is \(authorization.description)"
            )
        }
        guard FileManager.default.fileExists(atPath: audioURL.path) else {
            return RecognitionResult(
                transcript: nil,
                seconds: 0,
                error: "Audio file not found: \(audioURL.path)"
            )
        }
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "zh-CN")),
              recognizer.isAvailable else {
            return RecognitionResult(
                transcript: nil,
                seconds: 0,
                error: "zh-CN speech recognizer unavailable"
            )
        }
        guard recognizer.supportsOnDeviceRecognition else {
            return RecognitionResult(
                transcript: nil,
                seconds: 0,
                error: "zh-CN on-device speech recognition unavailable"
            )
        }

        let request = SFSpeechURLRecognitionRequest(url: audioURL)
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = false
        request.addsPunctuation = true
        request.taskHint = .dictation

        let clock = ContinuousClock()
        let start = clock.now
        return await withCheckedContinuation { continuation in
            let box = RecognitionContinuationBox(continuation: continuation)
            _ = recognizer.recognitionTask(with: request) { result, error in
                if let result, result.isFinal {
                    box.resume(
                        RecognitionResult(
                            transcript: result.bestTranscription.formattedString,
                            seconds: seconds(from: start, to: clock.now),
                            error: nil
                        )
                    )
                    return
                }
                if let error {
                    box.resume(
                        RecognitionResult(
                            transcript: nil,
                            seconds: seconds(from: start, to: clock.now),
                            error: error.localizedDescription
                        )
                    )
                }
            }
        }
    }
}

private final class OpenRouterFileRecognizer {
    private let model: String

    init(model: String) {
        self.model = model
    }

    func recognize(audioURL: URL) async -> RecognitionResult {
        guard let apiKey = Self.loadAPIKey() else {
            return RecognitionResult(
                transcript: nil,
                seconds: 0,
                error: "Missing OPENROUTER_API_KEY"
            )
        }
        guard FileManager.default.fileExists(atPath: audioURL.path) else {
            return RecognitionResult(
                transcript: nil,
                seconds: 0,
                error: "Audio file not found: \(audioURL.path)"
            )
        }

        let clock = ContinuousClock()
        let start = clock.now
        do {
            let wav = try Data(contentsOf: audioURL)
            let response = try await OpenRouterTranscriptionClient(
                apiKey: apiKey
            ).transcribe(
                wavAudio: wav,
                model: model,
                language: "zh"
            )
            return RecognitionResult(
                transcript: response.text,
                seconds: seconds(from: start, to: clock.now),
                error: nil
            )
        } catch {
            return RecognitionResult(
                transcript: nil,
                seconds: seconds(from: start, to: clock.now),
                error: error.localizedDescription
            )
        }
    }

    private static func loadAPIKey() -> String? {
        if let apiKey = ProcessInfo.processInfo.environment["OPENROUTER_API_KEY"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !apiKey.isEmpty {
            return apiKey
        }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.localvoice.openrouter",
            kSecAttrAccount as String: "api-key",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess,
              let data = item as? Data,
              let value = String(data: data, encoding: .utf8) else {
            return nil
        }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

private final class SpeechAuthorizationContinuationBox: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation:
        CheckedContinuation<SFSpeechRecognizerAuthorizationStatus, Never>?

    init(
        continuation: CheckedContinuation<SFSpeechRecognizerAuthorizationStatus, Never>
    ) {
        self.continuation = continuation
    }

    func resume(_ status: SFSpeechRecognizerAuthorizationStatus) {
        lock.lock()
        let continuation = continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(returning: status)
    }
}

private final class RecognitionContinuationBox {
    private var didResume = false
    private let continuation: CheckedContinuation<RecognitionResult, Never>

    init(continuation: CheckedContinuation<RecognitionResult, Never>) {
        self.continuation = continuation
    }

    func resume(_ result: RecognitionResult) {
        guard !didResume else { return }
        didResume = true
        continuation.resume(returning: result)
    }
}

private struct RecognitionResult {
    let transcript: String?
    let seconds: Double
    let error: String?
}

private struct BenchmarkReport: Codable {
    let environment: EnvironmentSnapshot
    let model: ModelStatus
    let speechProvider: String
    let speechAuthorization: String
    let rows: [CaseResult]
    let summary: QualityBenchmarkSummary

    init(
        environment: EnvironmentSnapshot,
        model: ModelStatus,
        speechProvider: String,
        speechAuthorization: String,
        rows: [CaseResult]
    ) {
        self.environment = environment
        self.model = model
        self.speechProvider = speechProvider
        self.speechAuthorization = speechAuthorization
        self.rows = rows
        summary = QualityBenchmarkSummary(
            rows: rows.map {
                QualityBenchmarkRow(
                    sample: $0.sample,
                    asr: $0.asr,
                    llmFromASR: $0.llmFromASR?.evaluation,
                    llmOracle: $0.llmOracle?.evaluation,
                    recognitionError: $0.recognitionError
                )
            }
        )
    }
}

private struct CaseResult: Codable {
    let sample: AudioBenchmarkSample
    let rawTranscript: String?
    let asr: ASRQualityScore?
    let llmFromASR: ProcessedResult?
    let llmOracle: ProcessedResult?
    let recognitionError: String?
    let audioDurationSeconds: Double
}

private struct ProcessedResult: Codable {
    let outputText: String
    let evaluation: ProcessingQualityEvaluationV2?
    let totalSeconds: Double
    let generationAttempts: Int
    let usedFallback: Bool
    let error: String?
}

private struct ModelStatus: Codable {
    let id: String
    let revision: String
    let loadSeconds: Double
    let error: String?
}

private struct EnvironmentSnapshot: Codable {
    let commit: String
    let chip: String
    let memoryGB: String
    let macOS: String

    static func capture(root: URL) -> Self {
        Self(
            commit: commandOutput(
                "/usr/bin/git",
                ["-C", root.path, "rev-parse", "--short", "HEAD"]
            ),
            chip: commandOutput("/usr/sbin/sysctl", ["-n", "machdep.cpu.brand_string"]),
            memoryGB: format(
                Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824
            ),
            macOS: ProcessInfo.processInfo.operatingSystemVersionString
        )
    }
}

private func makeMarkdown(_ report: BenchmarkReport) -> String {
    let rows = report.rows
    let failures = rows.filter {
        $0.recognitionError != nil
            || $0.llmFromASR?.evaluation?.passed == false
            || $0.llmOracle?.evaluation?.passed == false
    }
    let fromASR = rows.compactMap(\.llmFromASR?.evaluation)
    let oracle = rows.compactMap(\.llmOracle?.evaluation)
    return """
    # LocalVoice Quality Benchmark Report

    - Commit: `\(report.environment.commit)`
    - macOS: \(report.environment.macOS)
    - Chip: \(report.environment.chip)
    - Memory: \(report.environment.memoryGB) GB
    - Model: `\(report.model.id)`
    - Model revision: `\(report.model.revision)`
    - Model load: \(format(report.model.loadSeconds))s
    - Model error: \(report.model.error ?? "none")
    - Speech provider: \(report.speechProvider)
    - Speech authorization: \(report.speechAuthorization)
    - Source: `\(rows.first?.sample.sourceDataset ?? "unknown")`
    - Source license: `\(rows.first?.sample.sourceLicense ?? "unknown")`
    - Samples: \(report.summary.sampleCount)

    ## ASR Raw

    | Metric | Result |
    |---|---:|
    | Recognized | \(report.summary.recognizedCount)/\(report.summary.sampleCount) |
    | CER | \(format(report.summary.asrCER)) |
    | WER | \(format(report.summary.asrWER)) |
    | RTFx | \(format(report.summary.asrRTFx)) |
    | Empty-reference hallucinations | \(report.summary.asrHallucinationCount) |

    ## LLM Processing

    | Path | Pass rate |
    |---|---:|
    | LLM from ASR | \(llmRate(fromASR, fallback: report.model.error)) |
    | LLM oracle from reference | \(llmRate(oracle, fallback: report.model.error)) |

    ## Failure Cases

    \(failureLines(failures))
    """
}

private func failureLines(_ rows: [CaseResult]) -> String {
    guard !rows.isEmpty else { return "- None" }
    return rows.prefix(30).map { row in
        let fromASR = row.llmFromASR?.evaluation
        let oracle = row.llmOracle?.evaluation
        return "- `\(row.sample.id)`: recognition=`\(row.recognitionError ?? "ok")`, "
            + "fromASR=\(fromASR?.passed.description ?? "n/a"), "
            + "oracle=\(oracle?.passed.description ?? "n/a"), "
            + "llmError=\(row.llmFromASR?.error ?? row.llmOracle?.error ?? "none"), "
            + "missing=\((fromASR?.missingFacts ?? []).joined(separator: ",")), "
            + "forbidden=\((fromASR?.forbiddenClaims ?? []).joined(separator: ","))"
    }.joined(separator: "\n")
}

private func llmRate(
    _ evaluations: [ProcessingQualityEvaluationV2],
    fallback: String?
) -> String {
    guard !evaluations.isEmpty else {
        return fallback.map { "not run (\($0))" } ?? "not run"
    }
    let rate = Double(evaluations.filter(\.passed).count)
        / Double(evaluations.count)
    return "\(percent(rate)) (\(evaluations.filter(\.passed).count)/\(evaluations.count))"
}

private func seconds(
    from start: ContinuousClock.Instant,
    to end: ContinuousClock.Instant
) -> Double {
    let duration = start.duration(to: end).components
    return Double(duration.seconds)
        + Double(duration.attoseconds) / 1_000_000_000_000_000_000
}

private func format(_ value: Double) -> String {
    String(format: "%.2f", value)
}

private func percent(_ value: Double) -> String {
    String(format: "%.2f%%", value * 100)
}

private func commandOutput(
    _ executable: String,
    _ arguments: [String]
) -> String {
    let process = Process()
    let pipe = Pipe()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    do {
        try process.run()
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return output.isEmpty ? "unknown" : output
    } catch {
        return "unknown"
    }
}

private extension SFSpeechRecognizerAuthorizationStatus {
    var description: String {
        switch self {
        case .notDetermined:
            return "notDetermined"
        case .denied:
            return "denied"
        case .restricted:
            return "restricted"
        case .authorized:
            return "authorized"
        @unknown default:
            return "unknown"
        }
    }
}
