import Foundation

// MARK: - Data models

public struct GlossaryTerm: Codable, Equatable, Sendable {
    public var canonical: String
    public var surfaceCounts: [String: Int]
    public var occurrences: Double  // Double so degraded sessions count 0.5
    public var sessionCount: Int
    public var lastSeen: Date

    public init(
        canonical: String,
        surfaceCounts: [String: Int] = [:],
        occurrences: Double = 0,
        sessionCount: Int = 0,
        lastSeen: Date = Date()
    ) {
        self.canonical = canonical
        self.surfaceCounts = surfaceCounts
        self.occurrences = occurrences
        self.sessionCount = sessionCount
        self.lastSeen = lastSeen
    }

    /// Dominant surface form across all recorded occurrences.
    public var dominantSurface: String {
        surfaceCounts.max(by: { $0.value < $1.value })?.key ?? canonical
    }
}

public struct ContactFact: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case email, phone, address
    }
    public let kind: Kind
    public let value: String
    public var occurrences: Int
    public var lastSeen: Date

    public init(kind: Kind, value: String, occurrences: Int = 1, lastSeen: Date = Date()) {
        self.kind = kind
        self.value = value
        self.occurrences = occurrences
        self.lastSeen = lastSeen
    }
}

public struct StyleStats: Codable, Equatable, Sendable {
    public var totalSessions: Int = 0
    public var emailSessions: Int = 0
    public var fallbackSessions: Int = 0
    public var totalChineseChars: Int = 0
    public var totalEnglishChars: Int = 0
    public var totalSentences: Int = 0
    public var totalOutputLength: Int = 0

    public init() {}

    public var emailRate: Double {
        totalSessions == 0 ? 0 : Double(emailSessions) / Double(totalSessions)
    }
}

public struct UserProfile: Codable, Equatable, Sendable {
    public var version: Int = 1
    public var domains: [String: Double] = [:]
    public var glossary: [GlossaryTerm] = []
    public var candidates: [GlossaryTerm] = []
    public var contacts: [ContactFact] = []
    public var contactCandidates: [ContactFact] = []
    public var style: StyleStats = StyleStats()
    public var sessionCount: Int = 0

    public static let glossaryLimit = 64
    public static let candidatesLimit = 256
    public static let contactsLimit = 16
    public static let contactCandidatesLimit = 64

    // Promotion thresholds
    public static let glossaryMinOccurrences: Double = 3.0
    public static let glossaryMinSessions: Int = 2
    public static let contactMinOccurrences: Int = 2
    public static let domainPromotionThreshold: Double = 5.0

    public init() {}
}

// MARK: - Session input

public struct ProfileIngestInput: Sendable {
    public let finalText: String
    public let mode: VoiceMode
    public let wasEmail: Bool
    public let usedFallback: Bool

    public init(
        finalText: String,
        mode: VoiceMode,
        wasEmail: Bool,
        usedFallback: Bool
    ) {
        self.finalText = finalText
        self.mode = mode
        self.wasEmail = wasEmail
        self.usedFallback = usedFallback
    }
}

public struct ProfileHint: Sendable {
    public let glossaryTerms: [String]  // canonical forms, top-16 by frequency
    public let topDomains: [String]     // top-2
    public let contacts: [ContactFact]  // top-4

    public static let empty = ProfileHint(glossaryTerms: [], topDomains: [], contacts: [])

    public init(glossaryTerms: [String], topDomains: [String], contacts: [ContactFact]) {
        self.glossaryTerms = glossaryTerms
        self.topDomains = topDomains
        self.contacts = contacts
    }

    public var isEmpty: Bool {
        glossaryTerms.isEmpty && topDomains.isEmpty && contacts.isEmpty
    }

    /// Compact text block injected into the prompt. Hard limit: 400 characters.
    public var promptBlock: String? {
        guard !isEmpty else { return nil }
        var parts: [String] = []

        if !glossaryTerms.isEmpty {
            parts.append("用户术语表（如原文出现读音相近的误写，请改为下列规范写法；不得据此添加原文没有的内容）：\n"
                + glossaryTerms.joined(separator: "、"))
        }
        if !topDomains.isEmpty {
            parts.append("用户领域：" + topDomains.joined(separator: "、"))
        }
        if !contacts.isEmpty {
            let lines = contacts.map { "\($0.kind.rawValue): \($0.value)" }
            parts.append("常用联系方式：\n" + lines.joined(separator: "\n"))
        }

        var block = parts.joined(separator: "\n\n")
        if block.count > 400 {
            block = String(block.prefix(397)) + "…"
        }
        return block
    }
}

// MARK: - Seed glossary loader

enum SeedGlossary {
    static let terms: Set<String> = {
        guard let url = Bundle.module.url(
            forResource: "seed-glossary",
            withExtension: "json"
        ),
        let data = try? Data(contentsOf: url),
        let decoded = try? JSONDecoder().decode(SeedGlossaryFile.self, from: data)
        else { return [] }
        return Set(decoded.terms)
    }()

    static let commonEnglishWords: Set<String> = {
        guard let url = Bundle.module.url(
            forResource: "seed-glossary",
            withExtension: "json"
        ),
        let data = try? Data(contentsOf: url),
        let decoded = try? JSONDecoder().decode(SeedGlossaryFile.self, from: data)
        else { return [] }
        return Set(decoded.commonEnglishWords.map { $0.lowercased() })
    }()

    static let domainKeywords: [String: [String]] = {
        guard let url = Bundle.module.url(
            forResource: "seed-glossary",
            withExtension: "json"
        ),
        let data = try? Data(contentsOf: url),
        let decoded = try? JSONDecoder().decode(SeedGlossaryFile.self, from: data)
        else { return [:] }
        return decoded.domainKeywords
    }()

    private struct SeedGlossaryFile: Decodable {
        let terms: [String]
        let commonEnglishWords: [String]
        let domainKeywords: [String: [String]]

        enum CodingKeys: String, CodingKey {
            case terms
            case commonEnglishWords = "common_english_words"
            case domainKeywords = "domain_keywords"
        }
    }
}

// MARK: - ProfileExtractor (pure functions, no side effects)

public enum ProfileExtractor {

    // MARK: Public entry point

    public static func ingest(
        _ input: ProfileIngestInput,
        into profile: inout UserProfile,
        now: Date = Date()
    ) {
        let text = input.finalText
        let weight: Double = input.usedFallback ? 0.5 : 1.0

        // 1. Style stats
        updateStyle(&profile.style, text: text, input: input)

        // 2. Domain scoring
        scoreDomains(text, into: &profile.domains, weight: weight)

        // 3. Term candidates
        let termTokens = extractTermCandidates(from: text)
        mergeTermCandidates(
            termTokens,
            into: &profile.candidates,
            weight: weight,
            now: now
        )

        // 4. Contact candidates
        let contactFacts = extractContactCandidates(from: text)
        mergeContactCandidates(contactFacts, into: &profile.contactCandidates, now: now)

        // 5. Promote candidates → official lists
        promoteCandidates(&profile.candidates, into: &profile.glossary)
        promoteContactCandidates(&profile.contactCandidates, into: &profile.contacts)

        // 6. Enforce limits + decay
        enforceLimits(&profile)
        decayIfNeeded(&profile, now: now)

        profile.sessionCount += 1
    }

    // MARK: Domain scoring

    static func scoreDomains(
        _ text: String,
        into domains: inout [String: Double],
        weight: Double
    ) {
        let lower = text.lowercased()
        for (domain, keywords) in SeedGlossary.domainKeywords {
            var hits = 0
            for keyword in keywords {
                if lower.contains(keyword.lowercased()) {
                    hits += 1
                }
            }
            if hits > 0 {
                domains[domain, default: 0] += Double(hits) * weight
            }
        }
    }

    // MARK: Term extraction

    /// Returns raw surface tokens that are candidates for the glossary.
    static func extractTermCandidates(from text: String) -> [String] {
        var candidates: [String] = []

        // Pattern 1: tokens containing uppercase letters or digits mixed with letters
        // Covers: Kubernetes, gRPC, K8s, localStorage, HTTP
        let tokenPattern = try! NSRegularExpression(
            pattern: #"[A-Za-z][A-Za-z0-9]*(?:[.\-/][A-Za-z0-9]+)*"#
        )
        let matches = tokenPattern.matches(
            in: text,
            range: NSRange(text.startIndex..., in: text)
        )
        for match in matches {
            guard let range = Range(match.range, in: text) else { continue }
            let token = String(text[range])
            if isTermCandidate(token) {
                candidates.append(token)
            }
        }
        return candidates
    }

    static func isTermCandidate(_ token: String) -> Bool {
        guard token.count >= 2, token.count <= 40 else { return false }

        // Must have at least one uppercase letter, a digit, or mixed alphanumeric
        let hasUppercase = token.contains(where: { $0.isUppercase })
        let hasMixedAlphaNum = token.contains(where: { $0.isNumber })
            && token.contains(where: { $0.isLetter })
        let hasSeparator = (token.contains(".") || token.contains("-") || token.contains("/"))
            && token.contains(where: { $0.isLetter })

        guard hasUppercase || hasMixedAlphaNum || hasSeparator else { return false }

        // Reject pure numbers
        if token.allSatisfy({ $0.isNumber }) { return false }

        // Reject common English words (lowercased comparison)
        if SeedGlossary.commonEnglishWords.contains(token.lowercased()) { return false }

        return true
    }

    static func mergeTermCandidates(
        _ tokens: [String],
        into candidates: inout [GlossaryTerm],
        weight: Double,
        now: Date
    ) {
        for token in tokens {
            let key = token.lowercased()
            if let idx = candidates.firstIndex(where: {
                $0.canonical.lowercased() == key
                    || $0.surfaceCounts.keys.contains(token)
            }) {
                candidates[idx].occurrences += weight
                candidates[idx].surfaceCounts[token, default: 0] += 1
                candidates[idx].lastSeen = now
                // Re-elect canonical as the dominant surface form
                candidates[idx].canonical = candidates[idx].dominantSurface
            } else {
                // Check seed glossary for initial canonical
                let seedCanonical = SeedGlossary.terms.first {
                    $0.lowercased() == key
                } ?? token
                var term = GlossaryTerm(
                    canonical: seedCanonical,
                    occurrences: weight,
                    sessionCount: 1,
                    lastSeen: now
                )
                term.surfaceCounts[token] = 1
                candidates.append(term)
            }
        }
    }

    // MARK: Contact extraction

    static let emailRegex = try! NSRegularExpression(
        pattern: #"[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}"#
    )
    static let phoneRegex = try! NSRegularExpression(
        pattern: #"(?<!\d)(1[3-9]\d{9})(?!\d)"#  // 中国大陆手机号
    )
    static let addressRegex = try! NSRegularExpression(
        pattern: #"(?:[^，。！？\s]{1,8}(?:省|市|区|县|路|街道|弄|号|栋|室|楼)){2,}"#
    )

    static func extractContactCandidates(from text: String) -> [ContactFact] {
        var facts: [ContactFact] = []
        let range = NSRange(text.startIndex..., in: text)

        for match in emailRegex.matches(in: text, range: range) {
            if let r = Range(match.range, in: text) {
                facts.append(.init(kind: .email, value: String(text[r])))
            }
        }
        for match in phoneRegex.matches(in: text, range: range) {
            if let r = Range(match.range, in: text) {
                facts.append(.init(kind: .phone, value: String(text[r])))
            }
        }
        for match in addressRegex.matches(in: text, range: range) {
            if let r = Range(match.range, in: text) {
                facts.append(.init(kind: .address, value: String(text[r])))
            }
        }
        return facts
    }

    static func mergeContactCandidates(
        _ facts: [ContactFact],
        into candidates: inout [ContactFact],
        now: Date
    ) {
        for fact in facts {
            if let idx = candidates.firstIndex(where: {
                $0.kind == fact.kind && $0.value == fact.value
            }) {
                candidates[idx].occurrences += 1
                candidates[idx].lastSeen = now
            } else {
                candidates.append(fact)
            }
        }
    }

    // MARK: Promotion

    static func promoteCandidates(
        _ candidates: inout [GlossaryTerm],
        into glossary: inout [GlossaryTerm]
    ) {
        var toRemove: [Int] = []
        for (i, candidate) in candidates.enumerated() {
            guard
                candidate.occurrences >= UserProfile.glossaryMinOccurrences,
                candidate.sessionCount >= UserProfile.glossaryMinSessions
            else { continue }

            if let idx = glossary.firstIndex(where: {
                $0.canonical.lowercased() == candidate.canonical.lowercased()
            }) {
                // Merge into existing glossary entry
                for (surface, count) in candidate.surfaceCounts {
                    glossary[idx].surfaceCounts[surface, default: 0] += count
                }
                glossary[idx].occurrences += candidate.occurrences
                glossary[idx].sessionCount += candidate.sessionCount
                glossary[idx].lastSeen = candidate.lastSeen
                glossary[idx].canonical = glossary[idx].dominantSurface
            } else {
                glossary.append(candidate)
            }
            toRemove.append(i)
        }
        for i in toRemove.reversed() { candidates.remove(at: i) }
    }

    static func promoteContactCandidates(
        _ candidates: inout [ContactFact],
        into contacts: inout [ContactFact]
    ) {
        var toRemove: [Int] = []
        for (i, candidate) in candidates.enumerated() {
            guard candidate.occurrences >= UserProfile.contactMinOccurrences else { continue }
            if let idx = contacts.firstIndex(where: {
                $0.kind == candidate.kind && $0.value == candidate.value
            }) {
                contacts[idx].occurrences += candidate.occurrences
                contacts[idx].lastSeen = candidate.lastSeen
            } else {
                contacts.append(candidate)
            }
            toRemove.append(i)
        }
        for i in toRemove.reversed() { candidates.remove(at: i) }
    }

    // MARK: Limits & decay

    static func enforceLimits(_ profile: inout UserProfile) {
        // Glossary: keep top by occurrences
        if profile.glossary.count > UserProfile.glossaryLimit {
            profile.glossary.sort { $0.occurrences > $1.occurrences }
            profile.glossary = Array(profile.glossary.prefix(UserProfile.glossaryLimit))
        }
        // Candidates: LRU eviction
        if profile.candidates.count > UserProfile.candidatesLimit {
            profile.candidates.sort { $0.lastSeen > $1.lastSeen }
            profile.candidates = Array(profile.candidates.prefix(UserProfile.candidatesLimit))
        }
        if profile.contacts.count > UserProfile.contactsLimit {
            profile.contacts.sort { $0.lastSeen > $1.lastSeen }
            profile.contacts = Array(profile.contacts.prefix(UserProfile.contactsLimit))
        }
        if profile.contactCandidates.count > UserProfile.contactCandidatesLimit {
            profile.contactCandidates.sort { $0.lastSeen > $1.lastSeen }
            profile.contactCandidates = Array(
                profile.contactCandidates.prefix(UserProfile.contactCandidatesLimit)
            )
        }
    }

    static func decayIfNeeded(_ profile: inout UserProfile, now: Date) {
        let ninetyDays: TimeInterval = 90 * 24 * 3600
        let oneEightyDays: TimeInterval = 180 * 24 * 3600

        // Demote old glossary entries back to candidates
        var demoted: [GlossaryTerm] = []
        profile.glossary = profile.glossary.filter { term in
            if now.timeIntervalSince(term.lastSeen) > ninetyDays {
                demoted.append(term)
                return false
            }
            return true
        }
        profile.candidates.append(contentsOf: demoted)

        // Remove very stale candidates
        profile.candidates = profile.candidates.filter {
            now.timeIntervalSince($0.lastSeen) <= oneEightyDays
        }
        profile.contactCandidates = profile.contactCandidates.filter {
            now.timeIntervalSince($0.lastSeen) <= oneEightyDays
        }

        // Monthly decay on domain scores (approximate: if session runs daily, decay ~×0.8/month)
        // We apply a small per-session decay to avoid unbounded growth
        for key in profile.domains.keys {
            profile.domains[key]! *= 0.995
            if profile.domains[key]! < 0.1 { profile.domains.removeValue(forKey: key) }
        }
    }

    // MARK: Style update

    static func updateStyle(
        _ style: inout StyleStats,
        text: String,
        input: ProfileIngestInput
    ) {
        style.totalSessions += 1
        if input.wasEmail { style.emailSessions += 1 }
        if input.usedFallback { style.fallbackSessions += 1 }
        style.totalOutputLength += text.count

        let hanCount = text.unicodeScalars.filter {
            $0.value >= 0x4E00 && $0.value <= 0x9FFF
        }.count
        let asciiLetterCount = text.filter { $0.isASCII && $0.isLetter }.count
        style.totalChineseChars += hanCount
        style.totalEnglishChars += asciiLetterCount

        let sentencePattern = try! NSRegularExpression(
            pattern: #"[。！？.!?]+"#
        )
        style.totalSentences += sentencePattern.numberOfMatches(
            in: text,
            range: NSRange(text.startIndex..., in: text)
        )
    }
}

// MARK: - ProfileHintBuilder

public enum ProfileHintBuilder {
    public static func build(from profile: UserProfile) -> ProfileHint {
        // Top-16 glossary terms by occurrences × recency (simple score)
        let now = Date()
        let scoredGlossary = profile.glossary
            .map { term -> (String, Double) in
                let ageDays = now.timeIntervalSince(term.lastSeen) / 86400
                let recency = max(0, 1.0 - ageDays / 90.0)
                return (term.canonical, term.occurrences * (0.5 + 0.5 * recency))
            }
            .sorted { $0.1 > $1.1 }
            .prefix(16)
            .map(\.0)

        // Top-2 domains above threshold
        let topDomains = profile.domains
            .filter { $0.value >= UserProfile.domainPromotionThreshold }
            .sorted { $0.value > $1.value }
            .prefix(2)
            .map(\.key)

        // Top-4 contacts by recency
        let topContacts = Array(
            profile.contacts
                .sorted { $0.lastSeen > $1.lastSeen }
                .prefix(4)
        )

        return ProfileHint(
            glossaryTerms: Array(scoredGlossary),
            topDomains: Array(topDomains),
            contacts: topContacts
        )
    }
}

// MARK: - GlossaryNormalizer

public enum GlossaryNormalizer {

    /// Applies glossary-based normalization to `text`.
    /// Protected zones (URLs, emails, product codes) are not modified.
    public static func normalize(_ text: String, glossary: [GlossaryTerm]) -> String {
        guard !glossary.isEmpty else { return text }

        // 1. Find protected zones from existing FactExtractor patterns
        let protected = protectedRanges(in: text)

        // 2. Apply exact case-insensitive word-boundary replacement
        var result = text
        for term in glossary {
            result = replaceIfSafe(
                result,
                canonical: term.canonical,
                protected: protected
            )
        }

        // 3. Edit-distance correction for likely-misspelled tokens
        result = correctMisspelledTerms(result, glossary: glossary, protected: protected)

        return result
    }

    // MARK: Implementation

    static func protectedRanges(in text: String) -> [Range<String.Index>] {
        let patterns = [
            // URLs
            #"https?://[A-Za-z0-9._~:/?\[\]@!$&'()*+,;=%#\-]+"#,
            // Emails
            #"[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}"#,
            // Product codes (e.g. LV-2048)
            #"(?<![A-Z0-9])[A-Z][A-Z0-9]+-[A-Z0-9\-]+(?![A-Z0-9a-z])"#,
            // Times
            #"\b\d{1,2}:\d{2}\b"#,
            // Money
            #"(?:¥|￥|\$)\s?\d+(?:\.\d+)?"#,
            #"\d+(?:\.\d+)?\s*(?:万元|美元|元|%)"#
        ]
        var ranges: [Range<String.Index>] = []
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let nsRange = NSRange(text.startIndex..., in: text)
            for match in regex.matches(in: text, range: nsRange) {
                if let r = Range(match.range, in: text) {
                    ranges.append(r)
                }
            }
        }
        return ranges
    }

    static func isProtected(_ range: Range<String.Index>, by protected: [Range<String.Index>]) -> Bool {
        protected.contains { $0.overlaps(range) }
    }

    static func replaceIfSafe(
        _ text: String,
        canonical: String,
        protected: [Range<String.Index>]
    ) -> String {
        // Build word-boundary aware pattern
        let escaped = NSRegularExpression.escapedPattern(for: canonical)
        let pattern = #"(?<![A-Za-z0-9\-_])"# + escaped + #"(?![A-Za-z0-9\-_])"#
        guard let regex = try? NSRegularExpression(
            pattern: pattern,
            options: .caseInsensitive
        ) else { return text }

        var result = text
        var offset = 0
        let nsText = text as NSString
        let nsRange = NSRange(location: 0, length: nsText.length)
        let matches = regex.matches(in: text, options: [], range: nsRange)

        for match in matches {
            guard let range = Range(match.range, in: text) else { continue }
            // Adjust range for previously applied replacements
            let adjustedStart = text.index(
                range.lowerBound,
                offsetBy: 0,
                limitedBy: text.endIndex
            ) ?? range.lowerBound

            if isProtected(range, by: protected) { continue }
            let matchedText = String(text[range])
            if matchedText == canonical { continue }  // already correct

            // Apply replacement in result string
            let nsResult = result as NSString
            let resultRange = NSRange(
                location: match.range.location + offset,
                length: match.range.length
            )
            let before = result.count
            result = nsResult.replacingCharacters(in: resultRange, with: canonical)
            offset += result.count - before
        }
        return result
    }

    static func correctMisspelledTerms(
        _ text: String,
        glossary: [GlossaryTerm],
        protected: [Range<String.Index>]
    ) -> String {
        // Tokenize: only process tokens that look like terms (contain uppercase or digit+letter)
        let tokenPattern = try! NSRegularExpression(
            pattern: #"[A-Za-z][A-Za-z0-9]*(?:[\.\-][A-Za-z0-9]+)*"#
        )
        let nsText = text as NSString
        let matches = tokenPattern.matches(
            in: text,
            range: NSRange(location: 0, length: nsText.length)
        )

        var replacements: [(NSRange, String)] = []
        for match in matches {
            guard let range = Range(match.range, in: text) else { continue }
            if isProtected(range, by: protected) { continue }

            let token = String(text[range])

            // Only attempt correction for tokens that look like terms
            guard ProfileExtractor.isTermCandidate(token) else { continue }

            if let corrected = bestGlossaryMatch(for: token, in: glossary) {
                if corrected != token {
                    replacements.append((match.range, corrected))
                }
            }
        }

        // Apply in reverse order to keep ranges valid
        var result = text
        for (nsRange, replacement) in replacements.reversed() {
            guard let range = Range(nsRange, in: result) else { continue }
            result.replaceSubrange(range, with: replacement)
        }
        return result
    }

    static func bestGlossaryMatch(for token: String, in glossary: [GlossaryTerm]) -> String? {
        let tokenLower = token.lowercased()
        let tokenLen = token.count

        for term in glossary {
            let canonical = term.canonical
            let canonicalLower = canonical.lowercased()
            let canonicalLen = canonical.count

            // Exact case-insensitive match → already handled by replaceIfSafe
            if tokenLower == canonicalLower { return canonical }

            // Edit distance threshold: len>=6 → dist<=2, len>=10 → dist<=3
            let minLen = min(tokenLen, canonicalLen)
            let threshold: Int
            if minLen >= 10 { threshold = 3 }
            else if minLen >= 6 { threshold = 2 }
            else { continue }

            let dist = damerauLevenshtein(tokenLower, canonicalLower)
            if dist > 0 && dist <= threshold {
                return canonical
            }
        }
        return nil
    }

    /// Damerau-Levenshtein distance (transpositions included).
    static func damerauLevenshtein(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        let m = a.count, n = b.count
        if m == 0 { return n }
        if n == 0 { return m }

        // Early exit if difference in length exceeds max possible threshold
        if abs(m - n) > 3 { return abs(m - n) }

        var dp = Array(repeating: Array(repeating: 0, count: n + 1), count: m + 1)
        for i in 0...m { dp[i][0] = i }
        for j in 0...n { dp[0][j] = j }

        for i in 1...m {
            for j in 1...n {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                dp[i][j] = Swift.min(
                    dp[i-1][j] + 1,
                    dp[i][j-1] + 1,
                    dp[i-1][j-1] + cost
                )
                if i > 1 && j > 1 && a[i-1] == b[j-2] && a[i-2] == b[j-1] {
                    dp[i][j] = Swift.min(dp[i][j], dp[i-2][j-2] + cost)
                }
            }
        }
        return dp[m][n]
    }
}
