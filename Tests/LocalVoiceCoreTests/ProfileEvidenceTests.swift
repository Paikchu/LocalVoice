import Testing
@testable import LocalVoiceCore

@Test func evidenceExtractsAliasFromRawFinalDifference() {
    let session = SessionHistoryRecord(
        id: "s1",
        rawTranscript: "把服务部署到酷伯内特斯上",
        finalOutput: "把服务部署到 Kubernetes 上",
        mode: .dictation,
        suspects: [],
        corrections: []
    )

    let evidence = ProfileEvidenceExtractor.extract(from: session)

    #expect(evidence.contains {
        $0.kind == .rawTranscriptAlias
            && $0.surface == "酷伯内特斯"
            && $0.canonical == "Kubernetes"
            && $0.source == .rawFinalDiff
    })
}

@Test func evidenceTreatsExplicitCorrectionInstructionAsNegative() {
    let session = SessionHistoryRecord(
        id: "s2",
        rawTranscript: "把这个 employ 的地方改成 deploy",
        finalOutput: "把这个 employ 的地方改成 deploy",
        mode: .dictation,
        suspects: [],
        corrections: []
    )

    let evidence = ProfileEvidenceExtractor.extract(from: session)

    #expect(evidence.contains {
        $0.kind == .negativeCorrection
            && $0.surface == "employ"
            && $0.canonical == "deploy"
    })
}

@Test func evidenceDoesNotPromoteAsrSuspectAlone() {
    let session = SessionHistoryRecord(
        id: "s3",
        rawTranscript: "今天 employ 新版本",
        finalOutput: "今天 employ 新版本",
        mode: .dictation,
        suspects: [
            SuspectSpan(text: "employ", confidence: 0.31, alternatives: ["deploy"])
        ],
        corrections: []
    )

    let evidence = ProfileEvidenceExtractor.extract(from: session)
    var profile = UserProfile()
    let proposal = ProfileAnalysisProposal(
        commonCorrections: [
            ProfileCorrectionProposal(
                from: "employ",
                to: "deploy",
                context: "software release",
                scope: .domain("softwareEngineering"),
                confidence: 0.99,
                evidenceSessionIds: ["s3"]
            )
        ]
    )

    ProfileAnalysisMerger.merge(
        proposal,
        evidence: evidence,
        into: &profile
    )

    #expect(profile.commonCorrections.isEmpty)
}

@Test func mergerPromotesAliasWithTwoRawFinalEvidenceSessions() {
    let sessions = [
        SessionHistoryRecord(
            id: "s1",
            rawTranscript: "部署到酷伯内特斯",
            finalOutput: "部署到 Kubernetes",
            mode: .dictation,
            suspects: [],
            corrections: []
        ),
        SessionHistoryRecord(
            id: "s2",
            rawTranscript: "检查酷伯内特斯 dashboard",
            finalOutput: "检查 Kubernetes dashboard",
            mode: .dictation,
            suspects: [],
            corrections: []
        )
    ]
    let evidence = sessions.flatMap(ProfileEvidenceExtractor.extract)
    var profile = UserProfile()
    let proposal = ProfileAnalysisProposal(
        terms: [
            ProfileTermProposal(
                canonical: "Kubernetes",
                surfaces: ["Kubernetes"],
                aliases: ["酷伯内特斯"],
                domain: "softwareEngineering",
                scope: .technicalTerm,
                confidence: 0.91,
                evidenceSessionIds: ["s1", "s2"]
            )
        ]
    )

    ProfileAnalysisMerger.merge(
        proposal,
        evidence: evidence,
        into: &profile
    )

    #expect(profile.termAliases.contains {
        $0.surface == "酷伯内特斯" && $0.canonical == "Kubernetes"
    })
}

@Test func profileHintIncludesAliasesAndScopedCorrections() {
    var profile = UserProfile()
    profile.glossary.append(
        GlossaryTerm(canonical: "Kubernetes", occurrences: 4, sessionCount: 2)
    )
    profile.termAliases.append(
        TermAlias(
            surface: "酷伯内特斯",
            canonical: "Kubernetes",
            confidence: 0.9,
            evidenceSessionIds: ["s1", "s2"]
        )
    )
    profile.commonCorrections.append(
        CommonCorrection(
            from: "employ",
            to: "deploy",
            context: "software release",
            scope: .domain("softwareEngineering"),
            confidence: 0.9,
            evidenceSessionIds: ["s3", "s4"]
        )
    )

    let hint = ProfileHintBuilder.build(from: profile)
    let block = hint.promptBlock ?? ""

    #expect(block.contains("酷伯内特斯 -> Kubernetes"))
    #expect(block.contains("employ -> deploy"))
    #expect(block.count <= 400)
}

@Test func speechContextualStringsUseCanonicalTermsOnly() {
    var profile = UserProfile()
    profile.glossary.append(
        GlossaryTerm(canonical: "Kubernetes", occurrences: 4, sessionCount: 2)
    )
    profile.termAliases.append(
        TermAlias(
            surface: "酷伯内特斯",
            canonical: "Kubernetes",
            confidence: 0.9,
            evidenceSessionIds: ["s1", "s2"]
        )
    )
    profile.commonCorrections.append(
        CommonCorrection(
            from: "employ",
            to: "deploy",
            context: "software release",
            scope: .domain("softwareEngineering"),
            confidence: 0.9,
            evidenceSessionIds: ["s3", "s4"]
        )
    )

    let strings = ProfileHintBuilder.speechContextualStrings(from: profile)

    #expect(strings.contains("Kubernetes"))
    #expect(!strings.contains("酷伯内特斯"))
    #expect(!strings.contains("deploy"))
}

@Test func analysisProposalPromotesRepeatedAliasEvidence() {
    let sessions = [
        SessionHistoryRecord(
            id: "s1",
            rawTranscript: "部署到酷伯内特斯",
            finalOutput: "部署到 Kubernetes",
            mode: .dictation,
            suspects: [],
            corrections: []
        ),
        SessionHistoryRecord(
            id: "s2",
            rawTranscript: "酷伯内特斯 dashboard",
            finalOutput: "Kubernetes dashboard",
            mode: .dictation,
            suspects: [],
            corrections: []
        )
    ]
    let evidence = sessions.flatMap(ProfileEvidenceExtractor.extract)

    let proposal = ProfileAnalysisProposalBuilder.build(from: evidence)

    #expect(proposal.terms.contains {
        $0.canonical == "Kubernetes"
            && $0.aliases.contains("酷伯内特斯")
            && Set($0.evidenceSessionIds) == ["s1", "s2"]
    })
}
