import Foundation

public struct AudioBenchmarkSample: Codable, Equatable, Sendable {
    public let id: String
    public let suite: String
    public let audioPath: String
    public let verbatimReference: String
    public let mode: VoiceMode
    public let expectedIntent: DraftIntent
    public let requiredFacts: [String]
    public let forbiddenClaims: [String]
    public let semanticGroups: [[String]]
    public let terms: [String]
    public let audioTags: [String]
    public let sourceDataset: String
    public let sourceLicense: String

    public init(
        id: String,
        suite: String,
        audioPath: String,
        verbatimReference: String,
        mode: VoiceMode,
        expectedIntent: DraftIntent,
        requiredFacts: [String],
        forbiddenClaims: [String],
        semanticGroups: [[String]],
        terms: [String],
        audioTags: [String],
        sourceDataset: String,
        sourceLicense: String
    ) {
        self.id = id
        self.suite = suite
        self.audioPath = audioPath
        self.verbatimReference = verbatimReference
        self.mode = mode
        self.expectedIntent = expectedIntent
        self.requiredFacts = requiredFacts
        self.forbiddenClaims = forbiddenClaims
        self.semanticGroups = semanticGroups
        self.terms = terms
        self.audioTags = audioTags
        self.sourceDataset = sourceDataset
        self.sourceLicense = sourceLicense
    }
}

public struct ASRQualityScore: Codable, Equatable, Sendable {
    public let characterErrorRate: Double
    public let wordErrorRate: Double
    public let characterEdits: Int
    public let wordEdits: Int
    public let referenceCharacters: Int
    public let referenceWords: Int
    public let hallucinatedOnEmptyReference: Bool
    public let realtimeFactor: Double

    public init(
        characterErrorRate: Double,
        wordErrorRate: Double,
        characterEdits: Int,
        wordEdits: Int,
        referenceCharacters: Int,
        referenceWords: Int,
        hallucinatedOnEmptyReference: Bool,
        realtimeFactor: Double
    ) {
        self.characterErrorRate = characterErrorRate
        self.wordErrorRate = wordErrorRate
        self.characterEdits = characterEdits
        self.wordEdits = wordEdits
        self.referenceCharacters = referenceCharacters
        self.referenceWords = referenceWords
        self.hallucinatedOnEmptyReference = hallucinatedOnEmptyReference
        self.realtimeFactor = realtimeFactor
    }
}

public enum ASRQualityEvaluator {
    public static func evaluate(
        reference: String,
        hypothesis: String,
        audioDurationSeconds: Double = 0,
        recognitionSeconds: Double = 0
    ) -> ASRQualityScore {
        let referenceCharacters = Array(normalizeForCharacters(reference))
        let hypothesisCharacters = Array(normalizeForCharacters(hypothesis))
        let characterEdits = levenshtein(
            referenceCharacters,
            hypothesisCharacters
        )
        let hallucinated = referenceCharacters.isEmpty
            && !hypothesisCharacters.isEmpty

        let referenceWords = tokenizeWords(reference)
        let hypothesisWords = tokenizeWords(hypothesis)
        let wordEdits = levenshtein(referenceWords, hypothesisWords)

        return ASRQualityScore(
            characterErrorRate: errorRate(
                edits: characterEdits,
                referenceCount: referenceCharacters.count,
                hypothesisCount: hypothesisCharacters.count
            ),
            wordErrorRate: errorRate(
                edits: wordEdits,
                referenceCount: referenceWords.count,
                hypothesisCount: hypothesisWords.count
            ),
            characterEdits: characterEdits,
            wordEdits: wordEdits,
            referenceCharacters: referenceCharacters.count,
            referenceWords: referenceWords.count,
            hallucinatedOnEmptyReference: hallucinated,
            realtimeFactor: audioDurationSeconds > 0
                ? recognitionSeconds / audioDurationSeconds
                : 0
        )
    }

    private static func normalizeForCharacters(_ value: String) -> String {
        value
            .lowercased()
            .replacingOccurrences(
                of: #"[\s，。！？、,.!?:：;；“”"'（）()\-\[\]{}]+"#,
                with: "",
                options: .regularExpression
            )
    }

    private static func tokenizeWords(_ value: String) -> [String] {
        value
            .lowercased()
            .replacingOccurrences(
                of: #"[，。！？、,.!?:：;；“”"'（）()\-\[\]{}]+"#,
                with: " ",
                options: .regularExpression
            )
            .split { $0.isWhitespace }
            .map(String.init)
    }

    private static func errorRate(
        edits: Int,
        referenceCount: Int,
        hypothesisCount: Int
    ) -> Double {
        if referenceCount == 0 {
            return hypothesisCount == 0 ? 0 : 1
        }
        return Double(edits) / Double(referenceCount)
    }

    private static func levenshtein<T: Equatable>(
        _ source: [T],
        _ target: [T]
    ) -> Int {
        guard !source.isEmpty else { return target.count }
        guard !target.isEmpty else { return source.count }

        var previous = Array(0...target.count)
        var current = Array(repeating: 0, count: target.count + 1)

        for sourceIndex in 1...source.count {
            current[0] = sourceIndex
            for targetIndex in 1...target.count {
                let cost = source[sourceIndex - 1] == target[targetIndex - 1]
                    ? 0
                    : 1
                current[targetIndex] = min(
                    previous[targetIndex] + 1,
                    current[targetIndex - 1] + 1,
                    previous[targetIndex - 1] + cost
                )
            }
            swap(&previous, &current)
        }
        return previous[target.count]
    }
}

public struct ProcessingQualityEvaluationV2: Codable, Equatable, Sendable {
    public let passed: Bool
    public let intentMatches: Bool
    public let missingFacts: [String]
    public let forbiddenClaims: [String]
    public let semanticScore: Double
    public let hasExpectedStructure: Bool
    public let languageMatchesMode: Bool

    public init(
        passed: Bool,
        intentMatches: Bool,
        missingFacts: [String],
        forbiddenClaims: [String],
        semanticScore: Double,
        hasExpectedStructure: Bool,
        languageMatchesMode: Bool
    ) {
        self.passed = passed
        self.intentMatches = intentMatches
        self.missingFacts = missingFacts
        self.forbiddenClaims = forbiddenClaims
        self.semanticScore = semanticScore
        self.hasExpectedStructure = hasExpectedStructure
        self.languageMatchesMode = languageMatchesMode
    }
}

public enum ProcessingQualityEvaluatorV2 {
    public static func evaluate(
        _ result: ProcessingResult,
        against sample: AudioBenchmarkSample
    ) -> ProcessingQualityEvaluationV2 {
        let normalized = normalize(result.outputText)
        let missingFacts = sample.requiredFacts
            .filter { !normalized.contains(normalize($0)) }
            .sorted()
        let forbiddenClaims = sample.forbiddenClaims
            .filter { normalized.contains(normalize($0)) }
            .sorted()
        let matchedGroups = sample.semanticGroups.filter { alternatives in
            alternatives.contains { normalized.contains(normalize($0)) }
        }.count
        let semanticScore = sample.semanticGroups.isEmpty
            ? 1
            : Double(matchedGroups) / Double(sample.semanticGroups.count)
        let hasExpectedStructure = sample.expectedIntent != .composeEmail
            || hasEmailStructure(result.outputText)
        let intentMatches = result.intent == sample.expectedIntent
        let languageMatchesMode = sample.mode != .english
            || result.outputText.range(
                of: #"\p{Han}"#,
                options: .regularExpression
            ) == nil

        return ProcessingQualityEvaluationV2(
            passed: intentMatches
                && missingFacts.isEmpty
                && forbiddenClaims.isEmpty
                && semanticScore == 1
                && hasExpectedStructure
                && languageMatchesMode,
            intentMatches: intentMatches,
            missingFacts: missingFacts,
            forbiddenClaims: forbiddenClaims,
            semanticScore: semanticScore,
            hasExpectedStructure: hasExpectedStructure,
            languageMatchesMode: languageMatchesMode
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

public struct QualityBenchmarkRow: Codable, Equatable, Sendable {
    public let sample: AudioBenchmarkSample
    public let asr: ASRQualityScore?
    public let llmFromASR: ProcessingQualityEvaluationV2?
    public let llmOracle: ProcessingQualityEvaluationV2?
    public let recognitionError: String?

    public init(
        sample: AudioBenchmarkSample,
        asr: ASRQualityScore?,
        llmFromASR: ProcessingQualityEvaluationV2?,
        llmOracle: ProcessingQualityEvaluationV2?,
        recognitionError: String?
    ) {
        self.sample = sample
        self.asr = asr
        self.llmFromASR = llmFromASR
        self.llmOracle = llmOracle
        self.recognitionError = recognitionError
    }
}

public struct QualityBenchmarkSummary: Codable, Equatable, Sendable {
    public let sampleCount: Int
    public let recognizedCount: Int
    public let asrCER: Double
    public let asrWER: Double
    public let asrRTFx: Double
    public let asrHallucinationCount: Int
    public let llmFromASRPassRate: Double
    public let llmOraclePassRate: Double

    public init(rows: [QualityBenchmarkRow]) {
        sampleCount = rows.count
        let asrRows = rows.compactMap(\.asr)
        recognizedCount = asrRows.count
        asrCER = Self.average(asrRows.map(\.characterErrorRate))
        asrWER = Self.average(asrRows.map(\.wordErrorRate))
        asrRTFx = Self.average(asrRows.map(\.realtimeFactor))
        asrHallucinationCount = asrRows
            .filter(\.hallucinatedOnEmptyReference)
            .count
        let fromASR = rows.compactMap(\.llmFromASR)
        let oracle = rows.compactMap(\.llmOracle)
        llmFromASRPassRate = Self.passRate(fromASR)
        llmOraclePassRate = Self.passRate(oracle)
    }

    private static func average(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        return values.reduce(0, +) / Double(values.count)
    }

    private static func passRate(
        _ values: [ProcessingQualityEvaluationV2]
    ) -> Double {
        guard !values.isEmpty else { return 0 }
        return Double(values.filter(\.passed).count) / Double(values.count)
    }
}
