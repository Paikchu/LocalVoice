import AVFoundation
import Foundation
import LocalVoiceCore
import OSLog

final class OpenRouterSpeechBackend: SpeechRecognitionBackend, @unchecked Sendable {
    let kind: SpeechRecognitionBackendKind = .openRouter
    var finalizationGrace: Duration { .seconds(20) }

    private let model: String
    private let language: String
    private let partialInterval: Duration
    private let sampleRate = 16_000

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

    private let store = OpenRouterSpeechStore()
    private var onPartial: PartialHandler?
    private var onLevel: LevelHandler?
    private var onError: ErrorHandler?
    private var partialTask: Task<Void, Never>?
    private var finalTask: Task<Void, Never>?
    private let logger = Logger(
        subsystem: "com.localvoice.app",
        category: "openrouter-speech"
    )

    init(
        model: String = "openai/gpt-4o-mini-transcribe",
        language: String = "zh",
        partialInterval: Duration = .seconds(5)
    ) {
        self.model = model
        self.language = language
        self.partialInterval = partialInterval
    }

    func preload(onReady: @escaping @MainActor @Sendable () -> Void) {
        Task { @MainActor in onReady() }
    }

    func start(
        contextualStrings: [String] = [],
        onPartial: @escaping PartialHandler,
        onLevel: @escaping LevelHandler,
        onError: @escaping ErrorHandler
    ) throws {
        cancel()
        guard OpenRouterAPIKeyStore.load() != nil else {
            throw OpenRouterTranscriptionError.missingAPIKey
        }

        store.reset()
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

        logger.info("OpenRouter ASR start inputRate=\(inputFormat.sampleRate) model=\(self.model, privacy: .public)")

        input.installTap(onBus: 0, bufferSize: 1_024, format: inputFormat) {
            [weak self] buffer, _ in
            guard let self else { return }
            self.append(resampling: buffer)
            self.onLevel?(self.level(from: buffer))
        }
        tapInstalled = true

        audioEngine.prepare()
        try audioEngine.start()

        partialTask = Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: self.partialInterval)
                if Task.isCancelled || self.store.isStopped { break }
                await self.runTranscription(isFinal: false)
            }
        }
    }

    func stop() {
        store.setStopped()
        teardownEngine()
        partialTask?.cancel()
        finalTask = Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            await self.runTranscription(isFinal: true)
        }
    }

    func cancel() {
        store.setStopped()
        teardownEngine()
        partialTask?.cancel()
        finalTask?.cancel()
        partialTask = nil
        finalTask = nil
        onPartial = nil
        onLevel = nil
        onError = nil
        store.clearSamples()
    }

    private func runTranscription(isFinal: Bool) async {
        if isFinal {
            while !store.claimTranscription() {
                try? await Task.sleep(for: .milliseconds(50))
            }
        } else {
            guard store.claimTranscription() else { return }
        }
        defer { store.releaseTranscription() }

        let samples = store.snapshotSamples()
        guard samples.count > sampleRate / 4 else {
            if isFinal { deliver(text: "", isFinal: true) }
            return
        }
        guard let apiKey = OpenRouterAPIKeyStore.load() else {
            deliver(error: OpenRouterTranscriptionError.missingAPIKey)
            return
        }

        do {
            let wav = PCM16WAVEncoder.encode(
                samples: samples,
                sampleRate: sampleRate
            )
            let response = try await OpenRouterTranscriptionClient(
                apiKey: apiKey
            ).transcribe(
                wavAudio: wav,
                model: model,
                language: language
            )
            let text = response.text
                .trimmingCharacters(in: .whitespacesAndNewlines)
            deliver(text: text, isFinal: isFinal)
        } catch {
            logger.error("OpenRouter transcription failed: \(error.localizedDescription, privacy: .public)")
            if isFinal { deliver(error: error) }
        }
    }

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
        guard status != .error,
              let channel = output.floatChannelData else { return }
        let count = Int(output.frameLength)
        guard count > 0 else { return }
        store.append(
            Array(UnsafeBufferPointer(start: channel[0], count: count))
        )
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

    private func deliver(text: String, isFinal: Bool) {
        onPartial?(text, isFinal, [])
    }

    private func deliver(error: Error) {
        onError?(error)
    }
}

private final class OpenRouterSpeechStore: @unchecked Sendable {
    private let lock = NSLock()
    private var sampleBuffer: [Float] = []
    private var stopped = false
    private var transcribing = false

    func reset() {
        lock.withLock {
            sampleBuffer.removeAll(keepingCapacity: true)
            stopped = false
            transcribing = false
        }
    }

    func setStopped() {
        lock.withLock { stopped = true }
    }

    var isStopped: Bool {
        lock.withLock { stopped }
    }

    func append(_ samples: [Float]) {
        lock.withLock { sampleBuffer.append(contentsOf: samples) }
    }

    func clearSamples() {
        lock.withLock { sampleBuffer.removeAll(keepingCapacity: false) }
    }

    func snapshotSamples() -> [Float] {
        lock.withLock { sampleBuffer }
    }

    func claimTranscription() -> Bool {
        lock.withLock {
            if transcribing { return false }
            transcribing = true
            return true
        }
    }

    func releaseTranscription() {
        lock.withLock { transcribing = false }
    }
}
