import Foundation
import Testing
@testable import LocalVoiceCore

// MARK: - PhoneticSimilarity tests

@Test func phoneticSimilarityAllowsCaseOnlyDifference() {
    #expect(PhoneticSimilarity.isPlausibleCorrection(from: "Deploy", to: "deploy"))
    #expect(PhoneticSimilarity.isPlausibleCorrection(from: "DEPLOY", to: "Deploy"))
}

@Test func phoneticSimilarityAllowsDeployEmploy() {
    // Edit distance = 2, threshold = max(2, 6/3) = 2
    #expect(PhoneticSimilarity.isPlausibleCorrection(from: "employ", to: "deploy"))
    #expect(PhoneticSimilarity.isPlausibleCorrection(from: "deploy", to: "employ"))
}

@Test func phoneticSimilarityAllowsMarchMerge() {
    // Short words (len=5), threshold = max(2, 5-2) = 3, distance = 3
    #expect(PhoneticSimilarity.isPlausibleCorrection(from: "march", to: "merge"))
    #expect(PhoneticSimilarity.isPlausibleCorrection(from: "merge", to: "march"))
}

@Test func phoneticSimilarityAllowsRecordRecode() {
    // Edit distance = 2, threshold = max(2, 6/3) = 2
    #expect(PhoneticSimilarity.isPlausibleCorrection(from: "record", to: "recode"))
}

@Test func phoneticSimilarityAllowsMultiWordReadyIsRedis() {
    // Multi-word: "readyis" vs "redis" = distance 2, threshold = max(2, 7/2) = 3
    #expect(PhoneticSimilarity.isPlausibleCorrection(from: "ready is", to: "Redis"))
}

@Test func phoneticSimilarityRejectsDeployBanana() {
    // Edit distance = 6, threshold = 2
    #expect(!PhoneticSimilarity.isPlausibleCorrection(from: "deploy", to: "banana"))
}

@Test func phoneticSimilarityRejectsTheDeploy() {
    // "the" (3) vs "deploy" (6): maxLen=6, distance >= 5, threshold=2
    #expect(!PhoneticSimilarity.isPlausibleCorrection(from: "the", to: "deploy"))
}

@Test func phoneticSimilarityRejectsChinese() {
    // Chinese ↔ Latin not handled by this layer
    #expect(!PhoneticSimilarity.isPlausibleCorrection(from: "酷伯内特斯", to: "Kubernetes"))
    #expect(!PhoneticSimilarity.isPlausibleCorrection(from: "Kubernetes", to: "酷伯内特斯"))
}

@Test func phoneticSimilarityRejectsEmpty() {
    #expect(!PhoneticSimilarity.isPlausibleCorrection(from: "", to: "deploy"))
    #expect(!PhoneticSimilarity.isPlausibleCorrection(from: "deploy", to: ""))
}

@Test func phoneticKeyCollapsesDuplicates() {
    let key = PhoneticSimilarity.phoneticKey("deploy")
    // d + (e removed) + p + l + (o removed) + y → dply → no adjacent dups → "dply"
    #expect(!key.isEmpty)
    // Key must not contain vowels beyond the first char
    let withoutFirst = key.dropFirst()
    #expect(!withoutFirst.contains("a"))
    #expect(!withoutFirst.contains("e"))
    #expect(!withoutFirst.contains("i"))
    #expect(!withoutFirst.contains("o"))
    #expect(!withoutFirst.contains("u"))
}

@Test func damerauLevenshteinKnownDistances() {
    #expect(PhoneticSimilarity.damerauLevenshtein("deploy", "employ") == 2)
    #expect(PhoneticSimilarity.damerauLevenshtein("kitten", "sitting") == 3)
    #expect(PhoneticSimilarity.damerauLevenshtein("abc", "abc") == 0)
    #expect(PhoneticSimilarity.damerauLevenshtein("", "abc") == 3)
    #expect(PhoneticSimilarity.damerauLevenshtein("abc", "") == 3)
    // Transposition: ab → ba = 1
    #expect(PhoneticSimilarity.damerauLevenshtein("ab", "ba") == 1)
}

// MARK: - CorrectionValidator tests

@Test func correctionValidatorAcceptsEmptyCorrections() {
    let (text, accepted, reverted) = CorrectionValidator.apply(
        corrections: [],
        to: "今天我们要 deploy 新版本",
        source: "今天我们要 employ 新版本",
        protectedFacts: []
    )
    #expect(text == "今天我们要 deploy 新版本")
    #expect(accepted.isEmpty)
    #expect(reverted.isEmpty)
}

@Test func correctionValidatorAcceptsValidNearSoundCorrection() {
    let correction = TermCorrection(from: "employ", to: "deploy")
    let (text, accepted, reverted) = CorrectionValidator.apply(
        corrections: [correction],
        to: "今天我们要 deploy 新版本",
        source: "今天我们要 employ 新版本",
        protectedFacts: []
    )
    #expect(text == "今天我们要 deploy 新版本")
    #expect(accepted == [correction])
    #expect(reverted.isEmpty)
}

@Test func correctionValidatorRevertsWhenFromNotInSource() {
    let correction = TermCorrection(from: "phantom", to: "deploy")
    let (text, accepted, reverted) = CorrectionValidator.apply(
        corrections: [correction],
        to: "今天我们要 deploy 新版本",
        source: "今天我们要 employ 新版本",
        protectedFacts: []
    )
    // "phantom" not in source → revert: "deploy" → "phantom"
    #expect(text.contains("phantom"))
    #expect(accepted.isEmpty)
    #expect(reverted == [correction])
}

@Test func correctionValidatorRevertsWhenFromOverlapsHardFact() {
    // "employ" is a substring of "employ.example.com" which is a protected fact
    let correction = TermCorrection(from: "employ", to: "deploy")
    let (text, _, reverted) = CorrectionValidator.apply(
        corrections: [correction],
        to: "visit deploy.example.com",
        source: "visit employ.example.com",
        protectedFacts: ["employ.example.com"]
    )
    #expect(text.contains("employ") || !reverted.isEmpty)
    #expect(reverted.contains(correction))
}

@Test func correctionValidatorRevertsWhenPhoneticsNotSimilar() {
    let correction = TermCorrection(from: "deploy", to: "banana")
    let (text, accepted, reverted) = CorrectionValidator.apply(
        corrections: [correction],
        to: "今天 banana 新版本",
        source: "今天 deploy 新版本",
        protectedFacts: []
    )
    #expect(text.contains("deploy") || text.contains("banana"))
    #expect(accepted.isEmpty)
    #expect(reverted == [correction])
}

@Test func correctionValidatorRevertsWhenToIsEmpty() {
    let correction = TermCorrection(from: "employ", to: "")
    let (_, accepted, reverted) = CorrectionValidator.apply(
        corrections: [correction],
        to: "今天我们要 deploy 新版本",
        source: "今天我们要 employ 新版本",
        protectedFacts: []
    )
    #expect(accepted.isEmpty)
    #expect(reverted == [correction])
}

@Test func correctionValidatorRevertsWhenToContainsNewline() {
    let correction = TermCorrection(from: "employ", to: "dep\nloy")
    let (_, accepted, reverted) = CorrectionValidator.apply(
        corrections: [correction],
        to: "dep\nloy 新版本",
        source: "employ 新版本",
        protectedFacts: []
    )
    #expect(accepted.isEmpty)
    #expect(reverted == [correction])
}

@Test func correctionValidatorRevertsAllWhenExceedsMaxCount() {
    // 9 corrections > max 8 → all reverted
    let corrections = (1...9).map { i in
        TermCorrection(from: "word\(i)", to: "word\(i)x")
    }
    let output = corrections.map(\.to).joined(separator: " ")
    let source = corrections.map(\.from).joined(separator: " ")
    let (_, accepted, reverted) = CorrectionValidator.apply(
        corrections: corrections,
        to: output,
        source: source,
        protectedFacts: []
    )
    #expect(accepted.isEmpty)
    #expect(reverted.count == 9)
}

@Test func correctionValidatorPartiallyAcceptsValidAndRejectsInvalid() {
    let valid = TermCorrection(from: "employ", to: "deploy")
    let invalid = TermCorrection(from: "phantom", to: "banana")
    let source = "今天 employ 版本"
    let output = "今天 deploy 版本 banana"
    let (text, accepted, reverted) = CorrectionValidator.apply(
        corrections: [valid, invalid],
        to: output,
        source: source,
        protectedFacts: []
    )
    #expect(accepted == [valid])
    #expect(reverted == [invalid])
    // "banana" reverted to "phantom" in text
    #expect(text.contains("phantom"))
    // "deploy" (the valid correction) is preserved
    #expect(text.contains("deploy"))
}

@Test func correctionValidatorWordBoundaryDoesNotReplaceSubstrings() {
    // When reverting an invalid correction, word boundary must prevent "merged" → "marched".
    // Make the correction invalid by having `from` absent from source (rule 1).
    let correction = TermCorrection(from: "march", to: "merge")
    let output = "请把这个分支 merged 进去"
    let source = "请把这个分支 进去"  // "march" not in source → invalid

    let (text, accepted, reverted) = CorrectionValidator.apply(
        corrections: [correction],
        to: output,
        source: source,
        protectedFacts: []
    )

    // Correction reverted because "march" absent from source
    #expect(accepted.isEmpty)
    #expect(reverted == [correction])
    // Revert tries to replace "merge"→"march" in output.
    // "merged" must not become "marched" — word boundary protects it.
    #expect(text.contains("merged"))
    #expect(!text.contains("marched"))
}
