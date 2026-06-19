import Foundation

public enum MenuLayout {
    public static let width: CGFloat = 200
    public static let nativeRowHeight: CGFloat = 34
    public static let footerHeight: CGFloat = 32
    public static let closedContentHeight: CGFloat = nativeRowHeight * 4 + footerHeight
    public static let horizontalPadding: CGFloat = 14
    public static let settingsSectionSpacing: CGFloat = 8
    public static let settingsSectionVerticalPadding: CGFloat = 8
}

public enum FloatingBarLayout {
    public static let width: CGFloat = 330
    public static let height: CGFloat = 184
    public static let contentWidth: CGFloat = 314
    public static let glowPadding: CGFloat = 8
    public static let controlsHeight: CGFloat = 38
    public static let capsuleWidth: CGFloat = 184
    public static let buttonDiameter: CGFloat = 28
    public static let barCount = 13

    public static let statusFontSize: CGFloat = 9
    public static let previewFontSize: CGFloat = 12.5
    public static let previewLineSpacing: CGFloat = 2
    public static let previewLineHeight: CGFloat = 17
    public static let previewMinLines = 2
    public static let previewMaxLines = 5
    public static let previewCharactersPerPage = 72
    public static let previewPagerReserveWidth: CGFloat = 64
    public static let previewHorizontalPadding: CGFloat = 14
    public static let previewVerticalPadding: CGFloat = 10
    public static let statusTextHeight: CGFloat = 12
    public static let statusSpacing: CGFloat = 3
    public static let cornerRadius: CGFloat = 14

    public static var previewTextWidth: CGFloat {
        contentWidth - previewHorizontalPadding * 2
    }

    public static func textAreaHeight(forLines lines: Int) -> CGFloat {
        CGFloat(lines) * previewLineHeight
    }

    /// Clamp a measured text height into the allowed 2…5 line range.
    public static func clampedTextAreaHeight(_ measured: CGFloat) -> CGFloat {
        let minHeight = textAreaHeight(forLines: previewMinLines)
        let maxHeight = textAreaHeight(forLines: previewMaxLines)
        return min(max(measured, minHeight), maxHeight)
    }
}

public enum PreviewPagination {
    public static func pages(
        for text: String,
        charactersPerPage: Int = FloatingBarLayout.previewCharactersPerPage
    ) -> [String] {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return [""]
        }

        let limit = max(charactersPerPage, 1)
        var pages: [String] = []
        var current = ""

        for character in text {
            current.append(character)
            if current.count >= limit {
                pages.append(current)
                current = ""
            }
        }

        if !current.isEmpty {
            pages.append(current)
        }
        return pages
    }

    public static func pageIndexAfterTextChange(
        currentIndex: Int,
        previousPageCount: Int,
        newPageCount: Int
    ) -> Int {
        guard newPageCount > 0 else { return 0 }
        let previousLastIndex = max(previousPageCount - 1, 0)
        if currentIndex >= previousLastIndex {
            return newPageCount - 1
        }
        return min(max(currentIndex, 0), newPageCount - 1)
    }
}

public struct ProcessingProgress: Equatable, Sendable {
    public let fraction: Double

    public static let finalizing = Self(fraction: 0.06)
    public static let preparing = Self(fraction: 0.14)
    public static let validating = Self(fraction: 0.92)
    public static let inserting = Self(fraction: 0.97)
    public static let completed = Self(fraction: 1)

    public static func generating(
        outputCharacters: Int,
        estimatedCharacters: Int,
        attempt: Int
    ) -> Self {
        let normalized = min(
            max(Double(outputCharacters) / Double(max(estimatedCharacters, 1)), 0),
            1
        )
        let base = attempt > 1 ? 0.82 : 0.18
        let span = attempt > 1 ? 0.06 : 0.64
        return Self(fraction: base + normalized * span)
    }

    public init(fraction: Double) {
        self.fraction = min(max(fraction, 0), 1)
    }
}

public enum RecordingStartupAction: Equatable, Sendable {
    case startListening
    case startThenFinish
    case discard
}

public struct RecordingStartupGate: Sendable {
    private var generation = 0
    private var activeGeneration: Int?
    private var finishRequested = false

    public init() {}

    public mutating func begin() -> Int {
        generation += 1
        activeGeneration = generation
        finishRequested = false
        return generation
    }

    public mutating func requestFinish() {
        guard activeGeneration != nil else { return }
        finishRequested = true
    }

    public mutating func cancel() {
        generation += 1
        activeGeneration = nil
        finishRequested = false
    }

    public mutating func actionWhenReady(
        for startup: Int
    ) -> RecordingStartupAction {
        guard activeGeneration == startup else { return .discard }
        activeGeneration = nil
        return finishRequested ? .startThenFinish : .startListening
    }
}

public final class RecognitionSessionGate: @unchecked Sendable {
    private let lock = NSLock()
    private var currentSession = 0
    private var stoppingSession: Int?

    public init() {}

    public func begin() -> Int {
        lock.withLock {
            currentSession += 1
            stoppingSession = nil
            return currentSession
        }
    }

    public func stop(_ session: Int) {
        lock.withLock {
            guard session == currentSession else { return }
            stoppingSession = session
        }
    }

    public func stopCurrent() {
        lock.withLock {
            stoppingSession = currentSession
        }
    }

    public func cancelCurrent() {
        lock.withLock {
            currentSession += 1
            stoppingSession = nil
        }
    }

    public func shouldDeliverResult(for session: Int) -> Bool {
        lock.withLock {
            session == currentSession
        }
    }

    public func shouldDeliverError(for session: Int) -> Bool {
        lock.withLock {
            session == currentSession && stoppingSession != session
        }
    }
}

/// Geometry for the Siri-style glowing waveform: several lines that stay
/// nearly flat when idle and weave up and down — interleaving because each
/// line carries its own frequency, speed and phase — as the voice level rises.
public enum WaveformDynamics {
    public struct LineParameters: Sendable, Equatable {
        public let frequency: Double
        public let speed: Double
        public let phase: Double
        public let amplitude: Double
        public let width: Double

        public init(
            frequency: Double,
            speed: Double,
            phase: Double,
            amplitude: Double,
            width: Double
        ) {
            self.frequency = frequency
            self.speed = speed
            self.phase = phase
            self.amplitude = amplitude
            self.width = width
        }
    }

    public static let lines: [LineParameters] = [
        LineParameters(frequency: 1.1, speed: 1.6, phase: 0.0, amplitude: 1.00, width: 2.0),
        LineParameters(frequency: 1.7, speed: -2.1, phase: 1.8, amplitude: 0.78, width: 1.6),
        LineParameters(frequency: 2.3, speed: 2.7, phase: 3.4, amplitude: 0.58, width: 1.4),
        LineParameters(frequency: 0.7, speed: -1.2, phase: 5.0, amplitude: 0.42, width: 1.3)
    ]

    /// Small idle shimmer so the line reads as alive while staying near-flat.
    public static let idleAmplitude: CGFloat = 1.0

    /// Peak vertical swing the lines reach for the current voice level.
    public static func activeAmplitude(level: Float, height: CGFloat) -> CGFloat {
        let clamped = CGFloat(min(max(level, 0), 1))
        return clamped * height * 0.40
    }

    /// Vertical offset (relative to the vertical center) of one line at the
    /// normalized horizontal position `p` in 0...1. A `sin` envelope pulls the
    /// lines back to the center line at both ends, like a voice waveform.
    public static func lineOffset(
        lineIndex: Int,
        p: Double,
        time: Double,
        level: Float,
        height: CGFloat
    ) -> CGFloat {
        let line = lines[lineIndex]
        let envelope = sin(Double.pi * p)
        let wobble = sin(
            p * Double.pi * 2 * line.frequency + time * line.speed + line.phase
        )
        let harmonic = 0.4 * sin(
            p * Double.pi * 3.1 * line.frequency - time * line.speed * 0.7 + line.phase
        )
        let idle = Double(idleAmplitude)
            * sin(p * 9 + time * 1.2 + Double(lineIndex))
            * envelope
        let active = Double(activeAmplitude(level: level, height: height))
        let wave = (wobble + harmonic) * envelope * active * line.amplitude
        return CGFloat(idle + wave)
    }
}

public enum VoiceMode: String, Codable, Equatable, Sendable {
    case dictation
    case english
}

public struct ShortcutModifiers: OptionSet, Codable, Equatable, Sendable {
    public let rawValue: UInt

    public init(rawValue: UInt) {
        self.rawValue = rawValue
    }

    public static let command = Self(rawValue: 1 << 0)
    public static let shift = Self(rawValue: 1 << 1)
    public static let option = Self(rawValue: 1 << 2)
    public static let control = Self(rawValue: 1 << 3)
}

public struct ShortcutModifierSides: OptionSet, Codable, Equatable, Sendable {
    public let rawValue: UInt

    public init(rawValue: UInt) {
        self.rawValue = rawValue
    }

    public static let leftCommand = Self(rawValue: 1 << 0)
    public static let rightCommand = Self(rawValue: 1 << 1)
    public static let leftShift = Self(rawValue: 1 << 2)
    public static let rightShift = Self(rawValue: 1 << 3)
    public static let leftOption = Self(rawValue: 1 << 4)
    public static let rightOption = Self(rawValue: 1 << 5)
    public static let leftControl = Self(rawValue: 1 << 6)
    public static let rightControl = Self(rawValue: 1 << 7)
}

public struct KeyboardShortcut: Codable, Equatable, Sendable {
    public var keyCode: UInt16
    public var modifiers: ShortcutModifiers
    public var modifierSides: ShortcutModifierSides

    private enum CodingKeys: String, CodingKey {
        case keyCode
        case modifiers
        case modifierSides
    }

    public init(
        keyCode: UInt16,
        modifiers: ShortcutModifiers,
        modifierSides: ShortcutModifierSides = []
    ) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.modifierSides = modifierSides.intersection(
            Self.sidesMask(for: modifiers)
        )
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let keyCode = try container.decode(UInt16.self, forKey: .keyCode)
        let modifiers = try container.decode(
            ShortcutModifiers.self,
            forKey: .modifiers
        )
        let modifierSides = try container.decodeIfPresent(
            ShortcutModifierSides.self,
            forKey: .modifierSides
        ) ?? []
        self.init(
            keyCode: keyCode,
            modifiers: modifiers,
            modifierSides: modifierSides
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(keyCode, forKey: .keyCode)
        try container.encode(modifiers, forKey: .modifiers)
        try container.encode(modifierSides, forKey: .modifierSides)
    }

    public var validationError: String? {
        modifiers.isEmpty ? "快捷键必须包含修饰键" : nil
    }

    public func matches(_ event: KeyboardShortcut) -> Bool {
        guard keyCode == event.keyCode,
              modifiers == event.modifiers else {
            return false
        }
        guard !modifierSides.isEmpty else { return true }
        return modifierSides == event.modifierSides
    }

    public func conflicts(with other: KeyboardShortcut) -> Bool {
        matches(other) || other.matches(self)
    }

    public var displayString: String {
        var value = ""
        value += displayModifier(
            .control,
            left: .leftControl,
            right: .rightControl,
            symbol: "⌃"
        )
        value += displayModifier(
            .option,
            left: .leftOption,
            right: .rightOption,
            symbol: "⌥"
        )
        value += displayModifier(
            .command,
            left: .leftCommand,
            right: .rightCommand,
            symbol: "⌘"
        )
        value += displayModifier(
            .shift,
            left: .leftShift,
            right: .rightShift,
            symbol: "⇧"
        )
        value += Self.keyNames[keyCode] ?? "Key \(keyCode)"
        return value
    }

    private func displayModifier(
        _ modifier: ShortcutModifiers,
        left: ShortcutModifierSides,
        right: ShortcutModifierSides,
        symbol: String
    ) -> String {
        guard modifiers.contains(modifier) else { return "" }
        let sides = modifierSides.intersection([left, right])
        if sides == left { return "左\(symbol)" }
        if sides == right { return "右\(symbol)" }
        return symbol
    }

    private static func sidesMask(
        for modifiers: ShortcutModifiers
    ) -> ShortcutModifierSides {
        var mask: ShortcutModifierSides = []
        if modifiers.contains(.command) {
            mask.insert([.leftCommand, .rightCommand])
        }
        if modifiers.contains(.shift) {
            mask.insert([.leftShift, .rightShift])
        }
        if modifiers.contains(.option) {
            mask.insert([.leftOption, .rightOption])
        }
        if modifiers.contains(.control) {
            mask.insert([.leftControl, .rightControl])
        }
        return mask
    }

    private static let keyNames: [UInt16: String] = [
        0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z",
        7: "X", 8: "C", 9: "V", 11: "B", 12: "Q", 13: "W",
        14: "E", 15: "R", 16: "Y", 17: "T", 31: "O", 32: "U",
        34: "I", 35: "P", 37: "L", 38: "J", 40: "K", 45: "N",
        46: "M", 49: "Space"
    ]
}

public struct ShortcutPair: Equatable, Sendable {
    public var dictation: KeyboardShortcut
    public var english: KeyboardShortcut

    public init(dictation: KeyboardShortcut, english: KeyboardShortcut) {
        self.dictation = dictation
        self.english = english
    }

    public var validationError: String? {
        if let error = dictation.validationError ?? english.validationError {
            return error
        }
        return dictation.conflicts(with: english)
            ? "两个功能不能使用相同快捷键"
            : nil
    }

    public func mode(matching shortcut: KeyboardShortcut) -> VoiceMode? {
        if dictation.matches(shortcut) { return .dictation }
        if english.matches(shortcut) { return .english }
        return nil
    }

    public func shortcut(for mode: VoiceMode) -> KeyboardShortcut {
        switch mode {
        case .dictation:
            return dictation
        case .english:
            return english
        }
    }
}

public enum DictationActivationSoundOption: String, Codable, CaseIterable, Sendable {
    case glass
    case ping
    case tink
    case pop

    public var displayName: String {
        switch self {
        case .glass:
            return "清脆"
        case .ping:
            return "明亮"
        case .tink:
            return "轻点"
        case .pop:
            return "柔和"
        }
    }

    public var systemSoundName: String {
        switch self {
        case .glass:
            return "Glass"
        case .ping:
            return "Ping"
        case .tink:
            return "Tink"
        case .pop:
            return "Pop"
        }
    }
}

public struct DictationActivationSoundSettings: Codable, Equatable, Sendable {
    public var isEnabled: Bool
    public var option: DictationActivationSoundOption

    public init(
        isEnabled: Bool = true,
        option: DictationActivationSoundOption = .glass
    ) {
        self.isEnabled = isEnabled
        self.option = option
    }

    public var soundName: String {
        option.systemSoundName
    }
}

public enum DictationActivationSoundPolicy {
    public static let soundName = DictationActivationSoundOption.glass.systemSoundName

    public static func shouldPlay(
        currentState: SessionState,
        shortcutMode _: VoiceMode,
        settings: DictationActivationSoundSettings = .init()
    ) -> Bool {
        guard settings.isEnabled else { return false }
        switch currentState {
        case .ready, .failed, .listening:
            return true
        case .finalizing, .processing, .inserting:
            return false
        }
    }
}

public struct VoicePermissionState: Equatable, Sendable {
    public let microphoneGranted: Bool
    public let speechRecognitionGranted: Bool
    public let accessibilityGranted: Bool

    public init(
        microphoneGranted: Bool,
        speechRecognitionGranted: Bool,
        accessibilityGranted: Bool
    ) {
        self.microphoneGranted = microphoneGranted
        self.speechRecognitionGranted = speechRecognitionGranted
        self.accessibilityGranted = accessibilityGranted
    }

    public var canRecord: Bool {
        microphoneGranted && speechRecognitionGranted
    }

    public var canInsertText: Bool {
        accessibilityGranted
    }
}

public enum DictationStartStep: Equatable, Sendable {
    case targetCapture
    case permissionRequest
}

public struct DictationStartSequence: Equatable, Sendable {
    private var steps: [DictationStartStep] = []

    public init() {}

    public mutating func record(_ step: DictationStartStep) {
        steps.append(step)
    }

    public var validationError: String? {
        guard let targetIndex = steps.firstIndex(of: .targetCapture),
              let permissionIndex = steps.firstIndex(of: .permissionRequest),
              targetIndex < permissionIndex else {
            return "必须在请求权限前捕获文本输入目标"
        }
        return nil
    }
}

public struct InsertionTarget: Equatable, Sendable {
    public let applicationPID: Int32

    public init(applicationPID: Int32) {
        self.applicationPID = applicationPID
    }

    public func requiresActivation(
        currentApplicationPID: Int32?
    ) -> Bool {
        currentApplicationPID != applicationPID
    }
}

public enum AccessibilityPromptPolicy {
    public static func shouldPrompt(isTrusted: Bool) -> Bool {
        !isTrusted
    }
}

public enum TextInsertionRoute: Equatable, Sendable {
    case pasteboard
}

public enum TextInsertionDestination: Equatable, Sendable {
    case target
    case clipboard
}

public enum TextInsertionPolicy {
    public static func destination(
        accessibilityGranted: Bool,
        requiresCurrentSelection: Bool,
        selectionIsCurrent: Bool,
        cursorIsAvailable: Bool
    ) -> TextInsertionDestination {
        guard accessibilityGranted else { return .clipboard }
        if requiresCurrentSelection {
            return selectionIsCurrent ? .target : .clipboard
        }
        return cursorIsAvailable ? .target : .clipboard
    }
}

public struct ConfirmedInsertionRequest: Equatable, Sendable {
    public let text: String
    public let target: InsertionTarget

    public init(text: String, target: InsertionTarget) {
        self.text = text
        self.target = target
    }

    public var route: TextInsertionRoute {
        .pasteboard
    }

    public func canAttemptInsertion(accessibilityGranted: Bool) -> Bool {
        accessibilityGranted
    }

    public func requiresActivation(
        currentApplicationPID: Int32?
    ) -> Bool {
        target.requiresActivation(
            currentApplicationPID: currentApplicationPID
        )
    }
}

public struct SelectedTextTranslationRequest: Equatable, Sendable {
    public let sourceText: String
    public let target: InsertionTarget
    private let selectedText: String
    private let leadingWhitespace: String
    private let trailingWhitespace: String

    public init?(selectedText: String, target: InsertionTarget) {
        let sourceText = selectedText.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !sourceText.isEmpty,
              sourceText.range(
                of: #"\p{Han}"#,
                options: .regularExpression
              ) != nil else {
            return nil
        }
        self.sourceText = sourceText
        self.target = target
        self.selectedText = selectedText
        self.leadingWhitespace = String(
            selectedText.prefix(while: \.isWhitespace)
        )
        self.trailingWhitespace = String(
            selectedText.reversed().prefix(while: \.isWhitespace).reversed()
        )
    }

    public func matchesCurrentSelection(_ text: String?) -> Bool {
        text == selectedText
    }

    public func replacementText(for translation: String) -> String {
        leadingWhitespace + translation + trailingWhitespace
    }

    public func canReplace(
        currentApplicationPID: Int32?,
        currentSelectedText: String?
    ) -> Bool {
        currentApplicationPID == target.applicationPID
            && matchesCurrentSelection(currentSelectedText)
    }
}

public enum SelectedTextTranslationValidator {
    public static func replacement(
        output: String,
        usedFallback: Bool
    ) -> String? {
        let replacement = output.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !usedFallback,
              !replacement.isEmpty,
              replacement.range(
                of: #"\p{Han}"#,
                options: .regularExpression
              ) == nil else {
            return nil
        }
        return replacement
    }
}

public struct DictationDraft: Equatable, Sendable {
    public private(set) var rawTranscript = ""
    public private(set) var previewText = ""
    public private(set) var finalTranscript: String?
    public private(set) var isConfirmed = false

    public init() {}

    public mutating func updateRaw(_ text: String) {
        guard !isConfirmed else { return }
        rawTranscript = text
    }

    public mutating func updatePreview(_ text: String) {
        guard !isConfirmed else { return }
        previewText = text
    }

    @discardableResult
    public mutating func finalize(_ text: String? = nil) -> String? {
        guard !isConfirmed else { return finalTranscript }
        let value = (text ?? previewText)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        finalTranscript = value
        previewText = value
        return value
    }

    public mutating func confirm() -> String? {
        guard !isConfirmed, !previewText.isEmpty else { return nil }
        isConfirmed = true
        return finalTranscript ?? previewText
    }

    public mutating func cancel() {
        rawTranscript = ""
        previewText = ""
        finalTranscript = nil
        isConfirmed = true
    }
}

public struct RecognitionTranscriptAccumulator: Sendable {
    private var committedText = ""
    private var currentHypothesis = ""

    public init() {}

    public mutating func consume(
        _ hypothesis: String,
        isFinal: Bool
    ) -> String {
        let value = hypothesis.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !value.isEmpty else { return transcript }

        if currentHypothesis.isEmpty {
            currentHypothesis = value
        } else if isRevision(of: currentHypothesis, candidate: value) {
            currentHypothesis = value
        } else {
            let overlap = suffixPrefixOverlap(
                currentHypothesis,
                value
            )
            committedText = joined(committedText, currentHypothesis)
            currentHypothesis = overlap >= 4
                ? String(value.dropFirst(overlap))
                : value
        }

        if isFinal {
            committedText = joined(committedText, currentHypothesis)
            currentHypothesis = ""
        }
        return transcript
    }

    public mutating func reset() {
        committedText = ""
        currentHypothesis = ""
    }

    public var transcript: String {
        joined(committedText, currentHypothesis)
    }

    private func isRevision(
        of current: String,
        candidate: String
    ) -> Bool {
        if current.hasPrefix(candidate) || candidate.hasPrefix(current) {
            return true
        }
        let commonPrefix = zip(current, candidate)
            .prefix { $0 == $1 }
            .count
        return commonPrefix >= 3
    }

    private func suffixPrefixOverlap(
        _ current: String,
        _ candidate: String
    ) -> Int {
        let maximum = min(current.count, candidate.count)
        guard maximum >= 4 else { return 0 }
        for length in stride(from: maximum, through: 4, by: -1) {
            if current.suffix(length) == candidate.prefix(length) {
                return length
            }
        }
        return 0
    }

    private func joined(_ prefix: String, _ suffix: String) -> String {
        guard !prefix.isEmpty else { return suffix }
        guard !suffix.isEmpty else { return prefix }
        let needsSpace = prefix.last?.isASCII == true
            && prefix.last?.isLetter == true
            && suffix.first?.isASCII == true
            && suffix.first?.isLetter == true
        return needsSpace ? "\(prefix) \(suffix)" : prefix + suffix
    }
}

public enum PermissionPromptPolicy: Equatable, Sendable {
    case dictationShortcut
    case explicitRequest

    public var promptsForAccessibility: Bool {
        self == .explicitRequest
    }
}

public struct AccessibilityPromptHistory: Equatable, Sendable {
    private var hasPrompted = false

    public init() {}

    public mutating func consumePrompt() -> Bool {
        guard !hasPrompted else { return false }
        hasPrompted = true
        return true
    }
}

public struct SpeechCaptureActivity: Equatable, Sendable {
    public let peakLevel: Float
    public let receivedTranscript: Bool

    public init(peakLevel: Float, receivedTranscript: Bool) {
        self.peakLevel = peakLevel
        self.receivedTranscript = receivedTranscript
    }

    public var failureMessage: String? {
        if receivedTranscript {
            return nil
        }
        return peakLevel < 0.03
            ? "未检测到麦克风声音"
            : "检测到声音，但未识别到文字"
    }
}

public struct StableTextUpdate: Equatable, Sendable {
    public let committed: String
    public let unstable: String

    public init(committed: String, unstable: String) {
        self.committed = committed
        self.unstable = unstable
    }
}

public struct RealtimeTextProjection: Sendable {
    public private(set) var currentText = ""

    public init() {}

    @discardableResult
    public mutating func update(_ text: String) -> String {
        currentText = text
        return currentText
    }

    public mutating func reset() {
        currentText = ""
    }
}

public struct LatestTextBuffer<Element: Sendable>: Sendable {
    private var latest: Element?

    public init() {}

    public mutating func submit(_ value: Element) {
        latest = value
    }

    public mutating func takeLatest() -> Element? {
        defer { latest = nil }
        return latest
    }

    public mutating func reset() {
        latest = nil
    }
}

public struct StableTextAssembler: Sendable {
    private let requiredMatches: Int
    private var previousHypothesis = ""
    private var committedText = ""

    public init(requiredMatches: Int = 2) {
        self.requiredMatches = max(2, requiredMatches)
    }

    public mutating func consume(_ hypothesis: String) -> StableTextUpdate {
        guard !previousHypothesis.isEmpty else {
            previousHypothesis = hypothesis
            return StableTextUpdate(committed: "", unstable: hypothesis)
        }

        let stablePrefix = longestCommonPrefix(previousHypothesis, hypothesis)
        let newCommitted = suffix(after: committedText, in: stablePrefix)
        if stablePrefix.count >= committedText.count {
            committedText = stablePrefix
        }
        previousHypothesis = hypothesis

        return StableTextUpdate(
            committed: newCommitted,
            unstable: suffix(after: committedText, in: hypothesis)
        )
    }

    public mutating func finalize(_ hypothesis: String) -> String {
        let remaining = suffix(after: committedText, in: hypothesis)
        committedText = hypothesis
        previousHypothesis = hypothesis
        return remaining
    }

    public mutating func reset() {
        previousHypothesis = ""
        committedText = ""
    }

    private func longestCommonPrefix(_ lhs: String, _ rhs: String) -> String {
        String(zip(lhs, rhs).prefix { $0 == $1 }.map(\.0))
    }

    private func suffix(after prefix: String, in value: String) -> String {
        guard value.hasPrefix(prefix) else { return value }
        return String(value.dropFirst(prefix.count))
    }
}

public enum CorrectionLanguage: Sendable {
    case chinese
    case english
}

public enum TextCorrector {
    public static func correct(
        _ input: String,
        language: CorrectionLanguage
    ) -> String {
        var value = input.trimmingCharacters(in: .whitespacesAndNewlines)

        switch language {
        case .chinese:
            value = value.replacingOccurrences(
                of: #"^(嗯|呃|啊)+(?:[，,、。.!！?？…\s]+)?"#,
                with: "",
                options: .regularExpression
            )
            value = removeLeadingFillers(
                value,
                pattern: #"^(嗯|呃|啊|怎么说|那个)(?:[，,、。.!！?？…\s]+)"#
            )
            value = value.replacingOccurrences(
                of: #"^那个(?=今天|明天|昨天|现在|接下来|然后|就是|其实|所以|但是|我们|我)"#,
                with: "",
                options: .regularExpression
            )
            value = removeAdjacentRepeatedTokens(value)
            value = value.replacingOccurrences(
                of: #"\s+"#,
                with: "",
                options: .regularExpression
            )
        case .english:
            value = removeLeadingFillers(
                value,
                pattern: #"(?i)^(um|uh|er|well|you know)(?:[,\s.]+)"#
            )
            value = value.replacingOccurrences(
                of: #"\s+([,.!?])"#,
                with: "$1",
                options: .regularExpression
            )
            if let first = value.first {
                value.replaceSubrange(
                    value.startIndex...value.startIndex,
                    with: String(first).uppercased()
                )
            }
        }

        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func removeLeadingFillers(
        _ input: String,
        pattern: String
    ) -> String {
        var value = input
        while let range = value.range(of: pattern, options: .regularExpression) {
            value.removeSubrange(range)
        }
        return value
    }

    private static func removeAdjacentRepeatedTokens(_ input: String) -> String {
        let tokens = input.split(separator: " ", omittingEmptySubsequences: true)
        guard tokens.count > 1 else { return input }

        var result: [Substring] = []
        for token in tokens where result.last != token {
            result.append(token)
        }
        return result.joined(separator: " ")
    }
}

public enum SessionState: Equatable, Sendable {
    case ready
    case listening(VoiceMode)
    case finalizing(VoiceMode)
    case processing(VoiceMode)
    case inserting(VoiceMode)
    case failed(String)
}

public enum SessionEvent: Equatable, Sendable {
    case start(VoiceMode)
    case translateSelection
    case finish
    case finalTranscriptReady
    case processingSucceeded
    case processingFallback
    case insertionCompleted
    case completed
    case fail(String)
    case cancel
}

public struct SessionStateMachine: Sendable {
    public private(set) var state: SessionState = .ready
    public private(set) var pendingMode: VoiceMode?

    public init() {}

    @discardableResult
    public mutating func handle(_ event: SessionEvent) -> SessionState {
        switch (state, event) {
        case (.ready, .start(let mode)), (.failed, .start(let mode)):
            pendingMode = nil
            state = .listening(mode)
        case (.ready, .translateSelection), (.failed, .translateSelection):
            pendingMode = nil
            state = .processing(.english)
        case (.listening(let mode), .start(let nextMode)) where mode != nextMode:
            pendingMode = nextMode
            state = .finalizing(mode)
        case (.listening(let mode), .finish):
            pendingMode = nil
            state = .finalizing(mode)
        case (.finalizing, .finish):
            pendingMode = nil
        case (.finalizing(let mode), .finalTranscriptReady):
            state = .processing(mode)
        case (.processing(let mode), .processingSucceeded),
             (.processing(let mode), .processingFallback):
            state = .inserting(mode)
        case (.inserting, .insertionCompleted):
            if let pendingMode {
                self.pendingMode = nil
                state = .listening(pendingMode)
            } else {
                state = .ready
            }
        case (.finalizing, .completed):
            if let pendingMode {
                self.pendingMode = nil
                state = .listening(pendingMode)
            } else {
                state = .ready
            }
        case (.processing, .completed), (.inserting, .completed):
            pendingMode = nil
            state = .ready
        case (_, .cancel):
            pendingMode = nil
            state = .ready
        case (_, .fail(let message)):
            pendingMode = nil
            state = .failed(message)
        case (.failed, .completed):
            state = .ready
        default:
            break
        }
        return state
    }
}
