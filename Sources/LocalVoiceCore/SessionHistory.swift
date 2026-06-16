import Foundation

public struct SessionHistoryRecord: Codable, Equatable, Sendable {
    public let id: String
    public let createdAt: Date
    public let rawTranscript: String
    public let finalOutput: String
    public let mode: VoiceMode
    public let suspects: [SuspectSpan]
    public let corrections: [TermCorrection]
    public let usedFallback: Bool
    public let targetAppBundleID: String?
    public let profileVersionAtUse: Int

    public init(
        id: String = UUID().uuidString,
        createdAt: Date = Date(),
        rawTranscript: String,
        finalOutput: String,
        mode: VoiceMode,
        suspects: [SuspectSpan],
        corrections: [TermCorrection],
        usedFallback: Bool = false,
        targetAppBundleID: String? = nil,
        profileVersionAtUse: Int = 1
    ) {
        self.id = id
        self.createdAt = createdAt
        self.rawTranscript = rawTranscript
        self.finalOutput = finalOutput
        self.mode = mode
        self.suspects = suspects
        self.corrections = corrections
        self.usedFallback = usedFallback
        self.targetAppBundleID = targetAppBundleID
        self.profileVersionAtUse = profileVersionAtUse
    }
}
