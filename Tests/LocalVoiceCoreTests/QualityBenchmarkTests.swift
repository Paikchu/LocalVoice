import Foundation
import Testing
@testable import LocalVoiceCore

@Test func audioManifestDecodesJSONLine() throws {
    let line = """
    {"id":"fleurs-smoke-001","suite":"smoke","audioPath":"benchmark-data/fleurs-zh_cn/audio/001.wav","verbatimReference":"今天开始测试","mode":"dictation","expectedIntent":"plainText","requiredFacts":["今天"],"forbiddenClaims":["明天"],"semanticGroups":[["开始测试"]],"terms":["LocalVoice"],"audioTags":["public"],"sourceDataset":"google/fleurs zh_cn","sourceLicense":"CC-BY-4.0"}
    """

    let sample = try JSONDecoder().decode(
        AudioBenchmarkSample.self,
        from: Data(line.utf8)
    )

    #expect(sample.id == "fleurs-smoke-001")
    #expect(sample.mode == .dictation)
    #expect(sample.expectedIntent == .plainText)
    #expect(sample.requiredFacts == ["今天"])
    #expect(sample.forbiddenClaims == ["明天"])
    #expect(sample.semanticGroups == [["开始测试"]])
}

@Test func characterErrorRateNormalizesChinesePunctuation() {
    let score = ASRQualityEvaluator.evaluate(
        reference: "今天开始测试",
        hypothesis: "今天，开始测试。"
    )

    #expect(score.characterErrorRate == 0)
    #expect(score.characterEdits == 0)
}

@Test func wordErrorRateCountsEnglishWordSubstitution() {
    let score = ASRQualityEvaluator.evaluate(
        reference: "deploy to staging",
        hypothesis: "deploy to production"
    )

    #expect(score.wordErrorRate == 1.0 / 3.0)
    #expect(score.wordEdits == 1)
}

@Test func emptyReferenceDetectsHallucinatedTranscript() {
    let score = ASRQualityEvaluator.evaluate(
        reference: "",
        hypothesis: "你好"
    )

    #expect(score.hallucinatedOnEmptyReference)
    #expect(score.characterErrorRate == 1)
}

@Test func processingQualityV2RejectsForbiddenClaims() {
    let sample = AudioBenchmarkSample(
        id: "case-001",
        suite: "smoke",
        audioPath: "audio.wav",
        verbatimReference: "项目还在测试",
        mode: .dictation,
        expectedIntent: .plainText,
        requiredFacts: ["测试"],
        forbiddenClaims: ["已经上线"],
        semanticGroups: [["测试"]],
        terms: [],
        audioTags: [],
        sourceDataset: "fixture",
        sourceLicense: "test"
    )
    let result = ProcessingResult(
        intent: .plainText,
        confidence: 1,
        outputText: "项目还在测试，但已经上线。",
        email: nil
    )

    let evaluation = ProcessingQualityEvaluatorV2.evaluate(
        result,
        against: sample
    )

    #expect(!evaluation.passed)
    #expect(evaluation.forbiddenClaims == ["已经上线"])
}

@Test func benchmarkSummarySeparatesAsrAndOraclePaths() {
    let rows = [
        QualityBenchmarkRow(
            sample: .fixture(id: "one"),
            asr: ASRQualityScore(
                characterErrorRate: 0,
                wordErrorRate: 0,
                characterEdits: 0,
                wordEdits: 0,
                referenceCharacters: 4,
                referenceWords: 1,
                hallucinatedOnEmptyReference: false,
                realtimeFactor: 0.4
            ),
            llmFromASR: .fixture(passed: false),
            llmOracle: .fixture(passed: true),
            recognitionError: nil
        )
    ]

    let summary = QualityBenchmarkSummary(rows: rows)

    #expect(summary.sampleCount == 1)
    #expect(summary.asrCER == 0)
    #expect(summary.llmFromASRPassRate == 0)
    #expect(summary.llmOraclePassRate == 1)
}

@Test func qualityBenchTargetUsesFoundationModelsBackend() throws {
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let project = try String(
        contentsOf: root.appendingPathComponent("project.yml"),
        encoding: .utf8
    )
    let target = project.components(separatedBy: "  LocalVoiceQualityBench:")
        .dropFirst()
        .first ?? ""

    #expect(target.contains("Sources/LocalVoiceApp/FoundationModelBackend.swift"))
    #expect(target.contains("FoundationModels.framework"))
}

private extension AudioBenchmarkSample {
    static func fixture(id: String) -> Self {
        Self(
            id: id,
            suite: "smoke",
            audioPath: "audio.wav",
            verbatimReference: "今天测试",
            mode: .dictation,
            expectedIntent: .plainText,
            requiredFacts: ["测试"],
            forbiddenClaims: [],
            semanticGroups: [["测试"]],
            terms: [],
            audioTags: [],
            sourceDataset: "fixture",
            sourceLicense: "test"
        )
    }
}

private extension ProcessingQualityEvaluationV2 {
    static func fixture(passed: Bool) -> Self {
        Self(
            passed: passed,
            intentMatches: true,
            missingFacts: [],
            forbiddenClaims: [],
            semanticScore: 1,
            hasExpectedStructure: true,
            languageMatchesMode: true
        )
    }
}
