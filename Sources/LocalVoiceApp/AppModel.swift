import AppKit
import Combine
import LocalVoiceCore
import NaturalLanguage
@preconcurrency import Translation

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var state: SessionState = .ready
    @Published private(set) var transcript = ""
    @Published private(set) var unstableTranscript = ""
    @Published private(set) var audioLevel: Float = 0
    @Published private(set) var statusMessage = "已就绪"
    @Published private(set) var permissionSummary = "等待权限"
    @Published var recordingShortcut: VoiceMode?
    @Published var dictationShortcut: KeyboardShortcut
    @Published var englishShortcut: KeyboardShortcut

    let microphoneName: String

    private var stateMachine = SessionStateMachine()
    private var projection = RealtimeTextProjection()
    private let speechService = SpeechRecognitionService()
    private let hotkeyController = HotkeyController()
    private let insertionService = TextInsertionService()
    private let panelController = FloatingPanelController()
    private var translator: TranslationSession?
    private var latestRawTranscript = ""
    private var translationBuffer = LatestTextBuffer<TranslationInput>()
    private var pendingTranslationTask: Task<Void, Never>?
    private var pendingFinalizationTask: Task<Void, Never>?

    init() {
        dictationShortcut = Self.loadShortcut(
            key: "dictationShortcut",
            fallback: KeyboardShortcut(keyCode: 2, modifiers: [.command, .shift])
        )
        englishShortcut = Self.loadShortcut(
            key: "englishShortcut",
            fallback: KeyboardShortcut(keyCode: 14, modifiers: [.command, .shift])
        )
        microphoneName = SpeechRecognitionService.defaultInputName
        permissionSummary = PermissionCoordinator.summary
    }

    var menuBarSymbol: String {
        switch state {
        case .ready:
            return "waveform"
        case .listening(.dictation):
            return "waveform.circle.fill"
        case .listening(.english):
            return "translate"
        case .finalizing:
            return "ellipsis.circle"
        case .failed:
            return "exclamationmark.triangle"
        }
    }

    var isListening: Bool {
        if case .listening = state { return true }
        return false
    }

    func start() {
        hotkeyController.onShortcut = { [weak self] shortcut in
            guard let self else { return false }
            return MainActor.assumeIsolated {
                self.handleShortcut(shortcut)
            }
        }
        if PermissionCoordinator.accessibilityGranted {
            hotkeyController.start()
        }
        panelController.bind(to: self)
    }

    func shutdown() {
        pendingTranslationTask?.cancel()
        translationBuffer.reset()
        pendingFinalizationTask?.cancel()
        speechService.stop()
        hotkeyController.stop()
        panelController.hide()
    }

    func toggle(_ mode: VoiceMode) {
        switch state {
        case .ready, .failed:
            begin(mode)
        case .listening(let activeMode) where activeMode == mode:
            finish()
        case .listening(let activeMode):
            state = stateMachine.handle(.start(mode))
            stopAndAwaitFinal(mode: activeMode)
        case .finalizing:
            break
        }
    }

    func cancel() {
        pendingTranslationTask?.cancel()
        translationBuffer.reset()
        pendingFinalizationTask?.cancel()
        speechService.cancel()
        projection.reset()
        latestRawTranscript = ""
        transcript = ""
        unstableTranscript = ""
        state = stateMachine.handle(.cancel)
        statusMessage = "已取消"
        panelController.hide()
    }

    func finish() {
        guard case .listening(let mode) = state else { return }
        state = stateMachine.handle(.finish)
        stopAndAwaitFinal(mode: mode)
    }

    private func stopAndAwaitFinal(mode: VoiceMode) {
        statusMessage = "正在完成"
        speechService.stop()
        pendingFinalizationTask?.cancel()
        pendingFinalizationTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(700))
            guard !Task.isCancelled else { return }
            self?.finalize(mode: mode)
        }
    }

    func beginRecordingShortcut(_ mode: VoiceMode) {
        recordingShortcut = mode
        statusMessage = "请按下新的快捷键"
    }

    func requestPermissions() {
        Task {
            _ = await PermissionCoordinator.requestAll()
            permissionSummary = PermissionCoordinator.summary
            hotkeyController.start()
        }
    }

    func openSystemSettings() {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        ) else { return }
        NSWorkspace.shared.open(url)
    }

    private func begin(_ mode: VoiceMode) {
        Task {
            pendingTranslationTask?.cancel()
            pendingTranslationTask = nil
            translationBuffer.reset()
            let granted = await PermissionCoordinator.requestAll()
            permissionSummary = PermissionCoordinator.summary
            hotkeyController.start()
            guard granted else {
                fail("需要麦克风、语音识别和辅助功能权限")
                return
            }

            state = stateMachine.handle(.start(mode))
            statusMessage = mode == .dictation ? "正在听写" : "正在转为英文"
            transcript = ""
            unstableTranscript = ""
            latestRawTranscript = ""
            projection.reset()
            insertionService.captureTarget()
            panelController.show(mode: mode)

            do {
                try speechService.start(
                    onPartial: { [weak self] text, isFinal in
                        Task { @MainActor in
                            self?.receive(text, isFinal: isFinal, mode: mode)
                        }
                    },
                    onLevel: { [weak self] level in
                        Task { @MainActor in
                            self?.audioLevel = level
                        }
                    },
                    onError: { [weak self] error in
                        Task { @MainActor in
                            self?.fail(error.localizedDescription)
                        }
                    }
                )
            } catch {
                fail(error.localizedDescription)
            }
        }
    }

    private func receive(_ text: String, isFinal: Bool, mode: VoiceMode) {
        latestRawTranscript = text
        if mode == .english {
            translatePartial(text, isFinal: isFinal)
            return
        }

        processRecognized(
            text,
            isFinal: isFinal,
            language: correctionLanguage(for: text)
        )
    }

    private func translatePartial(_ text: String, isFinal: Bool) {
        translationBuffer.submit(
            TranslationInput(text: text, isFinal: isFinal)
        )
        guard pendingTranslationTask == nil else { return }

        pendingTranslationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { pendingTranslationTask = nil }

            while let input = translationBuffer.takeLatest() {
                do {
                    let translator = self.translator
                        ?? TranslationSession(
                            installedSource: Locale.Language(
                                identifier: "zh-Hans"
                            ),
                            target: Locale.Language(identifier: "en")
                        )
                    self.translator = translator
                    let response = try await translator.translate(input.text)
                    guard !Task.isCancelled else { return }
                    processRecognized(
                        response.targetText,
                        isFinal: input.isFinal,
                        language: .english
                    )
                } catch {
                    if input.isFinal {
                        fail("英文翻译不可用：请在系统设置中下载中文与英语")
                    } else {
                        unstableTranscript = input.text
                    }
                }
            }
        }
    }

    private func processRecognized(
        _ text: String,
        isFinal: Bool,
        language: CorrectionLanguage
    ) {
        let corrected = TextCorrector.correct(text, language: language)
        transcript = isFinal ? projection.update(corrected) : ""
        unstableTranscript = isFinal ? "" : projection.update(corrected)
        insertionService.update(corrected, isFinal: isFinal)
        if isFinal {
            pendingFinalizationTask?.cancel()
            completeSession()
        }
    }

    private func finalize(mode: VoiceMode) {
        guard !latestRawTranscript.isEmpty else {
            completeSession()
            return
        }

        if mode == .dictation {
            processRecognized(
                latestRawTranscript,
                isFinal: true,
                language: .chinese
            )
        } else {
            translatePartial(latestRawTranscript, isFinal: true)
        }
    }

    private func completeSession() {
        pendingFinalizationTask?.cancel()
        unstableTranscript = ""
        state = stateMachine.handle(.completed)
        statusMessage = "已完成"
        panelController.hide(after: 0.35)

        if case .listening(let pendingMode) = state {
            begin(pendingMode)
        }
    }

    private func fail(_ message: String) {
        speechService.cancel()
        state = stateMachine.handle(.fail(message))
        statusMessage = message
        panelController.showError()
    }

    private func handleShortcut(_ shortcut: KeyboardShortcut) -> Bool {
        if let mode = recordingShortcut {
            let other = mode == .dictation ? englishShortcut : dictationShortcut
            let candidate = mode == .dictation
                ? ShortcutPair(dictation: shortcut, english: other)
                : ShortcutPair(dictation: other, english: shortcut)

            guard shortcut.validationError == nil,
                  candidate.validationError == nil else {
                statusMessage = candidate.validationError
                    ?? shortcut.validationError
                    ?? "快捷键无效"
                return true
            }

            setShortcut(shortcut, for: mode)
            recordingShortcut = nil
            statusMessage = "快捷键已更新"
            return true
        }

        let pair = ShortcutPair(
            dictation: dictationShortcut,
            english: englishShortcut
        )
        guard let mode = pair.mode(matching: shortcut) else { return false }
        toggle(mode)
        return true
    }

    private func detectedSourceLanguage(for text: String) -> Locale.Language {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        if let language = recognizer.dominantLanguage {
            return Locale.Language(identifier: language.rawValue)
        }
        return Locale.current.language
    }

    private func correctionLanguage(for text: String) -> CorrectionLanguage {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        return recognizer.dominantLanguage == .english ? .english : .chinese
    }

    private func setShortcut(_ shortcut: KeyboardShortcut, for mode: VoiceMode) {
        switch mode {
        case .dictation:
            dictationShortcut = shortcut
            Self.saveShortcut(shortcut, key: "dictationShortcut")
        case .english:
            englishShortcut = shortcut
            Self.saveShortcut(shortcut, key: "englishShortcut")
        }
    }

    private static func loadShortcut(
        key: String,
        fallback: KeyboardShortcut
    ) -> KeyboardShortcut {
        guard let data = UserDefaults.standard.data(forKey: key),
              let shortcut = try? JSONDecoder().decode(
                  KeyboardShortcut.self,
                  from: data
              ) else {
            return fallback
        }
        return shortcut
    }

    private static func saveShortcut(_ shortcut: KeyboardShortcut, key: String) {
        guard let data = try? JSONEncoder().encode(shortcut) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}

private struct TranslationInput: Sendable {
    let text: String
    let isFinal: Bool
}
