import AVFoundation
import OSLog
import Speech

final class SpeechRecognitionService {
    typealias PartialHandler = @Sendable (String, Bool) -> Void
    typealias LevelHandler = @Sendable (Float) -> Void
    typealias ErrorHandler = @Sendable (Error) -> Void

    static var defaultInputName: String {
        AVCaptureDevice.default(for: .audio)?.localizedName ?? "系统默认麦克风"
    }

    static let recognitionLocale = Locale(identifier: "zh-CN")

    private let audioEngine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var smoothedLevel: Float = 0
    private var tapInstalled = false
    private let logger = Logger(
        subsystem: "com.localvoice.app",
        category: "speech"
    )

    func start(
        onPartial: @escaping PartialHandler,
        onLevel: @escaping LevelHandler,
        onError: @escaping ErrorHandler
    ) throws {
        stop()

        guard let recognizer = SFSpeechRecognizer(locale: Self.recognitionLocale),
              recognizer.isAvailable else {
            throw SpeechServiceError.recognizerUnavailable
        }
        guard recognizer.supportsOnDeviceRecognition else {
            throw SpeechServiceError.onDeviceRecognitionUnavailable
        }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = true
        request.taskHint = .dictation
        self.request = request

        task = recognizer.recognitionTask(with: request) {
            [weak self] result, error in
            if let result {
                let text = result.bestTranscription.formattedString
                self?.logger.info(
                    "Recognition result final=\(result.isFinal) characters=\(text.count)"
                )
                onPartial(text, result.isFinal)
            }
            if let error {
                self?.logger.error(
                    "Recognition error: \(error.localizedDescription, privacy: .public)"
                )
                onError(error)
            }
        }

        let input = audioEngine.inputNode
        let format = input.outputFormat(forBus: 0)
        logger.info(
            "Starting audio input sampleRate=\(format.sampleRate) channels=\(format.channelCount)"
        )
        input.installTap(
            onBus: 0,
            bufferSize: 1_024,
            format: format
        ) { [weak self] buffer, _ in
            request.append(buffer)
            let level = self?.level(from: buffer) ?? 0
            onLevel(level)
        }
        tapInstalled = true

        audioEngine.prepare()
        try audioEngine.start()
        logger.info("Audio engine started")
    }

    func stop() {
        if audioEngine.isRunning {
            audioEngine.stop()
        }
        removeTapIfNeeded()
        request?.endAudio()
    }

    func cancel() {
        if audioEngine.isRunning {
            audioEngine.stop()
        }
        removeTapIfNeeded()
        request?.endAudio()
        task?.cancel()
        task = nil
        request = nil
    }

    private func removeTapIfNeeded() {
        guard tapInstalled else { return }
        audioEngine.inputNode.removeTap(onBus: 0)
        tapInstalled = false
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
}

enum SpeechServiceError: LocalizedError {
    case recognizerUnavailable
    case onDeviceRecognitionUnavailable

    var errorDescription: String? {
        switch self {
        case .recognizerUnavailable:
            return "当前语言的语音识别不可用"
        case .onDeviceRecognitionUnavailable:
            return "当前语言尚未安装本地语音识别资源"
        }
    }
}
