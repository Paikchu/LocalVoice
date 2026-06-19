import AVFoundation
import Foundation
import LocalVoiceCore
import OSLog
@preconcurrency import WhisperKit

/// WhisperKit-backed speech recognition.
///
/// Unlike Apple's streaming recognizer, WhisperKit decodes whole audio chunks.
/// To keep LocalVoice's "live preview while recording, clean final on stop"
/// behavior, this backend:
/// - captures mic audio, resamples to 16 kHz mono, and accumulates it,
/// - periodically re-transcribes the accumulated buffer to emit partials,
/// - on `stop()`, runs one final transcription over the whole clip and rebuilds
///   `SuspectSpan`s from per-word probabilities (low-confidence Latin words are
///   exactly the "review→Refill" cases the LLM cleanup stage then corrects).
///
/// The model loads lazily on first use. When `modelFolder` is non-nil it loads
/// the bundled model with no download; otherwise WhisperKit downloads `model`
/// on first run (same on-demand pattern as the Qwen backend used to).
final class WhisperKitSpeechBackend: SpeechRecognitionBackend, @unchecked Sendable {
    let kind: SpeechRecognitionBackendKind = .whisper

    // Whisper runs inference over the full clip on stop(); allow seconds before
    // the partial-text fallback fires. The real final still arrives via onPartial.
    var finalizationGrace: Duration { .seconds(12) }

    private let modelVariant: String
    private let modelFolder: String?
    private let language: String
    private let partialInterval: Duration

    private let audioEngine = AVAudioEngine()
    private let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 16_000,
        channels: 1,
        interleaved: false
    )
    private var converter: AVAudioConverter?
    private var tapInstalled = false
    private var smoothedLevel: Float = 0

    // All mutable shared state lives in an actor to satisfy Swift 6 Sendable.
    private let store = WhisperStore()

    private var onPartial: PartialHandler?
    private var onLevel: LevelHandler?
    private var onError: ErrorHandler?

    private var partialTask: Task<Void, Never>?
    private var finalTask: Task<Void, Never>?

    private let logger = Logger(subsystem: "com.localvoice.app", category: "whisper")

    init(
        modelVariant: String = "openai_whisper-large-v3-v20240930_turbo_632MB",
        modelFolder: String? = WhisperKitSpeechBackend.bundledModelFolder(),
        language: String = "zh",
        partialInterval: Duration = .milliseconds(1_200)
    ) {
        self.modelVariant = modelVariant
        self.modelFolder = modelFolder
        self.language = language
        self.partialInterval = partialInterval
    }

    static func bundledModelFolder() -> String? {
        Bundle.main.url(forResource: "WhisperModels", withExtension: nil)?.path
    }

    // MARK: - SpeechRecognitionBackend

    func start(
        contextualStrings: [String] = [],
        onPartial: @escaping PartialHandler,
        onLevel: @escaping LevelHandler,
        onError: @escaping ErrorHandler
    ) throws {
        cancel()

        Task { await store.reset() }

        self.onPartial = onPartial
        self.onLevel = onLevel
        self.onError = onError

        let input = audioEngine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard let targetFormat,
              let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
            throw SpeechServiceError.recognizerUnavailable
        }
        self.converter = converter

        logger.info(
            "Whisper start inputRate=\(inputFormat.sampleRate) variant=\(self.modelVariant, privacy: .public) bundled=\(self.modelFolder != nil)"
        )

        input.installTap(onBus: 0, bufferSize: 1_024, format: inputFormat) {
            [weak self] buffer, _ in
            guard let self else { return }
            self.append(resampling: buffer)
            self.onLevel?(self.level(from: buffer))
        }
        tapInstalled = true

        audioEngine.prepare()
        try audioEngine.start()

        partialTask = Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            let kit: WhisperKit
            do {
                kit = try await self.ensureModel()
            } catch {
                self.deliver(error: error)
                return
            }
            while !Task.isCancelled {
                let stopped = await self.store.isStopped
                if stopped { break }
                try? await Task.sleep(for: self.partialInterval)
                if Task.isCancelled { break }
                let stopped2 = await self.store.isStopped
                if stopped2 { break }
                await self.runTranscription(kit, isFinal: false)
            }
        }
    }

    func stop() {
        Task { await store.setStopped() }
        teardownEngine()
        partialTask?.cancel()
        finalTask = Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            let kit: WhisperKit
            do {
                kit = try await self.ensureModel()
            } catch {
                self.deliver(error: error)
                return
            }
            await self.runTranscription(kit, isFinal: true)
        }
    }

    func cancel() {
        Task { await store.setStopped() }
        teardownEngine()
        partialTask?.cancel()
        finalTask?.cancel()
        partialTask = nil
        finalTask = nil
        onPartial = nil
        onLevel = nil
        onError = nil
        Task { await store.clearSamples() }
    }

    // MARK: - Model

    private func ensureModel() async throws -> WhisperKit {
        if let kit = await store.whisperKit {
            return kit
        }
        let variant = modelVariant
        let folder = modelFolder
        let config = WhisperKitConfig(
            model: variant,
            modelFolder: folder,
            download: folder == nil
        )
        let kit = try await WhisperKit(config)
        await store.setWhisperKit(kit)
        return kit
    }

    private func runTranscription(_ kit: WhisperKit, isFinal: Bool) async {
        // Partials skip if another transcription is already running.
        // The final waits until the slot is free so it sees the whole buffer.
        if isFinal {
            while await !store.claimTranscription() {
                try? await Task.sleep(for: .milliseconds(50))
            }
        } else {
            guard await store.claimTranscription() else { return }
        }
        defer { Task { await store.releaseTranscription() } }

        let samples = await store.snapshotSamples()
        guard samples.count > 1_600 else {
            if isFinal { deliver(text: "", isFinal: true, suspects: []) }
            return
        }

        do {
            let options = DecodingOptions(
                task: .transcribe,
                language: language,
                wordTimestamps: isFinal
            )
            let results = try await kit.transcribe(
                audioArray: samples,
                decodeOptions: options
            )
            let text = results
                .map(\.text)
                .joined()
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard isFinal || !text.isEmpty else { return }
            let suspects = isFinal ? Self.suspects(from: results) : []
            deliver(text: text, isFinal: isFinal, suspects: suspects)
        } catch {
            logger.error("Whisper transcribe failed: \(error.localizedDescription, privacy: .public)")
            if isFinal { deliver(error: error) }
        }
    }

    // Rebuild suspect spans from per-word probabilities. WhisperKit gives no
    // n-best alternatives; only the low-confidence threshold fires — which is
    // exactly the near-miss English-word case (review→Refill) we care about.
    private static func suspects(from results: [TranscriptionResult]) -> [SuspectSpan] {
        var infos: [TranscriptSegmentInfo] = []
        for result in results {
            for segment in result.segments {
                if let words = segment.words, !words.isEmpty {
                    for word in words {
                        let trimmed = word.word.trimmingCharacters(in: .whitespaces)
                        guard !trimmed.isEmpty else { continue }
                        infos.append(
                            TranscriptSegmentInfo(
                                text: trimmed,
                                confidence: Double(word.probability)
                            )
                        )
                    }
                } else {
                    let confidence = min(max(Double(exp(segment.avgLogprob)), 0), 1)
                    infos.append(
                        TranscriptSegmentInfo(
                            text: segment.text.trimmingCharacters(in: .whitespacesAndNewlines),
                            confidence: confidence
                        )
                    )
                }
            }
        }
        return SpeechSignalExtractor.suspects(best: infos, alternatives: [])
    }

    // MARK: - Audio capture

    private func append(resampling buffer: AVAudioPCMBuffer) {
        guard let converter, let targetFormat else { return }
        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 16
        guard let output = AVAudioPCMBuffer(
            pcmFormat: targetFormat,
            frameCapacity: capacity
        ) else { return }

        var supplied = false
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, inputStatus in
            if supplied {
                inputStatus.pointee = .noDataNow
                return nil
            }
            supplied = true
            inputStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, let channel = output.floatChannelData else { return }
        let count = Int(output.frameLength)
        guard count > 0 else { return }
        let samples = Array(UnsafeBufferPointer(start: channel[0], count: count))
        Task { await store.appendSamples(samples) }
    }

    private func level(from buffer: AVAudioPCMBuffer) -> Float {
        guard let data = buffer.floatChannelData?.pointee else { return 0 }
        let count = Int(buffer.frameLength)
        guard count > 0 else { return 0 }
        var sum: Float = 0
        for index in 0..<count {
            sum += data[index] * data[index]
        }
        let rms = sqrt(sum / Float(count))
        let normalized = min(max(rms * 8, 0), 1)
        let coefficient: Float = normalized > smoothedLevel ? 0.35 : 0.12
        smoothedLevel += (normalized - smoothedLevel) * coefficient
        return smoothedLevel
    }

    private func teardownEngine() {
        if audioEngine.isRunning { audioEngine.stop() }
        if tapInstalled {
            audioEngine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
    }

    // MARK: - Delivery

    private func deliver(text: String, isFinal: Bool, suspects: [SuspectSpan]) {
        onPartial?(text, isFinal, suspects)
    }

    private func deliver(error: Error) {
        onError?(error)
    }
}

// MARK: - Isolated mutable state

/// All mutable state shared between the audio tap (sync) and transcription
/// tasks (async) lives here so Swift 6's actor isolation is satisfied without
/// using NSLock in async contexts.
private actor WhisperStore {
    // WhisperKit is not declared Sendable; wrap in nonisolated(unsafe) so we
    // can hold it in the actor and hand it back to async callers that use it
    // only from a single task at a time (guarded by `transcribing` flag).
    nonisolated(unsafe) var whisperKit: WhisperKit?
    var sampleBuffer: [Float] = []
    var stopped = false
    var transcribing = false

    func reset() {
        sampleBuffer.removeAll(keepingCapacity: true)
        stopped = false
        transcribing = false
    }

    func setStopped() { stopped = true }

    var isStopped: Bool { stopped }

    func appendSamples(_ samples: [Float]) {
        sampleBuffer.append(contentsOf: samples)
    }

    func clearSamples() { sampleBuffer.removeAll(keepingCapacity: false) }

    func snapshotSamples() -> [Float] { sampleBuffer }

    func claimTranscription() -> Bool {
        if transcribing { return false }
        transcribing = true
        return true
    }

    func releaseTranscription() { transcribing = false }

    func setWhisperKit(_ kit: WhisperKit) { whisperKit = kit }
}
