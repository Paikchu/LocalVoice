import Foundation
import LocalVoiceCore
import OSLog

actor SessionHistoryStore {
    private let directoryURL: URL
    private let maxBytes: UInt64
    private let logger = Logger(
        subsystem: "com.localvoice.app",
        category: "history"
    )

    init(
        directoryURL: URL = SessionHistoryStore.defaultDirectoryURL,
        maxBytes: UInt64 = 50 * 1_024 * 1_024
    ) {
        self.directoryURL = directoryURL
        self.maxBytes = maxBytes
    }

    func append(_ record: SessionHistoryRecord) throws {
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
        let data = try JSONEncoder.localVoiceHistory.encode(record)
        var line = data
        line.append(0x0A)
        if FileManager.default.fileExists(atPath: currentFileURL.path) {
            let handle = try FileHandle(forWritingTo: currentFileURL)
            try handle.seekToEnd()
            try handle.write(contentsOf: line)
            try handle.close()
        } else {
            try line.write(to: currentFileURL, options: .atomic)
        }
        try enforceSizeLimit()
    }

    func recentRecords(limit: Int = 200) throws -> [SessionHistoryRecord] {
        let files = try historyFiles().suffix(3)
        var records: [SessionHistoryRecord] = []
        for file in files {
            guard let content = try? String(contentsOf: file, encoding: .utf8) else {
                continue
            }
            for line in content.split(separator: "\n") {
                guard let data = String(line).data(using: .utf8),
                      let record = try? JSONDecoder.localVoiceHistory.decode(
                        SessionHistoryRecord.self,
                        from: data
                      ) else {
                    continue
                }
                records.append(record)
            }
        }
        return Array(records.suffix(limit))
    }

    func clear() throws {
        guard FileManager.default.fileExists(atPath: directoryURL.path) else {
            return
        }
        try FileManager.default.removeItem(at: directoryURL)
    }

    private var currentFileURL: URL {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM"
        return directoryURL.appendingPathComponent(
            "sessions-\(formatter.string(from: Date())).jsonl"
        )
    }

    private func historyFiles() throws -> [URL] {
        guard FileManager.default.fileExists(atPath: directoryURL.path) else {
            return []
        }
        return try FileManager.default.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey]
        )
        .filter { $0.lastPathComponent.hasSuffix(".jsonl") }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private func enforceSizeLimit() throws {
        var files = try historyFiles()
        var total = try files.reduce(UInt64(0)) { partial, url in
            let values = try url.resourceValues(forKeys: [.fileSizeKey])
            return partial + UInt64(values.fileSize ?? 0)
        }
        while total > maxBytes, let oldest = files.first {
            let values = try oldest.resourceValues(forKeys: [.fileSizeKey])
            try FileManager.default.removeItem(at: oldest)
            total -= UInt64(values.fileSize ?? 0)
            files.removeFirst()
            logger.notice("Removed old history file \(oldest.lastPathComponent, privacy: .public)")
        }
    }

    static var defaultDirectoryURL: URL {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!
        return appSupport
            .appendingPathComponent("LocalVoice", isDirectory: true)
            .appendingPathComponent("history", isDirectory: true)
    }
}

private extension JSONEncoder {
    static var localVoiceHistory: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

private extension JSONDecoder {
    static var localVoiceHistory: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
