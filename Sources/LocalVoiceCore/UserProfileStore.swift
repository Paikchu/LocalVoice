import Foundation
import OSLog

public actor UserProfileStore {
    private var profile = UserProfile()
    private var isDirty = false
    private var flushTask: Task<Void, Never>?
    private var isEnabled: Bool
    private let fileURL: URL
    private let logger = Logger(
        subsystem: "com.localvoice.app",
        category: "profile"
    )

    public init(
        fileURL: URL = UserProfileStore.defaultFileURL,
        isEnabled: Bool = false
    ) {
        self.fileURL = fileURL
        self.isEnabled = isEnabled
    }

    public func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        guard !enabled else { return }
        flushTask?.cancel()
        flushTask = nil
        isDirty = false
        profile = UserProfile()
    }

    public func load() {
        profile = UserProfile()
        guard isEnabled,
              FileManager.default.fileExists(atPath: fileURL.path) else {
            return
        }
        do {
            let data = try Data(contentsOf: fileURL)
            profile = try JSONDecoder().decode(UserProfile.self, from: data)
            logger.info(
                "Profile loaded: \(self.profile.glossary.count) glossary terms, \(self.profile.sessionCount) sessions"
            )
        } catch {
            logger.error("Profile load failed, resetting: \(error)")
            archiveCorruptFile()
        }
    }

    public func snapshot() -> ProfileHint {
        guard isEnabled else { return .empty }
        return ProfileHintBuilder.build(from: profile)
    }

    public func ingest(_ input: ProfileIngestInput) {
        guard isEnabled else { return }
        ProfileExtractor.ingest(input, into: &profile)
        isDirty = true
        scheduleDebouncedFlush()
    }

    public func penaliseRecentTerms(_ terms: [String]) {
        guard isEnabled else { return }
        for term in terms {
            if let index = profile.glossary.firstIndex(where: {
                $0.canonical.lowercased() == term.lowercased()
            }) {
                profile.glossary[index].occurrences = max(
                    0,
                    profile.glossary[index].occurrences - 1
                )
            }
        }
        isDirty = true
    }

    public func flushNow() {
        flushTask?.cancel()
        flushTask = nil
        guard isEnabled, isDirty else { return }
        persist()
        isDirty = false
    }

    public func clear() throws {
        flushTask?.cancel()
        flushTask = nil
        isDirty = false
        profile = UserProfile()

        for url in profileArtifactURLs {
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
        }
    }

    private func scheduleDebouncedFlush() {
        flushTask?.cancel()
        flushTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            await self?.commitFlush()
        }
    }

    private func commitFlush() {
        guard isEnabled, isDirty else { return }
        persist()
        isDirty = false
    }

    private func persist() {
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try JSONEncoder().encode(profile)
            let temporaryURL = profileArtifactURLs[1]
            try data.write(to: temporaryURL, options: .atomic)
            if FileManager.default.fileExists(atPath: fileURL.path) {
                _ = try FileManager.default.replaceItemAt(
                    fileURL,
                    withItemAt: temporaryURL
                )
            } else {
                try FileManager.default.moveItem(
                    at: temporaryURL,
                    to: fileURL
                )
            }
            logger.debug("Profile persisted (\(data.count) bytes)")
        } catch {
            logger.error("Profile persist failed: \(error)")
        }
    }

    private func archiveCorruptFile() {
        let corruptURL = profileArtifactURLs[2]
        try? FileManager.default.removeItem(at: corruptURL)
        try? FileManager.default.moveItem(at: fileURL, to: corruptURL)
    }

    private var profileArtifactURLs: [URL] {
        [
            fileURL,
            URL(fileURLWithPath: fileURL.path + ".tmp"),
            URL(fileURLWithPath: fileURL.path + ".corrupt")
        ]
    }

    public static var defaultFileURL: URL {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!
        return appSupport
            .appendingPathComponent("LocalVoice", isDirectory: true)
            .appendingPathComponent("profile.json")
    }
}
