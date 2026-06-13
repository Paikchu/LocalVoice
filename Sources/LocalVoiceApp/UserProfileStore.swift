import Foundation
import LocalVoiceCore
import OSLog

actor UserProfileStore {
    private var profile = UserProfile()
    private var isDirty = false
    private var flushTask: Task<Void, Never>?
    private let fileURL: URL
    private let logger = Logger(subsystem: "com.localvoice.app", category: "profile")

    static let shared: UserProfileStore = UserProfileStore()

    init(fileURL: URL = UserProfileStore.defaultFileURL) {
        self.fileURL = fileURL
    }

    // MARK: - Public API

    func load() {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        do {
            let data = try Data(contentsOf: fileURL)
            profile = try JSONDecoder().decode(UserProfile.self, from: data)
            logger.info("Profile loaded: \(self.profile.glossary.count) glossary terms, \(self.profile.sessionCount) sessions")
        } catch {
            logger.error("Profile load failed, resetting: \(error)")
            archiveCorruptFile()
            profile = UserProfile()
        }
    }

    func snapshot() -> ProfileHint {
        ProfileHintBuilder.build(from: profile)
    }

    func ingest(_ input: ProfileIngestInput) {
        ProfileExtractor.ingest(input, into: &profile)
        isDirty = true
        scheduleDebouncedFlush()
    }

    /// Called when the user cancels — penalise glossary terms that were
    /// recently surface-corrected (lightweight negative signal).
    func penaliseRecentTerms(_ terms: [String]) {
        for term in terms {
            if let idx = profile.glossary.firstIndex(where: {
                $0.canonical.lowercased() == term.lowercased()
            }) {
                profile.glossary[idx].occurrences = max(0, profile.glossary[idx].occurrences - 1)
            }
        }
        isDirty = true
    }

    func flushNow() {
        flushTask?.cancel()
        flushTask = nil
        guard isDirty else { return }
        persist()
        isDirty = false
    }

    // MARK: - Private helpers

    private func scheduleDebouncedFlush() {
        flushTask?.cancel()
        flushTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            await self?.commitFlush()
        }
    }

    private func commitFlush() {
        guard isDirty else { return }
        persist()
        isDirty = false
    }

    private func persist() {
        do {
            let data = try JSONEncoder().encode(profile)
            let tmp = fileURL.deletingLastPathComponent()
                .appendingPathComponent("profile.json.tmp")
            try data.write(to: tmp, options: .atomic)
            _ = try FileManager.default.replaceItemAt(fileURL, withItemAt: tmp)
            logger.debug("Profile persisted (\(data.count) bytes)")
        } catch {
            logger.error("Profile persist failed: \(error)")
        }
    }

    private func archiveCorruptFile() {
        let corrupt = fileURL.deletingLastPathComponent()
            .appendingPathComponent("profile.json.corrupt")
        try? FileManager.default.removeItem(at: corrupt)
        try? FileManager.default.moveItem(at: fileURL, to: corrupt)
    }

    static var defaultFileURL: URL {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!
        let dir = appSupport.appendingPathComponent("LocalVoice", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("profile.json")
    }
}
