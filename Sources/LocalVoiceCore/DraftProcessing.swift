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

public struct ProcessingResult: Codable, Equatable, Sendable {
    public let intent: DraftIntent
    public let confidence: Double
    public let outputText: String
    public let email: EmailDraft?

    public init(
        intent: DraftIntent,
        confidence: Double,
        outputText: String,
        email: EmailDraft?
    ) {
        self.intent = intent
        self.confidence = confidence
        self.outputText = outputText
        self.email = email
    }

    public func downgradedToPlainText() -> Self {
        Self(
            intent: .plainText,
            confidence: confidence,
            outputText: outputText,
            email: nil
        )
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

public protocol LocalLanguageModelService: Sendable {
    func generate(prompt: String) async throws -> ModelGenerationOutput
}

public enum PromptBuilder {
    public static func processingPrompt(
        transcript: String,
        mode: VoiceMode,
        signature: String,
        intentHint: DraftIntent
    ) -> String {
        let targetLanguage = mode == .english ? "英文" : "跟随原文语言"
        return """
        你是本地语音输入整理器。只返回一个 JSON 对象，不要 Markdown，不要解释。

        JSON schema:
        {
          "intent": "plainText" | "composeEmail",
          "confidence": 0.0...1.0,
          "outputText": "最终可直接粘贴的文本",
          "email": null | {
            "recipient": "明确收件人或 null",
            "missingFields": ["缺失字段"]
          }
        }

        规则：
        - 意图提示为 \(intentHint.rawValue)，但必须根据完整原文判断。
        - 输出语言：\(targetLanguage)。
        - 删除口语填充和重复，保留原文事实。
        - 完整保留原文信息，不得总结、缩写、截断或省略后半段。
        - 不得虚构姓名、日期、金额、URL、编号、附件或承诺。
        - 人名、产品名、URL、编号必须逐字保留，不得翻译或转写拼音。
        - 邮件命令删除命令前缀；outputText 只写正文，不写问候、结束语或签名。
        - 邮件正文只写入 outputText；email 只写 recipient 和 missingFields。
        - 用户签名为空时不得虚构签名。
        - 低于 0.85 的邮件判断返回 plainText。
        - 输出紧凑 JSON，不要空格或换行。

        用户签名：
        \(signature.isEmpty ? "(未设置)" : signature)

        完整转写：
        \(transcript)
        """
    }

    public static func retryPrompt(
        originalPrompt: String,
        invalidOutput: String
    ) -> String {
        """
        上一次输出无效或不完整。重新执行原始任务。
        必须返回单个合法 JSON 对象，并完整保留原文全部信息。
        不得总结、缩写、截断或省略后半段。

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
        signature: String
    ) async -> DraftProcessingOutcome {
        let language: CorrectionLanguage = transcript.range(
            of: #"\p{Han}"#,
            options: .regularExpression
        ) == nil ? .english : .chinese
        let normalized = TextCorrector.correct(transcript, language: language)
        if mode == .english {
            let chunks = Self.translationChunks(normalized)
            if chunks.count > 1 {
                return await processEnglishChunks(
                    chunks
                )
            }
        }
        return await processSingle(
            transcript: normalized,
            mode: mode,
            signature: signature
        )
    }

    private func processEnglishChunks(
        _ chunks: [String]
    ) async -> DraftProcessingOutcome {
        var outputs: [String] = []
        var generations: [ModelGenerationOutput] = []
        var usedFallback = false
        var totalSeconds = 0.0
        var generationAttempts = 0

        for chunk in chunks {
            let outcome = await processTranslationChunk(chunk)
            outputs.append(outcome.result.outputText)
            if let generation = outcome.generation {
                generations.append(generation)
            }
            usedFallback = usedFallback || outcome.usedFallback
            totalSeconds += outcome.totalSeconds
            generationAttempts += outcome.generationAttempts
        }

        let output = outputs.joined(separator: " ")
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
        _ transcript: String
    ) async -> DraftProcessingOutcome {
        let clock = ContinuousClock()
        let start = clock.now

        do {
            let first = try await Self.generate(
                languageModel,
                prompt: PromptBuilder.translationPrompt(transcript),
                timeout: timeout
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
                timeout: timeout
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
        signature: String
    ) async -> DraftProcessingOutcome {
        let clock = ContinuousClock()
        let start = clock.now
        let intentHint = IntentHintDetector.detect(transcript)
        let prompt = PromptBuilder.processingPrompt(
            transcript: transcript,
            mode: mode,
            signature: signature,
            intentHint: intentHint
        )
        let facts = FactExtractor.hardFacts(from: transcript)
        let extractedRecipient = RecipientExtractor.recipient(from: transcript)

        do {
            let first = try await Self.generate(
                languageModel,
                prompt: prompt,
                timeout: timeout
            )
            if let result = Self.validated(
                first.text,
                source: transcript,
                mode: mode,
                facts: facts
            ) {
                return DraftProcessingOutcome(
                    result: Self.formatted(
                        result,
                        signature: signature,
                        recipient: extractedRecipient
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
                timeout: timeout
            )
            if let result = Self.validated(
                repaired.text,
                source: transcript,
                mode: mode,
                facts: facts
            ) {
                return DraftProcessingOutcome(
                    result: Self.formatted(
                        result,
                        signature: signature,
                        recipient: extractedRecipient
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

        let fallback = DocumentFormatter.format(transcript).plainText
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
        guard let result = try? ProcessingResultValidator.validate(
            data,
            requiredFacts: facts
        ) else {
            return nil
        }
        guard preservesInput(
            result.outputText,
            source: source,
            mode: mode
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
        let output = response.trimmingCharacters(
            in: .whitespacesAndNewlines
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
        let output: String
        if result.intent == .composeEmail {
            output = EmailOutputFormatter.format(
                body: result.outputText,
                recipient: recipient ?? result.email?.recipient,
                signature: signature
            )
        } else {
            output = DocumentFormatter.format(result.outputText).plainText
        }
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
            email: email
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
        timeout: Duration
    ) async throws -> ModelGenerationOutput {
        try await withThrowingTaskGroup(
            of: ModelGenerationOutput.self
        ) { group in
            group.addTask {
                try await model.generate(prompt: prompt)
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
