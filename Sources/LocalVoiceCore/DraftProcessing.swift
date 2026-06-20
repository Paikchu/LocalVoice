import Foundation

public enum DraftIntent: String, Codable, Equatable, Sendable {
    case plainText
    case composeEmail
}

public struct EmailDraft: Codable, Equatable, Sendable {
    public let subject: String?
    public let recipient: String?
    public let body: String
    public let missingFields: [String]

    public init(
        subject: String?,
        recipient: String?,
        body: String,
        missingFields: [String]
    ) {
        self.subject = subject
        self.recipient = recipient
        self.body = body
        self.missingFields = missingFields
    }

    private enum CodingKeys: String, CodingKey {
        case subject
        case recipient
        case body
        case missingFields
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        subject = try values.decodeIfPresent(String.self, forKey: .subject)
        recipient = try values.decodeIfPresent(String.self, forKey: .recipient)
        body = try values.decodeIfPresent(String.self, forKey: .body) ?? ""
        missingFields = try values.decodeIfPresent(
            [String].self,
            forKey: .missingFields
        ) ?? []
    }
}

public struct ProcessingResult: Equatable, Sendable {
    public let intent: DraftIntent
    public let confidence: Double
    public let outputText: String
    public let email: EmailDraft?
    /// Near-sound corrections the model declared and the validator accepted.
    public let corrections: [TermCorrection]

    public init(
        intent: DraftIntent,
        confidence: Double,
        outputText: String,
        email: EmailDraft?,
        corrections: [TermCorrection] = []
    ) {
        self.intent = intent
        self.confidence = confidence
        self.outputText = outputText
        self.email = email
        self.corrections = corrections
    }

    public func downgradedToPlainText() -> Self {
        Self(
            intent: .plainText,
            confidence: confidence,
            outputText: outputText,
            email: nil,
            corrections: corrections
        )
    }
}

extension ProcessingResult: Codable {
    private enum CodingKeys: String, CodingKey {
        case intent, confidence, outputText, email, corrections
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        intent = try c.decode(DraftIntent.self, forKey: .intent)
        confidence = try c.decode(Double.self, forKey: .confidence)
        outputText = try c.decode(String.self, forKey: .outputText)
        email = try c.decodeIfPresent(EmailDraft.self, forKey: .email)
        corrections = try c.decodeIfPresent([TermCorrection].self, forKey: .corrections) ?? []
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(intent, forKey: .intent)
        try c.encode(confidence, forKey: .confidence)
        try c.encode(outputText, forKey: .outputText)
        try c.encodeIfPresent(email, forKey: .email)
        if !corrections.isEmpty {
            try c.encode(corrections, forKey: .corrections)
        }
    }
}

public enum IntentHintDetector {
    public static func detect(_ text: String) -> DraftIntent {
        let normalized = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        let negativePatterns = [
            "不用发邮件",
            "不要发邮件",
            "不需要发邮件",
            "别发邮件"
        ]
        if negativePatterns.contains(where: normalized.contains) {
            return .plainText
        }

        let commandPatterns = [
            #"^(请|麻烦|帮我|我要|我想|替我|给我)?[^。！？]{0,20}(发|写|回复|回)(一封|封)?邮件"#,
            #"^(请|麻烦|帮我|我要|我想|替我)?给[^。！？]{1,20}(发|写|回复|回)(一封|封)?邮件"#
        ]
        if commandPatterns.contains(where: {
            normalized.range(of: $0, options: .regularExpression) != nil
        }) {
            return .composeEmail
        }
        return .plainText
    }
}

public enum ProcessingValidationError: Error, Equatable, Sendable {
    case invalidJSON
    case emptyOutput
    case missingFact(String)
}

public enum ProcessingResultValidator {
    public static func validate(
        _ data: Data,
        requiredFacts: [String],
        emailConfidenceThreshold: Double = 0.85
    ) throws -> ProcessingResult {
        let decoded: ProcessingResult
        do {
            decoded = try JSONDecoder().decode(ProcessingResult.self, from: data)
        } catch {
            throw ProcessingValidationError.invalidJSON
        }

        let output = decoded.outputText
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !output.isEmpty else {
            throw ProcessingValidationError.emptyOutput
        }

        let normalizedOutput = normalizeForFactComparison(output)
        for fact in requiredFacts {
            let normalizedFact = normalizeForFactComparison(fact)
            guard normalizedFact.isEmpty
                    || normalizedOutput.contains(normalizedFact) else {
                throw ProcessingValidationError.missingFact(fact)
            }
        }

        if decoded.intent == .composeEmail,
           decoded.confidence < emailConfidenceThreshold {
            return decoded.downgradedToPlainText()
        }
        return decoded
    }

    private static func normalizeForFactComparison(_ value: String) -> String {
        value
            .lowercased()
            .replacingOccurrences(
                of: #"\s+"#,
                with: "",
                options: .regularExpression
            )
    }
}

public enum EmailOutputFormatter {
    public static func format(
        body: String,
        recipient: String?,
        signature: String
    ) -> String {
        let trimmedBody = body
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(
                of: #"(?i)^(?:hi|hello|dear)\s+[^,，:：\n]{1,30}[,，:：]\s*"#,
                with: "",
                options: .regularExpression
            )
            .replacingOccurrences(
                of: #"^[^,，:：\n]{1,20}[,，](?:你好|您好)[：:，,]?\s*"#,
                with: "",
                options: .regularExpression
            )
        let isEnglish = trimmedBody.range(
            of: #"\p{Han}"#,
            options: .regularExpression
        ) == nil
        let addressee = recipient?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let greeting: String
        let closing: String
        if isEnglish {
            greeting = addressee.map { "Dear \($0)," } ?? "Hello,"
            closing = signature.isEmpty
                ? "Best regards"
                : "Best regards,\n\(signature)"
        } else {
            greeting = addressee.map { "\($0)，您好：" } ?? "您好："
            closing = signature.isEmpty ? "祝好" : "祝好\n\(signature)"
        }
        return DocumentFormatter.format(
            "\(greeting)\n\n\(trimmedBody)\n\n\(closing)"
        ).plainText
    }
}

public enum RecipientExtractor {
    public static func recipient(from text: String) -> String? {
        let patterns = [
            #"给\s*([^，。！？\s]{1,20}?)\s*(?:发|写|回复|回)(?:一封|封)?邮件"#,
            #"(?:发|写)(?:一封|封)?邮件给\s*([^，。！？\s]{1,20})"#
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(
                    in: text,
                    range: NSRange(text.startIndex..., in: text)
                  ),
                  match.numberOfRanges > 1,
                  let range = Range(match.range(at: 1), in: text) else {
                continue
            }
            return String(text[range])
        }
        return nil
    }
}

public struct FormattedDocument: Equatable, Sendable {
    public let plainText: String
    public let html: String

    public init(plainText: String, html: String) {
        self.plainText = plainText
        self.html = html
    }
}

public enum DocumentFormatter {
    public static func format(_ input: String) -> FormattedDocument {
        let normalized = input
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\u{3000}", with: " ")

        let lines = normalized
            .components(separatedBy: "\n")
            .map {
                $0.replacingOccurrences(of: "\t", with: "")
                    .trimmingCharacters(in: .whitespaces)
            }

        var compacted: [String] = []
        var previousWasBlank = true
        for line in lines {
            let isBlank = line.isEmpty
            if isBlank {
                if !previousWasBlank {
                    compacted.append("")
                }
            } else {
                compacted.append(line)
            }
            previousWasBlank = isBlank
        }
        while compacted.last?.isEmpty == true {
            compacted.removeLast()
        }

        let plainText = compacted.joined(separator: "\n")
        let paragraphs = plainText.components(separatedBy: "\n\n")
        let nonEmptyParagraphs = paragraphs.filter { !$0.isEmpty }
        let html = nonEmptyParagraphs
            .enumerated()
            .map { index, paragraph in
                let body = paragraph
                    .components(separatedBy: "\n")
                    .map(escapeHTML)
                    .joined(separator: "<br>")
                let margin = index == nonEmptyParagraphs.count - 1
                    ? "0"
                    : "0 0 1em 0"
                return """
                <p style="margin:\(margin);text-indent:0">\(body)</p>
                """
            }
            .joined()

        return FormattedDocument(plainText: plainText, html: html)
    }

    private static func escapeHTML(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}

public enum SpokenStructureNormalizer {
    public static func normalize(_ input: String) -> String {
        let normalized = input
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return normalized }

        let punctuated = replaceSpokenPunctuation(in: normalized)
        return numberedList(from: punctuated) ?? punctuated
    }

    private static func replaceSpokenPunctuation(in input: String) -> String {
        let commands: [(word: String, symbol: String, needsSuffix: Bool)] = [
            ("另起一段", "\n\n", true),
            ("感叹号", "！", false),
            ("问号", "？", false),
            ("句号", "。", false),
            ("逗号", "，", true),
            ("换行", "\n", true)
        ]
        var value = input
        for command in commands {
            value = replace(
                command.word,
                with: command.symbol,
                needsSuffix: command.needsSuffix,
                in: value
            )
        }
        return value
    }

    private static func replace(
        _ command: String,
        with symbol: String,
        needsSuffix: Bool,
        in input: String
    ) -> String {
        var value = input
        var searchStart = value.startIndex

        while searchStart < value.endIndex,
              let range = value.range(
                  of: command,
                  range: searchStart..<value.endIndex
              ) {
            let prefix = String(value[..<range.lowerBound])
            let suffix = String(value[range.upperBound...])
            let hasPrefix = prefix.contains {
                !$0.isWhitespace && !$0.isPunctuation
            }
            let hasSuffix = suffix.contains {
                !$0.isWhitespace && !$0.isPunctuation
            }
            let isLiteralTerm = literalPrefixes.contains {
                prefix.hasSuffix($0)
            } || literalSuffixes.contains {
                suffix.hasPrefix($0)
            }

            if hasPrefix,
               (!needsSuffix || hasSuffix),
               !isLiteralTerm {
                value.replaceSubrange(range, with: symbol)
                searchStart = value.index(
                    range.lowerBound,
                    offsetBy: symbol.count
                )
            } else {
                searchStart = range.upperBound
            }
        }
        return value
    }

    private static func numberedList(from input: String) -> String? {
        let pattern = #"第([一二三四五六七八九十])(?:点|个)|([一二三四五六七八九十])是"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return nil
        }
        let matches = regex.matches(
            in: input,
            range: NSRange(input.startIndex..., in: input)
        )
        guard matches.count >= 2 else { return nil }

        let numberedMatches = matches.compactMap { match -> (Int, Range<String.Index>)? in
            let numeralRange = match.range(at: 1).location != NSNotFound
                ? match.range(at: 1)
                : match.range(at: 2)
            guard let swiftNumeralRange = Range(numeralRange, in: input),
                  let markerRange = Range(match.range, in: input),
                  let number = chineseNumber(
                      String(input[swiftNumeralRange])
                  ) else {
                return nil
            }
            return (number, markerRange)
        }
        guard numberedMatches.count == matches.count,
              numberedMatches.first?.0 == 1,
              numberedMatches.enumerated().allSatisfy({
                  $0.element.0 == $0.offset + 1
              }) else {
            return nil
        }

        var items: [String] = []
        for (index, match) in numberedMatches.enumerated() {
            let contentStart = match.1.upperBound
            let contentEnd = index + 1 < numberedMatches.count
                ? numberedMatches[index + 1].1.lowerBound
                : input.endIndex
            let content = input[contentStart..<contentEnd]
                .trimmingCharacters(in: listBoundaryCharacters)
            guard !content.isEmpty else { return nil }
            items.append("\(match.0). \(content)")
        }

        let prefix = input[..<numberedMatches[0].1.lowerBound]
            .trimmingCharacters(in: listBoundaryCharacters)
        return prefix.isEmpty
            ? items.joined(separator: "\n")
            : "\(prefix)\n\(items.joined(separator: "\n"))"
    }

    private static func chineseNumber(_ value: String) -> Int? {
        [
            "一": 1, "二": 2, "三": 3, "四": 4, "五": 5,
            "六": 6, "七": 7, "八": 8, "九": 9, "十": 10
        ][value]
    }

    private static let literalPrefixes = [
        "叫", "称为", "名为", "输入", "说出", "读作"
    ]

    private static let literalSuffixes = [
        "是中文标点", "是标点", "这个词", "状态", "字符", "符号"
    ]

    private static let listBoundaryCharacters = CharacterSet(
        charactersIn: " \t\n，,、：:"
    )
}

public struct ProcessingBenchmarkSample: Codable, Equatable, Sendable {
    public let modelID: String
    public let inputCharacters: Int
    public let inputTokens: Int
    public let outputCharacters: Int
    public let outputTokens: Int
    public let modelLoadSeconds: Double
    public let promptPrefillSeconds: Double
    public let firstTokenSeconds: Double
    public let generationSeconds: Double
    public let validationSeconds: Double
    public let insertionSeconds: Double
    public let totalSeconds: Double

    public init(
        modelID: String,
        inputCharacters: Int,
        inputTokens: Int,
        outputCharacters: Int,
        outputTokens: Int,
        modelLoadSeconds: Double,
        promptPrefillSeconds: Double,
        firstTokenSeconds: Double,
        generationSeconds: Double,
        validationSeconds: Double,
        insertionSeconds: Double,
        totalSeconds: Double
    ) {
        self.modelID = modelID
        self.inputCharacters = inputCharacters
        self.inputTokens = inputTokens
        self.outputCharacters = outputCharacters
        self.outputTokens = outputTokens
        self.modelLoadSeconds = modelLoadSeconds
        self.promptPrefillSeconds = promptPrefillSeconds
        self.firstTokenSeconds = firstTokenSeconds
        self.generationSeconds = generationSeconds
        self.validationSeconds = validationSeconds
        self.insertionSeconds = insertionSeconds
        self.totalSeconds = totalSeconds
    }

    public var promptPrefillTokensPerSecond: Double {
        rate(Double(inputTokens), promptPrefillSeconds)
    }

    public var generationTokensPerSecond: Double {
        rate(Double(outputTokens), generationSeconds)
    }

    public var outputCharactersPerSecond: Double {
        rate(Double(outputCharacters), totalSeconds)
    }

    private func rate(_ amount: Double, _ seconds: Double) -> Double {
        seconds > 0 ? amount / seconds : 0
    }
}

public struct ProcessingQualityCase: Codable, Equatable, Sendable {
    public let id: String
    public let transcript: String
    public let mode: VoiceMode
    public let expectedIntent: DraftIntent
    public let requiredFacts: [String]
    public let semanticGroups: [[String]]
    public let requiresEmailStructure: Bool

    public init(
        id: String,
        transcript: String,
        mode: VoiceMode,
        expectedIntent: DraftIntent,
        requiredFacts: [String],
        semanticGroups: [[String]],
        requiresEmailStructure: Bool
    ) {
        self.id = id
        self.transcript = transcript
        self.mode = mode
        self.expectedIntent = expectedIntent
        self.requiredFacts = requiredFacts
        self.semanticGroups = semanticGroups
        self.requiresEmailStructure = requiresEmailStructure
    }
}

public struct ProcessingQualityEvaluation: Equatable, Sendable {
    public let passed: Bool
    public let intentMatches: Bool
    public let missingFacts: [String]
    public let semanticScore: Double
    public let hasExpectedStructure: Bool
}

public enum ProcessingQualityEvaluator {
    public static func evaluate(
        _ result: ProcessingResult,
        against testCase: ProcessingQualityCase
    ) -> ProcessingQualityEvaluation {
        let normalized = normalize(result.outputText)
        let missingFacts = testCase.requiredFacts
            .filter { !normalized.contains(normalize($0)) }
            .sorted()
        let matchedGroups = testCase.semanticGroups.filter { alternatives in
            alternatives.contains { normalized.contains(normalize($0)) }
        }.count
        let semanticScore = testCase.semanticGroups.isEmpty
            ? 1
            : Double(matchedGroups) / Double(testCase.semanticGroups.count)
        let hasExpectedStructure = !testCase.requiresEmailStructure
            || hasEmailStructure(result.outputText)
        let intentMatches = result.intent == testCase.expectedIntent
        return ProcessingQualityEvaluation(
            passed: intentMatches
                && missingFacts.isEmpty
                && semanticScore == 1
                && hasExpectedStructure,
            intentMatches: intentMatches,
            missingFacts: missingFacts,
            semanticScore: semanticScore,
            hasExpectedStructure: hasExpectedStructure
        )
    }

    private static func hasEmailStructure(_ text: String) -> Bool {
        let normalized = text.lowercased()
        let hasGreeting = ["你好", "您好", "hi ", "hello ", "dear "]
            .contains(where: normalized.contains)
        let hasClosing = ["祝好", "谢谢", "此致", "best", "regards", "thanks"]
            .contains(where: normalized.contains)
        return hasGreeting && hasClosing && text.contains("\n\n")
    }

    private static func normalize(_ value: String) -> String {
        value
            .lowercased()
            .replacingOccurrences(
                of: #"[\s，。！？、,.!?:：;；“”"'（）()\-]+"#,
                with: "",
                options: .regularExpression
            )
    }
}

public struct ModelGenerationOutput: Equatable, Sendable {
    public let text: String
    public let inputTokens: Int
    public let outputTokens: Int
    public let promptPrefillSeconds: Double
    public let firstTokenSeconds: Double
    public let generationSeconds: Double

    public init(
        text: String,
        inputTokens: Int = 0,
        outputTokens: Int = 0,
        promptPrefillSeconds: Double = 0,
        firstTokenSeconds: Double = 0,
        generationSeconds: Double = 0
    ) {
        self.text = text
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.promptPrefillSeconds = promptPrefillSeconds
        self.firstTokenSeconds = firstTokenSeconds
        self.generationSeconds = generationSeconds
    }
}

public struct ModelGenerationProgress: Equatable, Sendable {
    public let outputCharacters: Int

    public init(outputCharacters: Int) {
        self.outputCharacters = max(outputCharacters, 0)
    }
}

public protocol LocalLanguageModelService: Sendable {
    func generate(prompt: String) async throws -> ModelGenerationOutput
    func generate(
        prompt: String,
        onProgress: @escaping @Sendable (ModelGenerationProgress) -> Void
    ) async throws -> ModelGenerationOutput
}

public extension LocalLanguageModelService {
    func generate(
        prompt: String,
        onProgress: @escaping @Sendable (ModelGenerationProgress) -> Void
    ) async throws -> ModelGenerationOutput {
        onProgress(ModelGenerationProgress(outputCharacters: 0))
        let output = try await generate(prompt: prompt)
        onProgress(ModelGenerationProgress(outputCharacters: output.text.count))
        return output
    }
}

public enum PromptBuilder {
    public static func processingPrompt(
        transcript: String,
        mode: VoiceMode,
        signature: String,
        intentHint: DraftIntent,
        profileHint: String? = nil,
        suspects: [SuspectSpan] = []
    ) -> String {
        let targetLanguage = mode == .english ? "英文" : "跟随原文语言"
        let profileSection = profileHint.map { "\n\($0)\n" } ?? ""
        let suspectsSection = buildSuspectsBlock(suspects)
        return """
        你是本地语音输入整理器。只返回一个 JSON 对象，不要 Markdown，不要解释。

        JSON schema:
        {
          "intent": "plainText" | "composeEmail",
          "confidence": 0.0...1.0,
          "outputText": "最终可直接粘贴的文本",
          "corrections": [{"from":"原词","to":"替换词"}],
          "email": null | {
            "recipient": "明确收件人或 null",
            "missingFields": ["缺失字段"]
          }
        }

        规则：
        - 意图提示为 \(intentHint.rawValue)，但必须根据完整原文判断。
        - 输出语言：\(targetLanguage)。
        - 删除口语填充和重复，保留原文事实。
        - 根据语义补全逗号、句号、问号和感叹号。
        - 已有的 1.、2.、3. 编号列表必须逐项换行并保持编号顺序。
        - 不得在 URL、邮箱、时间、金额或产品编号内部插入标点。
        - 完整保留原文信息，不得总结、缩写、截断或省略后半段。
        - 不得虚构姓名、日期、金额、URL、编号、附件或承诺。
        - URL、邮箱、编号、金额、时间必须逐字保留，一个字符都不能改。
        - 中文用词保留原意，不得改写中文词语。
        - 原文是语音转写，句中英文词可能因近音被误识别。如某英文词在当前语境明显不通顺，请结合整句语义替换为读音相近、最符合语境的词，并在 corrections 中申报：{"from":"原词","to":"替换词"}。只在有把握时替换，没把握则保留原词不申报。corrections 最多 8 条。
        - 邮件命令删除命令前缀；outputText 只写正文，不写问候、结束语或签名。
        - 邮件正文只写入 outputText；email 只写 recipient 和 missingFields。
        - 用户签名为空时不得虚构签名。
        - 低于 0.85 的邮件判断返回 plainText。
        - 输出紧凑 JSON，不要空格或换行。
        \(profileSection)\(suspectsSection)
        用户签名：
        \(signature.isEmpty ? "(未设置)" : signature)

        完整转写：
        \(transcript)
        """
    }

    private static func buildSuspectsBlock(_ suspects: [SuspectSpan]) -> String {
        guard !suspects.isEmpty else { return "" }
        var lines = [
            "\n识别器低置信片段（这些位置最可能是近音误识别；括号内是识别器的其他候选写法，可作参考但不必采用）："
        ]
        for span in suspects {
            let conf = String(format: "%.2f", span.confidence)
            if span.alternatives.isEmpty {
                lines.append("- \"\(span.text)\"（置信度 \(conf)）")
            } else {
                let alts = span.alternatives.joined(separator: " / ")
                lines.append("- \"\(span.text)\"（候选：\(alts)，置信度 \(conf)）")
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    public static func retryPrompt(
        originalPrompt: String,
        invalidOutput: String
    ) -> String {
        """
        上一次输出无效或不完整。重新执行原始任务。
        必须返回单个合法 JSON 对象，并完整保留原文全部信息。
        不得总结、缩写、截断或省略后半段。
        如果输出中包含近音纠错替换，必须在 corrections 字段中逐条申报。

        原始任务：
        \(originalPrompt)

        上一次无效输出：
        \(invalidOutput)
        """
    }

    public static func translationPrompt(_ transcript: String) -> String {
        """
        将下面的完整中文逐句翻译成自然英文。
        只返回英文译文，不要 JSON、Markdown、解释或前后缀。
        不得总结、缩写、截断或省略任何句子。
        产品名、URL、编号、时间和金额必须逐字保留。

        \(transcript)
        """
    }

    public static func translationRetryPrompt(
        transcript: String,
        invalidOutput: String
    ) -> String {
        """
        上一次英文翻译无效或不完整。重新翻译下面的全部中文。
        只返回英文译文，不要 JSON、Markdown、解释或前后缀。
        不得保留未翻译的中文句子，不得总结、缩写、截断或省略。
        产品名、URL、编号、时间和金额必须逐字保留。

        完整中文：
        \(transcript)

        上一次无效输出：
        \(invalidOutput)
        """
    }
}

public struct DraftProcessingOutcome: Equatable, Sendable {
    public let result: ProcessingResult
    public let usedFallback: Bool
    public let generation: ModelGenerationOutput?
    public let totalSeconds: Double
    public let generationAttempts: Int

    public init(
        result: ProcessingResult,
        usedFallback: Bool,
        generation: ModelGenerationOutput?,
        totalSeconds: Double,
        generationAttempts: Int = 1
    ) {
        self.result = result
        self.usedFallback = usedFallback
        self.generation = generation
        self.totalSeconds = totalSeconds
        self.generationAttempts = generationAttempts
    }
}

public actor DraftProcessingService {
    private let languageModel: any LocalLanguageModelService
    private let timeout: Duration

    public init(
        languageModel: any LocalLanguageModelService,
        timeout: Duration = .seconds(12)
    ) {
        self.languageModel = languageModel
        self.timeout = timeout
    }

    public func process(
        transcript: String,
        mode: VoiceMode,
        signature: String,
        profileHint: String? = nil,
        glossary: [GlossaryTerm] = [],
        suspects: [SuspectSpan] = [],
        onProgress: @escaping @Sendable (ProcessingProgress) -> Void = { _ in }
    ) async -> DraftProcessingOutcome {
        onProgress(.preparing)
        let language: CorrectionLanguage = transcript.range(
            of: #"\p{Han}"#,
            options: .regularExpression
        ) == nil ? .english : .chinese
        let corrected = TextCorrector.correct(
            transcript,
            language: language
        )
        let normalized = SpokenStructureNormalizer.normalize(corrected)
        let outcome: DraftProcessingOutcome
        if mode == .english {
            let chunks = Self.translationChunks(normalized)
            if chunks.count > 1 {
                outcome = await processEnglishChunks(
                    chunks,
                    glossary: glossary,
                    onProgress: onProgress
                )
            } else {
                outcome = await processSingle(
                    transcript: normalized,
                    mode: mode,
                    signature: signature,
                    profileHint: profileHint,
                    glossary: glossary,
                    suspects: suspects,
                    onProgress: onProgress
                )
            }
            onProgress(.validating)
            return Self.sanitizingEnglishOutput(outcome)
        }
        outcome = await processSingle(
            transcript: normalized,
            mode: mode,
            signature: signature,
            profileHint: profileHint,
            glossary: glossary,
            suspects: suspects,
            onProgress: onProgress
        )
        onProgress(.validating)
        return outcome
    }

    public func translateSelection(
        transcript: String,
        glossary: [GlossaryTerm] = [],
        onProgress: @escaping @Sendable (ProcessingProgress) -> Void = { _ in }
    ) async -> DraftProcessingOutcome {
        onProgress(.preparing)
        let corrected = TextCorrector.correct(transcript, language: .chinese)
        let normalized = SpokenStructureNormalizer.normalize(corrected)
        let chunks = Self.translationChunks(normalized)
        let outcome = await processEnglishChunks(
            chunks,
            glossary: glossary,
            onProgress: onProgress
        )
        onProgress(.validating)
        return Self.sanitizingEnglishOutput(outcome)
    }

    /// English translation output must never carry the original Chinese. The
    /// model can echo the source, and per-chunk/whole-transcript fallbacks keep
    /// the untranslated text verbatim. Drop any residual Han-bearing sentence as
    /// a final guard so only the English translation reaches the user.
    private static func sanitizingEnglishOutput(
        _ outcome: DraftProcessingOutcome
    ) -> DraftProcessingOutcome {
        let cleaned = removingResidualChinese(outcome.result.outputText)
        guard cleaned != outcome.result.outputText else { return outcome }
        let result = outcome.result
        return DraftProcessingOutcome(
            result: ProcessingResult(
                intent: result.intent,
                confidence: result.confidence,
                outputText: cleaned,
                email: result.email,
                corrections: result.corrections
            ),
            usedFallback: outcome.usedFallback,
            generation: outcome.generation,
            totalSeconds: outcome.totalSeconds,
            generationAttempts: outcome.generationAttempts
        )
    }

    /// Removes sentences that still contain Chinese (Han) characters, then
    /// strips any stray Han characters left in otherwise-English sentences.
    /// Line structure (numbered lists, paragraphs) is preserved.
    static func removingResidualChinese(_ text: String) -> String {
        guard text.range(
            of: #"\p{Han}"#,
            options: .regularExpression
        ) != nil else {
            return text
        }
        let cleanedLines = text.components(separatedBy: "\n").map { line -> String in
            let sentences = line.matches(
                of: /[^。！？!?.]+[。！？!?.]?/
            ).map { String($0.output) }
            let englishOnly = sentences.filter { sentence in
                sentence.range(
                    of: #"\p{Han}"#,
                    options: .regularExpression
                ) == nil
            }
            return englishOnly.joined()
                .replacingOccurrences(
                    of: #" {2,}"#,
                    with: " ",
                    options: .regularExpression
                )
                .trimmingCharacters(in: .whitespaces)
        }
        return cleanedLines
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func processEnglishChunks(
        _ chunks: [String],
        glossary: [GlossaryTerm] = [],
        onProgress: @escaping @Sendable (ProcessingProgress) -> Void
    ) async -> DraftProcessingOutcome {
        var outputs: [String] = []
        var generations: [ModelGenerationOutput] = []
        var usedFallback = false
        var totalSeconds = 0.0
        var generationAttempts = 0

        for (index, chunk) in chunks.enumerated() {
            let outcome = await processTranslationChunk(
                chunk,
                onProgress: { progress in
                    let local = min(
                        max((progress.fraction - 0.18) / 0.70, 0),
                        1
                    )
                    let completed = (Double(index) + local)
                        / Double(chunks.count)
                    onProgress(ProcessingProgress(
                        fraction: 0.18 + completed * 0.70
                    ))
                }
            )
            outputs.append(outcome.result.outputText)
            if let generation = outcome.generation {
                generations.append(generation)
            }
            usedFallback = usedFallback || outcome.usedFallback
            totalSeconds += outcome.totalSeconds
            generationAttempts += outcome.generationAttempts
        }

        let rawOutput = outputs.joined(separator: " ")
        let output = GlossaryNormalizer.normalize(rawOutput, glossary: glossary)
        return DraftProcessingOutcome(
            result: ProcessingResult(
                intent: .plainText,
                confidence: usedFallback ? 0 : 1,
                outputText: output,
                email: nil
            ),
            usedFallback: usedFallback,
            generation: Self.combinedGeneration(generations),
            totalSeconds: totalSeconds,
            generationAttempts: generationAttempts
        )
    }

    private func processTranslationChunk(
        _ transcript: String,
        onProgress: @escaping @Sendable (ProcessingProgress) -> Void
    ) async -> DraftProcessingOutcome {
        let clock = ContinuousClock()
        let start = clock.now

        do {
            let first = try await Self.generate(
                languageModel,
                prompt: PromptBuilder.translationPrompt(transcript),
                timeout: timeout,
                estimatedCharacters: Self.estimatedGenerationCharacters(
                    transcript: transcript,
                    mode: .english
                ),
                attempt: 1,
                onProgress: onProgress
            )
            if let translation = Self.validatedTranslation(
                first.text,
                source: transcript
            ) {
                return Self.translationOutcome(
                    translation,
                    generation: first,
                    attempts: 1,
                    start: start,
                    end: clock.now
                )
            }

            let second = try await Self.generate(
                languageModel,
                prompt: PromptBuilder.translationRetryPrompt(
                    transcript: transcript,
                    invalidOutput: first.text
                ),
                timeout: timeout,
                estimatedCharacters: Self.estimatedGenerationCharacters(
                    transcript: transcript,
                    mode: .english
                ),
                attempt: 2,
                onProgress: onProgress
            )
            if let translation = Self.validatedTranslation(
                second.text,
                source: transcript
            ) {
                return Self.translationOutcome(
                    translation,
                    generation: second,
                    attempts: 2,
                    start: start,
                    end: clock.now
                )
            }
        } catch {
            // The caller retains the source chunk when local translation fails.
        }

        return DraftProcessingOutcome(
            result: ProcessingResult(
                intent: .plainText,
                confidence: 0,
                outputText: transcript,
                email: nil
            ),
            usedFallback: true,
            generation: nil,
            totalSeconds: Self.seconds(from: start, to: clock.now),
            generationAttempts: 2
        )
    }

    private func processSingle(
        transcript: String,
        mode: VoiceMode,
        signature: String,
        profileHint: String? = nil,
        glossary: [GlossaryTerm] = [],
        suspects: [SuspectSpan] = [],
        onProgress: @escaping @Sendable (ProcessingProgress) -> Void
    ) async -> DraftProcessingOutcome {
        let clock = ContinuousClock()
        let start = clock.now
        let intentHint = IntentHintDetector.detect(transcript)
        let prompt = PromptBuilder.processingPrompt(
            transcript: transcript,
            mode: mode,
            signature: signature,
            intentHint: intentHint,
            profileHint: profileHint,
            suspects: suspects
        )
        let facts = FactExtractor.hardFacts(from: transcript)
        let extractedRecipient = RecipientExtractor.recipient(from: transcript)

        do {
            let first = try await Self.generate(
                languageModel,
                prompt: prompt,
                timeout: timeout,
                estimatedCharacters: Self.estimatedGenerationCharacters(
                    transcript: transcript,
                    mode: mode
                ),
                attempt: 1,
                onProgress: onProgress
            )
            if let result = Self.validated(
                first.text,
                source: transcript,
                mode: mode,
                facts: facts
            ) {
                return DraftProcessingOutcome(
                    result: Self.normalizedFormatted(
                        result,
                        signature: signature,
                        recipient: extractedRecipient,
                        glossary: glossary
                    ),
                    usedFallback: false,
                    generation: first,
                    totalSeconds: Self.seconds(from: start, to: clock.now),
                    generationAttempts: 1
                )
            }

            let repaired = try await Self.generate(
                languageModel,
                prompt: PromptBuilder.retryPrompt(
                    originalPrompt: prompt,
                    invalidOutput: first.text
                ),
                timeout: timeout,
                estimatedCharacters: Self.estimatedGenerationCharacters(
                    transcript: transcript,
                    mode: mode
                ),
                attempt: 2,
                onProgress: onProgress
            )
            if let result = Self.validated(
                repaired.text,
                source: transcript,
                mode: mode,
                facts: facts
            ) {
                return DraftProcessingOutcome(
                    result: Self.normalizedFormatted(
                        result,
                        signature: signature,
                        recipient: extractedRecipient,
                        glossary: glossary
                    ),
                    usedFallback: false,
                    generation: repaired,
                    totalSeconds: Self.seconds(from: start, to: clock.now),
                    generationAttempts: 2
                )
            }
        } catch {
            // Deterministic fallback below keeps dictation available offline.
        }

        let rawFallback = DocumentFormatter.format(transcript).plainText
        let fallback = GlossaryNormalizer.normalize(rawFallback, glossary: glossary)
        return DraftProcessingOutcome(
            result: ProcessingResult(
                intent: .plainText,
                confidence: 1,
                outputText: fallback,
                email: nil
            ),
            usedFallback: true,
            generation: nil,
            totalSeconds: Self.seconds(from: start, to: clock.now),
            generationAttempts: 2
        )
    }

    private static func validated(
        _ response: String,
        source: String,
        mode: VoiceMode,
        facts: [String]
    ) -> ProcessingResult? {
        guard let data = jsonData(from: response) else { return nil }
        guard let raw = try? ProcessingResultValidator.validate(
            data,
            requiredFacts: facts
        ) else {
            return nil
        }

        // Apply and validate near-sound corrections declared by the model.
        // Invalid corrections are reverted (worst case: text unchanged).
        // Hard facts are protected, so the facts check above remains valid after correction.
        let (correctedText, accepted, _) = CorrectionValidator.apply(
            corrections: raw.corrections,
            to: raw.outputText,
            source: source,
            protectedFacts: facts
        )
        // In English mode the model can echo the original Chinese alongside its
        // translation. Strip those source sentences before the preservation and
        // translation checks so the English survives validation.
        let outputText = mode == .english
            ? removingResidualChinese(correctedText)
            : correctedText
        let result: ProcessingResult
        if accepted.isEmpty && outputText == raw.outputText {
            result = raw
        } else {
            result = ProcessingResult(
                intent: raw.intent,
                confidence: raw.confidence,
                outputText: outputText,
                email: raw.email,
                corrections: accepted
            )
        }

        guard preservesInput(
            result.outputText,
            source: source,
            mode: mode
        ) else {
            return nil
        }
        guard preservesNumberedListStructure(
            result.outputText,
            source: source
        ) else {
            return nil
        }
        guard isTranslatedWhenRequired(
            result.outputText,
            source: source,
            mode: mode
        ) else {
            return nil
        }
        return result
    }

    private static func preservesInput(
        _ output: String,
        source: String,
        mode: VoiceMode
    ) -> Bool {
        let sourceCount = contentCharacterCount(source)
        let minimumSourceCount = mode == .english ? 40 : 160
        guard sourceCount >= minimumSourceCount else { return true }
        let outputCount = contentCharacterCount(output)
        let minimumRatio = mode == .english ? 0.45 : 0.55
        return outputCount >= Int(Double(sourceCount) * minimumRatio)
    }

    private static func preservesNumberedListStructure(
        _ output: String,
        source: String
    ) -> Bool {
        let sourceNumbers = numberedListMarkers(in: source)
        guard !sourceNumbers.isEmpty else { return true }
        return numberedListMarkers(in: output) == sourceNumbers
    }

    private static func numberedListMarkers(in text: String) -> [Int] {
        guard let regex = try? NSRegularExpression(
            pattern: #"(?m)^(\d+)\.\s+\S"#
        ) else {
            return []
        }
        return regex.matches(
            in: text,
            range: NSRange(text.startIndex..., in: text)
        ).compactMap { match in
            guard let range = Range(match.range(at: 1), in: text) else {
                return nil
            }
            return Int(text[range])
        }
    }

    private static func contentCharacterCount(_ text: String) -> Int {
        text.reduce(into: 0) { count, character in
            if !character.isWhitespace {
                count += 1
            }
        }
    }

    private static func validatedTranslation(
        _ response: String,
        source: String
    ) -> String? {
        // Drop any echoed source sentences before judging the translation so a
        // partial mix of English + Chinese is salvaged into clean English rather
        // than rejected (and replaced by the untranslated source on fallback).
        let output = removingResidualChinese(
            response.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        guard !output.isEmpty,
              preservesInput(output, source: source, mode: .english),
              isTranslatedWhenRequired(
                output,
                source: source,
                mode: .english
              ) else {
            return nil
        }
        let normalizedOutput = normalizeForFactComparison(output)
        let facts = FactExtractor.hardFacts(from: source)
        guard facts.allSatisfy({
            normalizedOutput.contains(normalizeForFactComparison($0))
        }) else {
            return nil
        }
        return output
    }

    private static func normalizeForFactComparison(_ text: String) -> String {
        text.lowercased().replacingOccurrences(
            of: #"\s+"#,
            with: "",
            options: .regularExpression
        )
    }

    private static func translationOutcome(
        _ translation: String,
        generation: ModelGenerationOutput,
        attempts: Int,
        start: ContinuousClock.Instant,
        end: ContinuousClock.Instant
    ) -> DraftProcessingOutcome {
        DraftProcessingOutcome(
            result: ProcessingResult(
                intent: .plainText,
                confidence: 1,
                outputText: translation,
                email: nil
            ),
            usedFallback: false,
            generation: generation,
            totalSeconds: seconds(from: start, to: end),
            generationAttempts: attempts
        )
    }

    private static func isTranslatedWhenRequired(
        _ output: String,
        source: String,
        mode: VoiceMode
    ) -> Bool {
        guard mode == .english,
              source.range(
                of: #"\p{Han}"#,
                options: .regularExpression
              ) != nil else {
            return true
        }
        let outputCount = contentCharacterCount(output)
        guard outputCount > 0 else { return false }
        let hanCount = output.reduce(into: 0) { count, character in
            if String(character).range(
                of: #"\p{Han}"#,
                options: .regularExpression
            ) != nil {
                count += 1
            }
        }
        return Double(hanCount) / Double(outputCount) <= 0.2
    }

    private static func translationChunks(_ text: String) -> [String] {
        let sentences = text.matches(
            of: /[^。！？!?]+[。！？!?]?/
        ).map {
            String($0.output)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty }
        guard sentences.count > 1 else { return [text] }

        var chunks: [String] = []
        var current = ""
        for sentence in sentences {
            if !current.isEmpty, current.count + sentence.count > 70 {
                chunks.append(current)
                current = sentence
            } else {
                current += sentence
            }
        }
        if !current.isEmpty {
            chunks.append(current)
        }
        return chunks
    }

    private static func combinedGeneration(
        _ generations: [ModelGenerationOutput]
    ) -> ModelGenerationOutput? {
        guard !generations.isEmpty else { return nil }
        return ModelGenerationOutput(
            text: generations.map(\.text).joined(separator: "\n"),
            inputTokens: generations.reduce(0) { $0 + $1.inputTokens },
            outputTokens: generations.reduce(0) { $0 + $1.outputTokens },
            promptPrefillSeconds: generations.reduce(0) {
                $0 + $1.promptPrefillSeconds
            },
            firstTokenSeconds: generations.reduce(0) {
                $0 + $1.firstTokenSeconds
            },
            generationSeconds: generations.reduce(0) {
                $0 + $1.generationSeconds
            }
        )
    }

    private static func formatted(
        _ result: ProcessingResult,
        signature: String,
        recipient: String?
    ) -> ProcessingResult {
        normalizedFormatted(result, signature: signature, recipient: recipient, glossary: [])
    }

    private static func normalizedFormatted(
        _ result: ProcessingResult,
        signature: String,
        recipient: String?,
        glossary: [GlossaryTerm]
    ) -> ProcessingResult {
        let rawOutput: String
        if result.intent == .composeEmail {
            rawOutput = EmailOutputFormatter.format(
                body: result.outputText,
                recipient: recipient ?? result.email?.recipient,
                signature: signature
            )
        } else {
            rawOutput = DocumentFormatter.format(result.outputText).plainText
        }
        let output = GlossaryNormalizer.normalize(rawOutput, glossary: glossary)
        let email = result.email.map {
            EmailDraft(
                subject: $0.subject,
                recipient: $0.recipient,
                body: DocumentFormatter.format($0.body).plainText,
                missingFields: $0.missingFields
            )
        }
        return ProcessingResult(
            intent: result.intent,
            confidence: result.confidence,
            outputText: output,
            email: email,
            corrections: result.corrections
        )
    }

    private static func jsonData(from response: String) -> Data? {
        guard let start = response.firstIndex(of: "{"),
              let end = response.lastIndex(of: "}"),
              start <= end else {
            return nil
        }
        return Data(response[start...end].utf8)
    }

    private static func generate(
        _ model: any LocalLanguageModelService,
        prompt: String,
        timeout: Duration,
        estimatedCharacters: Int,
        attempt: Int,
        onProgress: @escaping @Sendable (ProcessingProgress) -> Void
    ) async throws -> ModelGenerationOutput {
        try await withThrowingTaskGroup(
            of: ModelGenerationOutput.self
        ) { group in
            group.addTask {
                try await model.generate(
                    prompt: prompt,
                    onProgress: { modelProgress in
                        onProgress(.generating(
                            outputCharacters: modelProgress.outputCharacters,
                            estimatedCharacters: estimatedCharacters,
                            attempt: attempt
                        ))
                    }
                )
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw DraftProcessingError.timeout
            }
            guard let first = try await group.next() else {
                throw DraftProcessingError.noOutput
            }
            group.cancelAll()
            return first
        }
    }

    private static func estimatedGenerationCharacters(
        transcript: String,
        mode: VoiceMode
    ) -> Int {
        let translatedText = mode == .english
            ? transcript.count * 2
            : transcript.count
        return max(translatedText + 120, 160)
    }

    private static func seconds(
        from start: ContinuousClock.Instant,
        to end: ContinuousClock.Instant
    ) -> Double {
        let duration = start.duration(to: end)
        let components = duration.components
        return Double(components.seconds)
            + Double(components.attoseconds) / 1_000_000_000_000_000_000
    }
}

public enum DraftProcessingError: Error, Sendable {
    case timeout
    case noOutput
}

public enum FactExtractor {
    public static func hardFacts(from text: String) -> [String] {
        let patterns = [
            #"https?://[A-Za-z0-9._~:/?\[\]@!$&'()*+,;=%#-]+"#,
            #"(?<![A-Z0-9])[A-Z][A-Z0-9]+-[A-Z0-9-]+(?![A-Z0-9])"#,
            #"(?:¥|￥|\$)\s?\d+(?:\.\d+)?"#,
            #"\d+(?:\.\d+)?\s*(?:万元|美元|元|%)"#,
            #"\b\d{1,2}:\d{2}\b"#
        ]
        var facts: [String] = []
        for pattern in patterns {
            let regex = try? NSRegularExpression(pattern: pattern)
            let range = NSRange(text.startIndex..., in: text)
            regex?.enumerateMatches(in: text, range: range) { match, _, _ in
                guard let match,
                      let range = Range(match.range, in: text) else { return }
                facts.append(String(text[range]))
            }
        }
        return Array(Set(facts)).sorted()
    }
}
