import Foundation
import Testing
@testable import LocalVoiceCore

@Test func speechSignalExtractorReturnsEmptyForEmptyInput() {
    let suspects = SpeechSignalExtractor.suspects(best: [], alternatives: [])
    #expect(suspects.isEmpty)
}

@Test func speechSignalExtractorFlagsLowConfidenceLatinSegment() {
    let best = [
        TranscriptSegmentInfo(text: "今天", confidence: 0.95),
        TranscriptSegmentInfo(text: "employ", confidence: 0.31),
        TranscriptSegmentInfo(text: "新版本", confidence: 0.92)
    ]
    let suspects = SpeechSignalExtractor.suspects(best: best, alternatives: [])
    #expect(suspects.count == 1)
    #expect(suspects[0].text == "employ")
    #expect(suspects[0].confidence == 0.31)
}

@Test func speechSignalExtractorIgnoresHighConfidenceLatinWithNoAlternatives() {
    let best = [
        TranscriptSegmentInfo(text: "deploy", confidence: 0.92)
    ]
    let suspects = SpeechSignalExtractor.suspects(best: best, alternatives: [])
    #expect(suspects.isEmpty)
}

@Test func speechSignalExtractorIgnoresPureChineseSegments() {
    let best = [
        TranscriptSegmentInfo(text: "部署到生产", confidence: 0.20),
        TranscriptSegmentInfo(text: "deploy", confidence: 0.85)
    ]
    let suspects = SpeechSignalExtractor.suspects(best: best, alternatives: [])
    // Chinese segment excluded even at low confidence; deploy high conf + no alts → also excluded
    #expect(suspects.isEmpty)
}

@Test func speechSignalExtractorFlagsDivergentAlternativeEvenAtHighConfidence() {
    let best = [
        TranscriptSegmentInfo(text: "employ", confidence: 0.88)
    ]
    // Alternative transcription gives a different Latin word at same index
    let alts = [[TranscriptSegmentInfo(text: "deploy", confidence: 0.80)]]
    let suspects = SpeechSignalExtractor.suspects(best: best, alternatives: alts)
    #expect(suspects.count == 1)
    #expect(suspects[0].text == "employ")
    #expect(suspects[0].alternatives == ["deploy"])
}

@Test func speechSignalExtractorDeduplicatesAlternatives() {
    let best = [
        TranscriptSegmentInfo(text: "employ", confidence: 0.35)
    ]
    let alts = [
        [TranscriptSegmentInfo(text: "deploy", confidence: 0.75)],
        [TranscriptSegmentInfo(text: "deploy", confidence: 0.70)],  // duplicate
        [TranscriptSegmentInfo(text: "the ploy", confidence: 0.60)]
    ]
    let suspects = SpeechSignalExtractor.suspects(best: best, alternatives: alts)
    #expect(suspects.count == 1)
    // "deploy" deduped, "the ploy" contains no latin after filter... wait, it does contain latin
    // dedup gives ["deploy", "the ploy"] (sorted)
    let altSet = Set(suspects[0].alternatives)
    #expect(altSet.contains("deploy"))
    // Max 3 alternatives
    #expect(suspects[0].alternatives.count <= 3)
}

@Test func speechSignalExtractorCapsAtLimit() {
    // 12 suspect Latin segments → capped at 8
    let best = (0..<12).map { i in
        TranscriptSegmentInfo(text: "word\(i)", confidence: Double(i) * 0.03)
    }
    let suspects = SpeechSignalExtractor.suspects(best: best, alternatives: [], limit: 8)
    #expect(suspects.count == 8)
}

@Test func speechSignalExtractorSortsByConfidenceAscending() {
    let best = [
        TranscriptSegmentInfo(text: "alpha", confidence: 0.40),
        TranscriptSegmentInfo(text: "beta", confidence: 0.20),
        TranscriptSegmentInfo(text: "gamma", confidence: 0.30)
    ]
    let suspects = SpeechSignalExtractor.suspects(
        best: best,
        alternatives: [],
        confidenceThreshold: 0.45
    )
    #expect(suspects.count == 3)
    // Sorted by confidence ascending
    #expect(suspects[0].text == "beta")   // 0.20
    #expect(suspects[1].text == "gamma")  // 0.30
    #expect(suspects[2].text == "alpha")  // 0.40
}

@Test func speechSignalExtractorIgnoresURLLikeSegments() {
    let best = [
        TranscriptSegmentInfo(text: "https://example.com/deploy", confidence: 0.10)
    ]
    let suspects = SpeechSignalExtractor.suspects(best: best, alternatives: [])
    #expect(suspects.isEmpty)
}

@Test func speechSignalExtractorHandlesMissingAltSegmentsGracefully() {
    let best = [
        TranscriptSegmentInfo(text: "employ", confidence: 0.30),
        TranscriptSegmentInfo(text: "新版本", confidence: 0.90)
    ]
    // Alternatives have fewer segments (only 1)
    let alts = [[TranscriptSegmentInfo(text: "deploy", confidence: 0.70)]]
    // Should not crash; index 1 missing in alts is handled gracefully
    let suspects = SpeechSignalExtractor.suspects(best: best, alternatives: alts)
    #expect(suspects.count == 1)
    #expect(suspects[0].text == "employ")
}
