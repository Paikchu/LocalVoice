import AppKit
import Combine
import LocalVoiceCore
import NaturalLanguage
import OSLog

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var state: SessionState = .ready
    @Published private(set) var transcript = ""
    @Published private(set) var unstableTranscript = ""
    @Published private(set) var audioLevel: Float = 0
    @Published private(set) var statusMessage = "已就绪"
    @Published private(set) var permissionSummary = "等待权限"
    @Published private(set) var isTranslatingSelectedText = false
    @Published private(set) var processingProgress: Double?
    @Published var recordingShortcut: VoiceMode?
    @Published var dictationShortcut: KeyboardShortcut
    @Published var englishShortcut: KeyboardShortcut
    @Published var signature: String {
        didSet {
            UserDefaults.standard.set(signature, forKey: "emailSignature")
        }
    }
    @Published var personalizationEnabled: Bool {
        didSet {
            UserDefaults.standard.set(
                personalizationEnabled,
                forKey: "personalizationEnabled"
            )
            Task {
                await profileStore.setEnabled(personalizationEnabled)
                if personalizationEnabled {
                    await profileStore.load()
                }
            }
        }
    }

    let microphoneName: String
    let modelManager: LocalModelManager

    private var stateMachine = SessionStateMachine()
    private var projection = RealtimeTextProjection()
    private var recognitionAccumulator = RecognitionTranscriptAccumulator()
    private var draft = DictationDraft()
    private let speechService = SpeechRecognitionService()
    private let hotkeyController = HotkeyController()
    private let insertionService = TextInsertionService()
    private let selectedTextService = SelectedTextService()
    private let panelController = FloatingPanelController()
    private let processingService: DraftProcessingService
    private var latestRawTranscript = ""
    private var latestSuspects: [SuspectSpan] = []
    private var peakAudioLevel: Float = 0
    private var receivedTranscript = false
    private var pendingFinalizationTask: Task<Void, Never>?
    private var pendingProcessingTask: Task<Void, Never>?
    private var pendingStartTask: Task<Void, Never>?
    private var recordingStartupGate = RecordingStartupGate()
    private var speechServiceStarted = false
    private let profileStore = UserProfileStore()
    private let logger = Logger(
        subsystem: "com.localvoice.app",
        category: "session"
    )

    init() {
        let languageModel = MLXLanguageModelService()
        modelManager = LocalModelManager(service: languageModel)
        processingService = DraftProcessingService(languageModel: languageModel)
        dictationShortcut = Self.loadShortcut(
            key: "dictationShortcut",
            fallback: Self.defaultDictationShortcut
        )
        englishShortcut = Self.loadShortcut(
            key: "englishShortcut",
            fallback: Self.defaultEnglishShortcut
        )
        signature = UserDefaults.standard.string(forKey: "emailSignature") ?? ""
        personalizationEnabled = UserDefaults.standard.bool(
            forKey: "personalizationEnabled"
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
        case .processing:
            return "sparkles"
        case .inserting:
            return "text.cursor"
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
        hotkeyController.isRecordingShortcut = { [weak self] in
            MainActor.assumeIsolated {
                self?.recordingShortcut != nil
            }
        }
        hotkeyController.setShortcuts(shortcutPair)
        hotkeyController.start()
        panelController.bind(to: self)
        _ = PermissionCoordinator.requestAccessibilityOnce()
        modelManager.preloadIfInstalled()
        Task {
            await profileStore.setEnabled(personalizationEnabled)
            await profileStore.load()
        }
    }

    func shutdown() {
        recordingStartupGate.cancel()
        speechServiceStarted = false
        pendingStartTask?.cancel()
        pendingFinalizationTask?.cancel()
        pendingProcessingTask?.cancel()
        insertionService.cancelPendingInsertion()
        speechService.stop()
        hotkeyController.stop()
        panelController.hide()
        modelManager.shutdown()
        Task { await profileStore.flushNow() }
    }

    func toggle(_ mode: VoiceMode) {
        switch state {
        case .ready, .failed:
            begin(mode)
        case .listening(let activeMode) where activeMode == mode:
            finish()
        case .listening(let activeMode):
            state = stateMachine.handle(.start(mode))
            requestFinalization(mode: activeMode)
        case .finalizing, .processing, .inserting:
            break
        }
    }

    func cancel() {
        recordingStartupGate.cancel()
        speechServiceStarted = false
        pendingStartTask?.cancel()
        pendingFinalizationTask?.cancel()
        pendingProcessingTask?.cancel()
        insertionService.cancelPendingInsertion()
        speechService.cancel()
        projection.reset()
        recognitionAccumulator.reset()
        draft.cancel()
        latestRawTranscript = ""
        latestSuspects = []
        isTranslatingSelectedText = false
        processingProgress = nil
        transcript = ""
        unstableTranscript = ""
        state = stateMachine.handle(.cancel)
        statusMessage = "已取消"
        panelController.hide()
    }

    func finish() {
        guard case .listening(let mode) = state else { return }
        state = stateMachine.handle(.finish)
        requestFinalization(mode: mode)
    }

    private func requestFinalization(mode: VoiceMode) {
        recordingStartupGate.requestFinish()
        guard speechServiceStarted else {
            statusMessage = "正在完成"
            processingProgress = ProcessingProgress.finalizing.fraction
            return
        }
        stopAndAwaitFinal(mode: mode)
    }

    private func stopAndAwaitFinal(mode: VoiceMode) {
        statusMessage = "正在完成"
        processingProgress = ProcessingProgress.finalizing.fraction
        speechServiceStarted = false
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
            _ = await PermissionCoordinator.requestRecording()
            _ = PermissionCoordinator.requestAccessibility()
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

    func clearAllLocalData() {
        pendingFinalizationTask?.cancel()
        pendingProcessingTask?.cancel()

        personalizationEnabled = false
        signature = ""
        dictationShortcut = Self.defaultDictationShortcut
        englishShortcut = Self.defaultEnglishShortcut
        hotkeyController.setShortcuts(shortcutPair)
        UserDefaults.standard.removePersistentDomain(
            forName: Bundle.main.bundleIdentifier ?? "com.localvoice.app"
        )

        Task {
            var failures: [String] = []
            do {
                try await modelManager.clearFiles()
            } catch {
                failures.append("模型：\(error.localizedDescription)")
            }
            do {
                try await profileStore.clear()
            } catch {
                failures.append("画像：\(error.localizedDescription)")
            }
            statusMessage = failures.isEmpty
                ? "本地数据已清除"
                : "清除失败：" + failures.joined(separator: "；")
        }
    }

    private func begin(_ mode: VoiceMode) {
        pendingStartTask?.cancel()
        let startup = recordingStartupGate.begin()
        speechServiceStarted = false
        isTranslatingSelectedText = false
        processingProgress = nil
        insertionService.captureTarget()
        state = stateMachine.handle(.start(mode))
        statusMessage = "正在准备"
        transcript = ""
        unstableTranscript = ""
        latestRawTranscript = ""
        peakAudioLevel = 0
        receivedTranscript = false
        projection.reset()
        recognitionAccumulator.reset()
        draft = DictationDraft()
        panelController.show(mode: mode)

        pendingStartTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let recordingGranted =
                await PermissionCoordinator.requestRecording()
            let insertionGranted = PermissionCoordinator.accessibilityGranted
            permissionSummary = PermissionCoordinator.summary
            hotkeyController.start()
            guard !Task.isCancelled else {
                return
            }
            let startupAction = recordingStartupGate.actionWhenReady(
                for: startup
            )
            guard startupAction != .discard else { return }
            guard recordingGranted else {
                fail("需要麦克风和语音识别权限")
                return
            }

            if insertionGranted {
                statusMessage = mode == .dictation
                    ? "正在听写"
                    : "正在转为英文"
            } else {
                statusMessage = "正在录音，未授权文本输入"
            }
            do {
                try speechService.start(
                    onPartial: { [weak self] text, isFinal, suspects in
                        Task { @MainActor in
                            self?.receive(text, isFinal: isFinal, mode: mode, suspects: suspects)
                        }
                    },
                    onLevel: { [weak self] level in
                        Task { @MainActor in
                            self?.audioLevel = level
                            self?.peakAudioLevel = max(
                                self?.peakAudioLevel ?? 0,
                                level
                            )
                        }
                    },
                    onError: { [weak self] error in
                        Task { @MainActor in
                            self?.fail(error.localizedDescription)
                        }
                    }
                )
                speechServiceStarted = true
                if startupAction == .startThenFinish {
                    stopAndAwaitFinal(mode: mode)
                }
            } catch {
                speechServiceStarted = false
                fail(error.localizedDescription)
            }
        }
    }

    private func receive(_ text: String, isFinal: Bool, mode: VoiceMode, suspects: [SuspectSpan] = []) {
        guard !text.isEmpty else { return }
        let accumulated = recognitionAccumulator.consume(
            text,
            isFinal: isFinal
        )
        latestRawTranscript = accumulated
        if isFinal { latestSuspects = suspects }
        draft.updateRaw(accumulated)
        receivedTranscript = true
        logger.info(
            "Received transcript final=\(isFinal) segmentCharacters=\(text.count) accumulatedCharacters=\(accumulated.count)"
        )

        processRecognized(
            accumulated,
            isFinal: isFinal,
            language: correctionLanguage(for: accumulated)
        )
    }

    private func processRecognized(
        _ text: String,
        isFinal: Bool,
        language: CorrectionLanguage
    ) {
        let corrected = TextCorrector.correct(text, language: language)
        let preview = projection.update(corrected)
        draft.updatePreview(preview)
        transcript = preview
        unstableTranscript = isFinal ? "" : preview
        if isFinal, case .finalizing = state {
            pendingFinalizationTask?.cancel()
            beginProcessing()
        }
    }

    private func finalize(mode: VoiceMode) {
        guard !latestRawTranscript.isEmpty else {
            let activity = SpeechCaptureActivity(
                peakLevel: peakAudioLevel,
                receivedTranscript: receivedTranscript
            )
            if let message = activity.failureMessage {
                logger.error(
                    "Capture failed peakLevel=\(self.peakAudioLevel) reason=\(message, privacy: .public)"
                )
                fail(message)
            } else {
                completeSession()
            }
            return
        }

        processRecognized(
            latestRawTranscript,
            isFinal: true,
            language: correctionLanguage(for: latestRawTranscript)
        )
    }

    private func completeSession(
        message: String = "已完成",
        hideAfter delay: TimeInterval = 0.35
    ) {
        pendingFinalizationTask?.cancel()
        pendingProcessingTask?.cancel()
        unstableTranscript = ""
        state = stateMachine.handle(.insertionCompleted)
        statusMessage = message
        isTranslatingSelectedText = false
        processingProgress = message == "已完成"
            ? ProcessingProgress.completed.fraction
            : nil
        panelController.hide(after: delay)

        if case .listening(let pendingMode) = state {
            begin(pendingMode)
        }
    }

    private func beginProcessing() {
        guard case .finalizing(let mode) = state,
              let finalTranscript = draft.finalize(latestRawTranscript) else {
            fail("没有可写入的识别结果")
            return
        }
        state = stateMachine.handle(.finalTranscriptReady)
        statusMessage = modelManager.isReady ? "正在本地整理" : "正在基础整理"
        processingProgress = ProcessingProgress.preparing.fraction
        unstableTranscript = ""

        pendingProcessingTask?.cancel()
        pendingProcessingTask = Task { @MainActor [weak self] in
            guard let self else { return }

            let hint = await profileStore.snapshot()
            let profileHintText = hint.promptBlock
            let glossaryTerms = await profileStore.snapshot().glossaryTerms
            // Build GlossaryTerm array from canonical names for normalizer
            let glossaryForNormalizer = glossaryTerms.map {
                GlossaryTerm(canonical: $0, occurrences: 1, sessionCount: 1)
            }

            let outcome = await processingService.process(
                transcript: finalTranscript,
                mode: mode,
                signature: signature,
                profileHint: profileHintText,
                glossary: glossaryForNormalizer,
                suspects: latestSuspects,
                onProgress: processingProgressHandler()
            )
            guard !Task.isCancelled else { return }

            let formatted = DocumentFormatter.format(outcome.result.outputText)
            transcript = formatted.plainText
            draft.updatePreview(formatted.plainText)
            _ = draft.confirm()
            state = stateMachine.handle(
                outcome.usedFallback
                    ? .processingFallback
                    : .processingSucceeded
            )
            statusMessage = outcome.usedFallback
                ? "模型不可用，已使用基础整理"
                : "正在写入"
            processingProgress = ProcessingProgress.inserting.fraction
            insertionService.insert(formatted) { [weak self] result in
                guard let self else { return }
                switch result {
                case .inserted, .copiedToClipboard:
                    let ingestInput = ProfileIngestInput(
                        finalText: formatted.plainText,
                        mode: mode,
                        wasEmail: outcome.result.intent == .composeEmail,
                        usedFallback: outcome.usedFallback
                    )
                    Task.detached(priority: .utility) { [profileStore] in
                        await profileStore.ingest(ingestInput)
                    }
                    if result == .inserted {
                        completeSession()
                    } else {
                        completeSession(
                            message: "光标不可用，内容已复制",
                            hideAfter: 1.4
                        )
                    }
                case .failed:
                    fail("无法写入目标文本框，请检查辅助功能权限")
                }
            }
        }
    }

    private func fail(_ message: String) {
        recordingStartupGate.cancel()
        speechServiceStarted = false
        pendingStartTask?.cancel()
        insertionService.cancelPendingInsertion()
        speechService.cancel()
        processingProgress = nil
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
        if mode == .english,
           canStartSelectedTextTranslation,
           let capture = selectedTextService.captureChineseSelection() {
            beginSelectedTextTranslation(capture)
            return true
        }
        toggle(mode)
        return true
    }

    private var canStartSelectedTextTranslation: Bool {
        switch state {
        case .ready, .failed:
            return true
        default:
            return false
        }
    }

    private func beginSelectedTextTranslation(
        _ capture: SelectedTextCapture
    ) {
        pendingFinalizationTask?.cancel()
        pendingProcessingTask?.cancel()
        insertionService.captureTarget(capture.request.target)
        isTranslatingSelectedText = true
        processingProgress = ProcessingProgress.preparing.fraction
        transcript = capture.request.sourceText
        unstableTranscript = ""
        state = stateMachine.handle(.translateSelection)
        statusMessage = "正在翻译选中文本"
        panelController.show(mode: .english)

        guard modelManager.isReady else {
            fail("本地模型尚未就绪，原文未修改")
            return
        }

        pendingProcessingTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let glossaryTerms = await profileStore.snapshot().glossaryTerms
            let glossary = glossaryTerms.map {
                GlossaryTerm(canonical: $0, occurrences: 1, sessionCount: 1)
            }
            let outcome = await processingService.process(
                transcript: capture.request.sourceText,
                mode: .english,
                signature: "",
                glossary: glossary,
                onProgress: processingProgressHandler()
            )
            guard !Task.isCancelled else { return }
            guard let replacement = SelectedTextTranslationValidator.replacement(
                output: outcome.result.outputText,
                usedFallback: outcome.usedFallback
            ) else {
                fail("翻译失败，原文未修改")
                return
            }

            let normalized = DocumentFormatter.format(replacement)
            let formatted = FormattedDocument(
                plainText: capture.request.replacementText(
                    for: normalized.plainText
                ),
                html: normalized.html
            )
            transcript = normalized.plainText
            state = stateMachine.handle(.processingSucceeded)
            statusMessage = "正在替换选中文本"
            processingProgress = ProcessingProgress.inserting.fraction
            insertionService.insert(
                formatted,
                requiring: capture
            ) { [weak self] result in
                guard let self else { return }
                switch result {
                case .inserted:
                    completeSession()
                case .copiedToClipboard:
                    completeSession(
                        message: "选区已变化，英文已复制",
                        hideAfter: 1.4
                    )
                case .failed:
                    fail("无法替换选区，英文复制失败")
                }
            }
        }
    }

    private func correctionLanguage(for text: String) -> CorrectionLanguage {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        return recognizer.dominantLanguage == .english ? .english : .chinese
    }

    private func processingProgressHandler()
        -> @Sendable (ProcessingProgress) -> Void {
        { [weak self] progress in
            Task { @MainActor in
                guard let self else { return }
                self.processingProgress = max(
                    self.processingProgress ?? 0,
                    progress.fraction
                )
            }
        }
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
        hotkeyController.setShortcuts(shortcutPair)
    }

    private var shortcutPair: ShortcutPair {
        ShortcutPair(
            dictation: dictationShortcut,
            english: englishShortcut
        )
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

    private static let defaultDictationShortcut = KeyboardShortcut(
        keyCode: 2,
        modifiers: [.command, .shift]
    )

    private static let defaultEnglishShortcut = KeyboardShortcut(
        keyCode: 14,
        modifiers: [.command, .shift]
    )
}
