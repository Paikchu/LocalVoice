import Foundation

public struct ProfileTermProposal: Codable, Equatable, Sendable {
    public let canonical: String
    public let surfaces: [String]
    public let aliases: [String]
    public let domain: String?
    public let scope: ProfileScope
    public let confidence: Double
    public let evidenceSessionIds: [String]

    public init(
        canonical: String,
        surfaces: [String] = [],
        aliases: [String] = [],
        domain: String? = nil,
        scope: ProfileScope = .technicalTerm,
        confidence: Double,
        evidenceSessionIds: [String]
    ) {
        self.canonical = canonical
        self.surfaces = surfaces
        self.aliases = aliases
        self.domain = domain
        self.scope = scope
        self.confidence = confidence
        self.evidenceSessionIds = evidenceSessionIds
    }
}

public struct ProfileCorrectionProposal: Codable, Equatable, Sendable {
    public let from: String
    public let to: String
    public let context: String
    public let scope: ProfileScope
    public let confidence: Double
    public let evidenceSessionIds: [String]

    public init(
        from: String,
        to: String,
        context: String,
        scope: ProfileScope,
        confidence: Double,
        evidenceSessionIds: [String]
    ) {
        self.from = from
        self.to = to
        self.context = context
        self.scope = scope
        self.confidence = confidence
        self.evidenceSessionIds = evidenceSessionIds
    }
}

public struct ProfileAnalysisProposal: Codable, Equatable, Sendable {
    public let terms: [ProfileTermProposal]
    public let commonCorrections: [ProfileCorrectionProposal]

    public init(
        terms: [ProfileTermProposal] = [],
        commonCorrections: [ProfileCorrectionProposal] = []
    ) {
        self.terms = terms
        self.commonCorrections = commonCorrections
    }
}

public enum ProfileAnalysisMerger {
    public static func merge(
        _ proposal: ProfileAnalysisProposal,
        evidence: [ProfileEvidence],
        into profile: inout UserProfile,
        now: Date = Date()
    ) {
        mergeTerms(proposal.terms, evidence: evidence, into: &profile, now: now)
        mergeCorrections(
            proposal.commonCorrections,
            evidence: evidence,
            into: &profile,
            now: now
        )
        enforceLimits(&profile)
    }

    private static func mergeTerms(
        _ terms: [ProfileTermProposal],
        evidence: [ProfileEvidence],
        into profile: inout UserProfile,
        now: Date
    ) {
        for term in terms where term.confidence >= 0.75 {
            let termEvidence = evidence.filter {
                term.evidenceSessionIds.contains($0.sessionId)
                    && ($0.canonical.caseInsensitiveCompare(term.canonical) == .orderedSame)
            }
            let outputSessions = uniqueSessions(
                termEvidence.filter { $0.kind == .finalOutputTerm || $0.kind == .rawTranscriptAlias }
            )

            let hasSeedStrongEvidence = SeedGlossary.terms.contains(term.canonical)
                && !outputSessions.isEmpty
            guard outputSessions.count >= 2 || hasSeedStrongEvidence else { continue }

            upsertGlossaryTerm(
                term.canonical,
                surfaces: term.surfaces,
                into: &profile,
                now: now
            )

            for alias in term.aliases {
                let aliasEvidence = termEvidence.filter {
                    $0.kind == .rawTranscriptAlias
                        && $0.surface == alias
                        && $0.canonical.caseInsensitiveCompare(term.canonical) == .orderedSame
                }
                let aliasSessions = uniqueSessions(aliasEvidence)
                guard term.confidence >= 0.85, aliasSessions.count >= 2 else { continue }
                upsertAlias(
                    surface: alias,
                    canonical: term.canonical,
                    confidence: calibratedConfidence(term.confidence, evidenceCount: aliasSessions.count),
                    evidenceSessionIds: aliasSessions,
                    into: &profile,
                    now: now
                )
            }
        }
    }

    private static func mergeCorrections(
        _ corrections: [ProfileCorrectionProposal],
        evidence: [ProfileEvidence],
        into profile: inout UserProfile,
        now: Date
    ) {
        for correction in corrections where correction.confidence >= 0.85 {
            let matchingEvidence = evidence.filter {
                correction.evidenceSessionIds.contains($0.sessionId)
                    && $0.surface.caseInsensitiveCompare(correction.from) == .orderedSame
                    && $0.canonical.caseInsensitiveCompare(correction.to) == .orderedSame
            }
            let negative = matchingEvidence.contains { $0.kind == .negativeCorrection }
            guard !negative else { continue }

            let modelCorrectionSessions = uniqueSessions(
                matchingEvidence.filter { $0.kind == .modelCorrection }
            )
            guard modelCorrectionSessions.count >= 2 else { continue }

            profile.commonCorrections.append(
                CommonCorrection(
                    from: correction.from,
                    to: correction.to,
                    context: correction.context,
                    scope: correction.scope,
                    confidence: calibratedConfidence(
                        correction.confidence,
                        evidenceCount: modelCorrectionSessions.count
                    ),
                    evidenceSessionIds: modelCorrectionSessions,
                    lastSeen: now
                )
            )
        }
    }

    private static func upsertGlossaryTerm(
        _ canonical: String,
        surfaces: [String],
        into profile: inout UserProfile,
        now: Date
    ) {
        if let index = profile.glossary.firstIndex(where: {
            $0.canonical.caseInsensitiveCompare(canonical) == .orderedSame
        }) {
            profile.glossary[index].lastSeen = now
            profile.glossary[index].occurrences += 1
            for surface in surfaces {
                profile.glossary[index].surfaceCounts[surface, default: 0] += 1
            }
        } else {
            var term = GlossaryTerm(
                canonical: canonical,
                occurrences: 1,
                sessionCount: 1,
                lastSeen: now
            )
            for surface in surfaces {
                term.surfaceCounts[surface, default: 0] += 1
            }
            profile.glossary.append(term)
        }
    }

    private static func upsertAlias(
        surface: String,
        canonical: String,
        confidence: Double,
        evidenceSessionIds: [String],
        into profile: inout UserProfile,
        now: Date
    ) {
        if let index = profile.termAliases.firstIndex(where: {
            $0.surface == surface && $0.canonical == canonical
        }) {
            profile.termAliases[index].confidence = max(
                profile.termAliases[index].confidence,
                confidence
            )
            profile.termAliases[index].evidenceSessionIds = Array(
                Set(profile.termAliases[index].evidenceSessionIds + evidenceSessionIds)
            ).sorted()
            profile.termAliases[index].lastSeen = now
        } else {
            profile.termAliases.append(
                TermAlias(
                    surface: surface,
                    canonical: canonical,
                    confidence: confidence,
                    evidenceSessionIds: evidenceSessionIds,
                    lastSeen: now
                )
            )
        }
    }

    private static func uniqueSessions(_ evidence: [ProfileEvidence]) -> [String] {
        Array(Set(evidence.map(\.sessionId))).sorted()
    }

    private static func calibratedConfidence(
        _ modelConfidence: Double,
        evidenceCount: Int
    ) -> Double {
        let diversity = min(1.0, Double(evidenceCount) / 3.0)
        return min(1.0, modelConfidence * (0.6 + 0.4 * diversity))
    }

    private static func enforceLimits(_ profile: inout UserProfile) {
        if profile.termAliases.count > UserProfile.aliasesLimit {
            profile.termAliases.sort { $0.confidence > $1.confidence }
            profile.termAliases = Array(profile.termAliases.prefix(UserProfile.aliasesLimit))
        }
        if profile.commonCorrections.count > UserProfile.commonCorrectionsLimit {
            profile.commonCorrections.sort { $0.confidence > $1.confidence }
            profile.commonCorrections = Array(profile.commonCorrections.prefix(UserProfile.commonCorrectionsLimit))
        }
    }
}

public enum ProfileAnalysisProposalBuilder {
    public static func build(from evidence: [ProfileEvidence]) -> ProfileAnalysisProposal {
        ProfileAnalysisProposal(
            terms: termProposals(from: evidence),
            commonCorrections: correctionProposals(from: evidence)
        )
    }

    private static func termProposals(
        from evidence: [ProfileEvidence]
    ) -> [ProfileTermProposal] {
        let aliasEvidence = evidence.filter { $0.kind == .rawTranscriptAlias }
        let grouped = Dictionary(grouping: aliasEvidence) {
            "\($0.surface)\u{1F}\($0.canonical)"
        }

        return grouped.compactMap { _, rows in
            let sessions = Array(Set(rows.map(\.sessionId))).sorted()
            guard sessions.count >= 2, let first = rows.first else { return nil }
            return ProfileTermProposal(
                canonical: first.canonical,
                surfaces: [first.canonical],
                aliases: [first.surface],
                domain: nil,
                scope: .technicalTerm,
                confidence: min(0.95, 0.72 + Double(sessions.count) * 0.08),
                evidenceSessionIds: sessions
            )
        }
    }

    private static func correctionProposals(
        from evidence: [ProfileEvidence]
    ) -> [ProfileCorrectionProposal] {
        let correctionEvidence = evidence.filter { $0.kind == .modelCorrection }
        let negativePairs = Set(
            evidence
                .filter { $0.kind == .negativeCorrection }
                .map { "\($0.surface.lowercased())\u{1F}\($0.canonical.lowercased())" }
        )
        let grouped = Dictionary(grouping: correctionEvidence) {
            "\($0.surface.lowercased())\u{1F}\($0.canonical.lowercased())"
        }

        return grouped.compactMap { key, rows in
            guard !negativePairs.contains(key) else { return nil }
            let sessions = Array(Set(rows.map(\.sessionId))).sorted()
            guard sessions.count >= 2, let first = rows.first else { return nil }
            return ProfileCorrectionProposal(
                from: first.surface,
                to: first.canonical,
                context: [first.contextBefore, first.contextAfter]
                    .filter { !$0.isEmpty }
                    .joined(separator: " "),
                scope: .recent,
                confidence: min(0.95, 0.72 + Double(sessions.count) * 0.08),
                evidenceSessionIds: sessions
            )
        }
    }
}
