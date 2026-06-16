import Foundation

public enum ProfileEvidenceKind: String, Codable, Equatable, Sendable {
    case finalOutputTerm
    case rawTranscriptAlias
    case modelCorrection
    case asrSuspect
    case seedGlossaryMatch
    case negativeCorrection
}

public enum ProfileEvidenceSource: String, Codable, Equatable, Sendable {
    case finalOutput
    case rawFinalDiff
    case modelCorrection
    case asrSuspect
    case explicitInstruction
    case seedGlossary
}

public struct ProfileEvidence: Codable, Equatable, Sendable {
    public let sessionId: String
    public let kind: ProfileEvidenceKind
    public let surface: String
    public let canonical: String
    public let contextBefore: String
    public let contextAfter: String
    public let source: ProfileEvidenceSource
    public let weight: Double

    public init(
        sessionId: String,
        kind: ProfileEvidenceKind,
        surface: String,
        canonical: String,
        contextBefore: String = "",
        contextAfter: String = "",
        source: ProfileEvidenceSource,
        weight: Double
    ) {
        self.sessionId = sessionId
        self.kind = kind
        self.surface = surface
        self.canonical = canonical
        self.contextBefore = contextBefore
        self.contextAfter = contextAfter
        self.source = source
        self.weight = weight
    }
}

public enum ProfileEvidenceExtractor {
    public static func extract(from session: SessionHistoryRecord) -> [ProfileEvidence] {
        var evidence: [ProfileEvidence] = []

        evidence.append(contentsOf: finalOutputTermEvidence(from: session))
        evidence.append(contentsOf: correctionEvidence(from: session))
        evidence.append(contentsOf: aliasEvidence(from: session))
        evidence.append(contentsOf: suspectEvidence(from: session))
        evidence.append(contentsOf: negativeCorrectionEvidence(from: session))

        return dedupe(evidence)
    }

    private static func finalOutputTermEvidence(
        from session: SessionHistoryRecord
    ) -> [ProfileEvidence] {
        ProfileExtractor.extractTermCandidates(from: session.finalOutput).map {
            ProfileEvidence(
                sessionId: session.id,
                kind: .finalOutputTerm,
                surface: $0,
                canonical: $0,
                source: .finalOutput,
                weight: session.usedFallback ? 0.5 : 1.0
            )
        }
    }

    private static func correctionEvidence(
        from session: SessionHistoryRecord
    ) -> [ProfileEvidence] {
        session.corrections.map {
            ProfileEvidence(
                sessionId: session.id,
                kind: .modelCorrection,
                surface: $0.from,
                canonical: $0.to,
                source: .modelCorrection,
                weight: session.usedFallback ? 0.5 : 1.0
            )
        }
    }

    private static func aliasEvidence(
        from session: SessionHistoryRecord
    ) -> [ProfileEvidence] {
        let terms = ProfileExtractor.extractTermCandidates(from: session.finalOutput)
        guard !terms.isEmpty else { return [] }

        let rawHanRuns = hanAliasCandidates(in: session.rawTranscript)
            .filter { !session.finalOutput.contains($0) && $0.count >= 3 }
        guard !rawHanRuns.isEmpty else { return [] }

        var output: [ProfileEvidence] = []
        for term in terms {
            guard SeedGlossary.terms.contains(term)
                    || term.contains(where: { $0.isUppercase })
                    || term.contains(where: { $0.isNumber }) else {
                continue
            }
            for alias in rawHanRuns {
                output.append(
                    ProfileEvidence(
                        sessionId: session.id,
                        kind: .rawTranscriptAlias,
                        surface: alias,
                        canonical: term,
                        contextBefore: context(before: alias, in: session.rawTranscript),
                        contextAfter: context(after: alias, in: session.rawTranscript),
                        source: .rawFinalDiff,
                        weight: session.usedFallback ? 0.35 : 0.7
                    )
                )
            }
        }
        return output
    }

    private static func suspectEvidence(
        from session: SessionHistoryRecord
    ) -> [ProfileEvidence] {
        session.suspects.flatMap { suspect in
            suspect.alternatives.map {
                ProfileEvidence(
                    sessionId: session.id,
                    kind: .asrSuspect,
                    surface: suspect.text,
                    canonical: $0,
                    source: .asrSuspect,
                    weight: 0.2
                )
            }
        }
    }

    private static func negativeCorrectionEvidence(
        from session: SessionHistoryRecord
    ) -> [ProfileEvidence] {
        let pattern = #"(?i)(?:把|将)[^A-Za-z]{0,12}([A-Za-z][A-Za-z0-9\-]*)\s*(?:的地方)?\s*(?:改成|改为|换成)\s*([A-Za-z][A-Za-z0-9\-]*)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(session.finalOutput.startIndex..., in: session.finalOutput)
        return regex.matches(in: session.finalOutput, range: range).compactMap { match in
            guard match.numberOfRanges >= 3,
                  let fromRange = Range(match.range(at: 1), in: session.finalOutput),
                  let toRange = Range(match.range(at: 2), in: session.finalOutput) else {
                return nil
            }
            return ProfileEvidence(
                sessionId: session.id,
                kind: .negativeCorrection,
                surface: String(session.finalOutput[fromRange]),
                canonical: String(session.finalOutput[toRange]),
                source: .explicitInstruction,
                weight: 1.0
            )
        }
    }

    private static func dedupe(_ evidence: [ProfileEvidence]) -> [ProfileEvidence] {
        var seen = Set<String>()
        return evidence.filter {
            let key = "\($0.sessionId)|\($0.kind.rawValue)|\($0.surface)|\($0.canonical)"
            return seen.insert(key).inserted
        }
    }

    private static func hanRuns(in text: String) -> [String] {
        var runs: [String] = []
        var current = ""
        for scalar in text.unicodeScalars {
            if isHan(scalar) {
                current.append(Character(scalar))
            } else {
                if !current.isEmpty { runs.append(current) }
                current = ""
            }
        }
        if !current.isEmpty { runs.append(current) }
        return runs
    }

    private static func hanAliasCandidates(in text: String) -> [String] {
        var candidates = Set<String>()
        for run in hanRuns(in: text) {
            candidates.insert(run)
            let chars = Array(run)
            guard chars.count >= 3 else { continue }
            let maxLength = min(8, chars.count)
            for length in 3...maxLength {
                for start in 0...(chars.count - length) {
                    candidates.insert(String(chars[start..<(start + length)]))
                }
            }
        }
        return Array(candidates).sorted { $0.count > $1.count }
    }

    private static func context(before surface: String, in text: String) -> String {
        guard let range = text.range(of: surface) else { return "" }
        return String(text[..<range.lowerBound].suffix(8))
    }

    private static func context(after surface: String, in text: String) -> String {
        guard let range = text.range(of: surface) else { return "" }
        return String(text[range.upperBound...].prefix(8))
    }

    private static func isHan(_ scalar: Unicode.Scalar) -> Bool {
        (0x4E00...0x9FFF).contains(scalar.value)
            || (0x3400...0x4DBF).contains(scalar.value)
    }
}
