import Foundation

public enum MenuLayout {
    public static let width: CGFloat = 300
    public static let headerHeight: CGFloat = 58
    public static let modeRowHeight: CGFloat = 55
    public static let footerHeight: CGFloat = 38
    public static let horizontalPadding: CGFloat = 16
}

public enum FloatingBarLayout {
    public static let width: CGFloat = 196
    public static let height: CGFloat = 46
    public static let buttonDiameter: CGFloat = 34
    public static let barCount = 13
}

public enum WaveformDynamics {
    public static func heights(
        level: Float,
        phase: Double
    ) -> [CGFloat] {
        let normalized = CGFloat(min(max(level, 0), 1))
        guard normalized >= 0.035 else {
            return Array(repeating: 4, count: FloatingBarLayout.barCount)
        }

        let amplitude = 5 + normalized * 19
        let center = CGFloat(FloatingBarLayout.barCount - 1) / 2

        return (0..<FloatingBarLayout.barCount).map { index in
            let distance = abs(CGFloat(index) - center) / center
            let envelope = 0.42 + (1 - distance) * 0.58
            let oscillation = 0.68 + 0.32 * abs(
                sin(phase * 3.2 + Double(index) * 0.82)
            )
            return max(4, amplitude * envelope * CGFloat(oscillation))
        }
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

public struct KeyboardShortcut: Codable, Equatable, Sendable {
    public var keyCode: UInt16
    public var modifiers: ShortcutModifiers

    public init(keyCode: UInt16, modifiers: ShortcutModifiers) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    public var validationError: String? {
        modifiers.isEmpty ? "快捷键必须包含修饰键" : nil
    }

    public var displayString: String {
        var value = ""
        if modifiers.contains(.control) { value += "⌃" }
        if modifiers.contains(.option) { value += "⌥" }
        if modifiers.contains(.command) { value += "⌘" }
        if modifiers.contains(.shift) { value += "⇧" }
        value += Self.keyNames[keyCode] ?? "Key \(keyCode)"
        return value
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
        return dictation == english ? "两个功能不能使用相同快捷键" : nil
    }

    public func mode(matching shortcut: KeyboardShortcut) -> VoiceMode? {
        if shortcut == dictation { return .dictation }
        if shortcut == english { return .english }
        return nil
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
    case failed(String)
}

public enum SessionEvent: Equatable, Sendable {
    case start(VoiceMode)
    case finish
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
        case (.ready, .start(let mode)):
            state = .listening(mode)
        case (.listening(let mode), .start(let nextMode)) where mode != nextMode:
            pendingMode = nextMode
            state = .finalizing(mode)
        case (.listening(let mode), .finish):
            state = .finalizing(mode)
        case (.finalizing, .completed):
            if let pendingMode {
                self.pendingMode = nil
                state = .listening(pendingMode)
            } else {
                state = .ready
            }
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
