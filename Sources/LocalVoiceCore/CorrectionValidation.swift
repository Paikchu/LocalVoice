import Foundation

// MARK: - TermCorrection

public struct TermCorrection: Codable, Equatable, Sendable {
    public let from: String
    public let to: String

    public init(from: String, to: String) {
        self.from = from
        self.to = to
    }
}

// MARK: - PhoneticSimilarity

public enum PhoneticSimilarity {

    /// Returns true if `from` and `to` are a plausible near-sound correction pair.
    ///
    /// Three paths, checked in order:
    ///  1. Case-only difference → always allowed.
    ///  2. Either string contains CJK → not handled by this layer (returns false).
    ///  3. Multi-word `from` (e.g. "ready is" → "Redis") → compressed edit distance.
    ///  4. Phonetic key match (consonant skeleton).
    ///  5. Damerau-Levenshtein edit distance with length-aware threshold.
    public static func isPlausibleCorrection(from: String, to: String) -> Bool {
        guard !from.isEmpty, !to.isEmpty else { return false }

        // Case-only difference
        if from.lowercased() == to.lowercased() { return true }

        // Chinese characters: not handled by this layer
        if from.unicodeScalars.contains(where: isHanScalar)
            || to.unicodeScalars.contains(where: isHanScalar) {
            return false
        }

        let fromLower = from.lowercased()
        let toLower = to.lowercased()

        // Multi-word from ("ready is" → "Redis")
        if fromLower.contains(" ") {
            let compressed = fromLower.replacingOccurrences(of: " ", with: "")
            let maxLen = max(compressed.count, toLower.count)
            let threshold = max(2, maxLen / 2)
            return damerauLevenshtein(compressed, toLower) <= threshold
        }

        // Phonetic key match
        if phoneticKey(fromLower) == phoneticKey(toLower) { return true }

        // Edit distance with length-aware threshold
        // Short words (len ≤ 5): threshold = max(2, len - 2) to allow e.g. march/merge (dist 3)
        // Longer words: threshold = max(2, len / 3)
        let maxLen = max(fromLower.count, toLower.count)
        let threshold = maxLen <= 5 ? max(2, maxLen - 2) : max(2, maxLen / 3)
        return damerauLevenshtein(fromLower, toLower) <= threshold
    }

    // MARK: Internal (accessible from tests)

    static func phoneticKey(_ word: String) -> String {
        var s = word.lowercased()
        // Multi-char substitutions first (order matters)
        for (pat, rep) in [("ph", "f"), ("ck", "k"), ("qu", "k"), ("wr", "r"), ("kn", "n")] {
            s = s.replacingOccurrences(of: pat, with: rep)
        }
        // Single-char: c → k, x → ks
        s = s.replacingOccurrences(of: "c", with: "k")
        s = s.replacingOccurrences(of: "x", with: "ks")

        // Strip vowels except the very first character
        var result = ""
        for (i, ch) in s.enumerated() {
            if i == 0 || !"aeiou".contains(ch) {
                result.append(ch)
            }
        }

        // Collapse adjacent duplicate consonants
        var deduped = ""
        for ch in result where deduped.last != ch {
            deduped.append(ch)
        }
        return deduped
    }

    static func damerauLevenshtein(_ a: String, _ b: String) -> Int {
        let aArr = Array(a), bArr = Array(b)
        let m = aArr.count, n = bArr.count
        if m == 0 { return n }
        if n == 0 { return m }

        var d = [[Int]](repeating: [Int](repeating: 0, count: n + 1), count: m + 1)
        for i in 0...m { d[i][0] = i }
        for j in 0...n { d[0][j] = j }

        for i in 1...m {
            for j in 1...n {
                let cost = aArr[i - 1] == bArr[j - 1] ? 0 : 1
                d[i][j] = Swift.min(
                    d[i - 1][j] + 1,
                    Swift.min(d[i][j - 1] + 1, d[i - 1][j - 1] + cost)
                )
                // Transposition
                if i > 1, j > 1,
                   aArr[i - 1] == bArr[j - 2],
                   aArr[i - 2] == bArr[j - 1] {
                    d[i][j] = Swift.min(d[i][j], d[i - 2][j - 2] + cost)
                }
            }
        }
        return d[m][n]
    }

    private static func isHanScalar(_ scalar: Unicode.Scalar) -> Bool {
        (0x4E00...0x9FFF).contains(scalar.value)
            || (0x3400...0x4DBF).contains(scalar.value)
            || (0x20000...0x2A6DF).contains(scalar.value)
    }
}

// MARK: - CorrectionValidator

public enum CorrectionValidator {

    /// Apply model-declared corrections to `output`.
    ///
    /// Each correction is validated against five rules:
    ///  1. `from` must appear in the source transcript (case-insensitive).
    ///  2. `from` must not overlap with any hard fact (URL, code, amount, time).
    ///  3. `from`/`to` must be phonetically similar.
    ///  4. Total corrections ≤ `maxCorrections` (all reverted if exceeded).
    ///  5. `to` must be non-empty, single-line, and ≤ 40 characters.
    ///
    /// Invalid corrections are reverted in the text (replaced back to `from`).
    /// Worst case: all reverted → text unchanged from what would have been without model correction.
    ///
    /// - Returns: (corrected text, accepted corrections, reverted corrections)
    public static func apply(
        corrections: [TermCorrection],
        to output: String,
        source: String,
        protectedFacts: [String],
        maxCorrections: Int = 8
    ) -> (text: String, accepted: [TermCorrection], reverted: [TermCorrection]) {
        guard !corrections.isEmpty else { return (output, [], []) }

        // Hard limit: revert all if exceeded
        guard corrections.count <= maxCorrections else {
            return (revertAll(corrections, in: output), [], corrections)
        }

        var text = output
        var accepted: [TermCorrection] = []
        var reverted: [TermCorrection] = []

        for correction in corrections {
            if isValid(correction, source: source, protectedFacts: protectedFacts) {
                accepted.append(correction)
            } else {
                text = revertOccurrences(of: correction.to, with: correction.from, in: text)
                reverted.append(correction)
            }
        }

        return (text, accepted, reverted)
    }

    // MARK: Private

    private static func isValid(
        _ correction: TermCorrection,
        source: String,
        protectedFacts: [String]
    ) -> Bool {
        let from = correction.from
        let to = correction.to

        // Rule 5: sanity
        guard !to.isEmpty, !to.contains("\n"), to.count <= 40 else { return false }

        // Rule 1: `from` must appear in source
        guard source.range(of: from, options: .caseInsensitive) != nil else { return false }

        // Rule 2: `from` must not overlap any hard fact
        for fact in protectedFacts where !fact.isEmpty {
            if from.range(of: fact, options: .caseInsensitive) != nil
                || fact.range(of: from, options: .caseInsensitive) != nil {
                return false
            }
        }

        // Rule 3: phonetic similarity
        guard PhoneticSimilarity.isPlausibleCorrection(from: from, to: to) else { return false }

        return true
    }

    private static func revertAll(_ corrections: [TermCorrection], in text: String) -> String {
        corrections.reduce(text) { t, c in
            revertOccurrences(of: c.to, with: c.from, in: t)
        }
    }

    /// Replace all word-boundary occurrences of `target` with `original` (case-insensitive match).
    private static func revertOccurrences(
        of target: String,
        with original: String,
        in text: String
    ) -> String {
        let escaped = NSRegularExpression.escapedPattern(for: target)
        // (?<!\w) and (?!\w) provide ASCII word boundaries, which work correctly
        // when the English word is adjacent to CJK characters (CJK is not \w).
        let pattern = "(?i)(?<![\\w])(?:\(escaped))(?![\\w])"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let template = NSRegularExpression.escapedTemplate(for: original)
        return regex.stringByReplacingMatches(
            in: text,
            range: NSRange(text.startIndex..., in: text),
            withTemplate: template
        )
    }
}
