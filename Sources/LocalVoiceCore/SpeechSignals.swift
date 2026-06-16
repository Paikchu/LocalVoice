import Foundation

// MARK: - Value types for ASR signal

/// One segment from a speech recognition transcription.
public struct TranscriptSegmentInfo: Codable, Equatable, Sendable {
    public let text: String
    /// Per-segment confidence score in [0, 1]. 0 when unavailable.
    public let confidence: Double

    public init(text: String, confidence: Double) {
        self.text = text
        self.confidence = confidence
    }
}

/// A segment span that is likely a near-sound mis-recognition.
/// Passed to the LLM as evidence when contextual correction is applied.
public struct SuspectSpan: Codable, Equatable, Sendable {
    /// The text as it appears in the best transcription.
    public let text: String
    /// Confidence score from the recognizer. Lower means more uncertain.
    public let confidence: Double
    /// Up to three distinct Latin-text alternatives from n-best transcriptions.
    public let alternatives: [String]

    public init(text: String, confidence: Double, alternatives: [String] = []) {
        self.text = text
        self.confidence = confidence
        self.alternatives = alternatives
    }
}

// MARK: - SpeechSignalExtractor

public enum SpeechSignalExtractor {

    private static let urlRegex: NSRegularExpression? = try? NSRegularExpression(
        pattern: #"https?://[A-Za-z0-9._~:/?\[\]@!$&'()*+,;=%#-]+"#
    )

    /// Extract suspect spans from a final ASR result.
    ///
    /// A segment becomes a suspect if it contains Latin characters AND either:
    /// - Its confidence is below `confidenceThreshold`, OR
    /// - N-best alternatives disagree on the Latin text at that position.
    ///
    /// Pure Chinese segments and URL-like segments are never included.
    /// Results are sorted by confidence ascending (most uncertain first)
    /// and capped at `limit`.
    ///
    /// Returns `[]` when no signal is available (e.g. recognizer returned only one
    /// transcription, or all segments are high-confidence Chinese). In that case the
    /// prompt still includes the general correction rules, so the model can still
    /// do contextual correction without explicit evidence.
    public static func suspects(
        best: [TranscriptSegmentInfo],
        alternatives: [[TranscriptSegmentInfo]],
        confidenceThreshold: Double = 0.45,
        limit: Int = 8
    ) -> [SuspectSpan] {
        guard !best.isEmpty else { return [] }

        var spans: [SuspectSpan] = []

        for (index, segment) in best.enumerated() {
            guard containsLatin(segment.text), !isURLLike(segment.text) else { continue }

            // Collect differing Latin alternatives at the same position index
            let divergent = alternatives.compactMap { altSegs -> String? in
                guard index < altSegs.count else { return nil }
                let alt = altSegs[index].text
                guard alt != segment.text, containsLatin(alt), !isURLLike(alt) else { return nil }
                return alt
            }
            let deduped = Array(Set(divergent)).sorted().prefix(3)

            let isLowConf = segment.confidence < confidenceThreshold
            let hasDivergence = !deduped.isEmpty

            if isLowConf || hasDivergence {
                spans.append(SuspectSpan(
                    text: segment.text,
                    confidence: segment.confidence,
                    alternatives: Array(deduped)
                ))
            }
        }

        spans.sort { $0.confidence < $1.confidence }
        return Array(spans.prefix(limit))
    }

    // MARK: Private helpers

    private static func containsLatin(_ text: String) -> Bool {
        text.unicodeScalars.contains {
            (0x41...0x5A).contains($0.value) || (0x61...0x7A).contains($0.value)
        }
    }

    private static func isURLLike(_ text: String) -> Bool {
        guard let re = urlRegex else { return false }
        return re.firstMatch(
            in: text,
            range: NSRange(text.startIndex..., in: text)
        ) != nil
    }
}
