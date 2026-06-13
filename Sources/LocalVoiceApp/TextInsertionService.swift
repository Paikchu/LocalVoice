import AppKit
import LocalVoiceCore
import OSLog

@MainActor
final class TextInsertionService {
    private var target: InsertionTarget?
    private var pendingPasteboardItems: [PasteboardItemSnapshot]?
    private var pendingInsertionTask: Task<Void, Never>?
    private var restoreTask: Task<Void, Never>?
    private let logger = Logger(
        subsystem: "com.localvoice.app",
        category: "insertion"
    )

    func captureTarget() {
        pendingInsertionTask?.cancel()
        pendingInsertionTask = nil
        target = NSWorkspace.shared.frontmostApplication.map {
            InsertionTarget(applicationPID: $0.processIdentifier)
        }
        logger.info(
            "Captured insertion target pid=\(self.target?.applicationPID ?? -1)"
        )
    }

    func insert(
        _ document: FormattedDocument,
        completion: @escaping (Bool) -> Void
    ) {
        let text = document.plainText
        guard !text.isEmpty, let target else {
            completion(false)
            return
        }
        let request = ConfirmedInsertionRequest(text: text, target: target)
        guard request.canAttemptInsertion(
            accessibilityGranted: PermissionCoordinator.accessibilityGranted
        ) else {
            logger.error("Insertion blocked: Accessibility permission missing")
            _ = PermissionCoordinator.requestAccessibility()
            completion(false)
            return
        }
        let currentPID = NSWorkspace.shared.frontmostApplication?
            .processIdentifier

        if request.requiresActivation(currentApplicationPID: currentPID) {
            guard let application = NSRunningApplication(
                processIdentifier: target.applicationPID
            ) else {
                completion(false)
                return
            }
            application.activate()
        }

        pendingInsertionTask?.cancel()
        pendingInsertionTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(100))
            guard !Task.isCancelled else { return }
            self?.logger.info(
                "Inserting confirmed transcript characters=\(text.count)"
            )
            self?.paste(document)
            self?.pendingInsertionTask = nil
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            completion(true)
        }
    }

    private func paste(_ document: FormattedDocument) {
        let pasteboard = NSPasteboard.general
        if pendingPasteboardItems == nil {
            pendingPasteboardItems = pasteboard.pasteboardItems?
                .map(PasteboardItemSnapshot.init)
        }
        restoreTask?.cancel()
        pasteboard.clearContents()
        let item = NSPasteboardItem()
        item.setString(document.plainText, forType: .string)
        item.setData(Data(document.html.utf8), forType: .html)
        if let rtf = Self.rtfData(for: document.plainText) {
            item.setData(rtf, forType: .rtf)
        }
        pasteboard.writeObjects([item])
        let insertionChangeCount = pasteboard.changeCount

        let source = CGEventSource(stateID: .combinedSessionState)
        let keyDown = CGEvent(
            keyboardEventSource: source,
            virtualKey: 9,
            keyDown: true
        )
        let keyUp = CGEvent(
            keyboardEventSource: source,
            virtualKey: 9,
            keyDown: false
        )
        keyDown?.flags = .maskCommand
        keyUp?.flags = .maskCommand
        keyDown?.post(tap: .cghidEventTap)
        keyUp?.post(tap: .cghidEventTap)

        restoreTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(700))
            guard !Task.isCancelled else { return }
            let pasteboard = NSPasteboard.general
            if pasteboard.changeCount == insertionChangeCount {
                pasteboard.clearContents()
                if let previousItems = self?.pendingPasteboardItems {
                    pasteboard.writeObjects(previousItems.map(\.pasteboardItem))
                }
            }
            self?.pendingPasteboardItems = nil
            self?.restoreTask = nil
        }
    }

    private static func rtfData(for text: String) -> Data? {
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.firstLineHeadIndent = 0
        paragraphStyle.headIndent = 0
        paragraphStyle.tailIndent = 0
        paragraphStyle.paragraphSpacing = 8
        paragraphStyle.lineSpacing = 2

        let attributed = NSAttributedString(
            string: text,
            attributes: [
                .font: NSFont.systemFont(ofSize: 13),
                .paragraphStyle: paragraphStyle
            ]
        )
        return try? attributed.data(
            from: NSRange(location: 0, length: attributed.length),
            documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]
        )
    }
}

private struct PasteboardItemSnapshot {
    let values: [(NSPasteboard.PasteboardType, Data)]

    init(_ item: NSPasteboardItem) {
        values = item.types.compactMap { type in
            item.data(forType: type).map { (type, $0) }
        }
    }

    var pasteboardItem: NSPasteboardItem {
        let item = NSPasteboardItem()
        for (type, data) in values {
            item.setData(data, forType: type)
        }
        return item
    }
}
