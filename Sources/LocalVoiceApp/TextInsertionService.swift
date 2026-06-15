import AppKit
import LocalVoiceCore
import OSLog

enum TextInsertionResult {
    case inserted
    case copiedToClipboard
    case failed
}

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

    func captureTarget(_ target: InsertionTarget) {
        pendingInsertionTask?.cancel()
        pendingInsertionTask = nil
        self.target = target
        logger.info("Captured insertion target pid=\(target.applicationPID)")
    }

    func cancelPendingInsertion() {
        pendingInsertionTask?.cancel()
        pendingInsertionTask = nil
    }

    func insert(
        _ document: FormattedDocument,
        requiring selection: SelectedTextCapture? = nil,
        completion: @escaping (TextInsertionResult) -> Void
    ) {
        let text = document.plainText
        guard !text.isEmpty else {
            completion(.failed)
            return
        }
        guard let target else {
            completion(
                copyToClipboard(document)
                    ? .copiedToClipboard
                    : .failed
            )
            return
        }
        let request = ConfirmedInsertionRequest(text: text, target: target)
        let accessibilityGranted = PermissionCoordinator.accessibilityGranted
        if !request.canAttemptInsertion(
            accessibilityGranted: accessibilityGranted
        ) {
            logger.notice(
                "Target insertion unavailable: Accessibility permission missing"
            )
            _ = PermissionCoordinator.requestAccessibility()
            completion(
                copyToClipboard(document)
                    ? .copiedToClipboard
                    : .failed
            )
            return
        }
        let currentPID = NSWorkspace.shared.frontmostApplication?
            .processIdentifier

        if let selection,
           !selection.isCurrent(currentApplicationPID: currentPID) {
            logger.notice(
                "Target insertion unavailable: selected text changed"
            )
            completion(
                copyToClipboard(document)
                    ? .copiedToClipboard
                    : .failed
            )
            return
        }

        if request.requiresActivation(currentApplicationPID: currentPID) {
            guard let application = NSRunningApplication(
                processIdentifier: target.applicationPID
            ) else {
                completion(
                    copyToClipboard(document)
                        ? .copiedToClipboard
                        : .failed
                )
                return
            }
            application.activate()
        }

        pendingInsertionTask?.cancel()
        pendingInsertionTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(100))
            guard !Task.isCancelled else { return }
            let currentPID = NSWorkspace.shared.frontmostApplication?
                .processIdentifier
            guard let self else { return }
            let selectionIsCurrent = selection?.isCurrent(
                currentApplicationPID: currentPID
            ) ?? true
            let cursorIsAvailable = selection != nil
                || self.cursorIsAvailable(for: target.applicationPID)
            let destination = TextInsertionPolicy.destination(
                accessibilityGranted:
                    PermissionCoordinator.accessibilityGranted,
                requiresCurrentSelection: selection != nil,
                selectionIsCurrent: selectionIsCurrent,
                cursorIsAvailable: cursorIsAvailable
            )
            if destination == .clipboard {
                self.logger.notice(
                    "Target insertion unavailable: copying result to clipboard"
                )
                self.pendingInsertionTask = nil
                completion(
                    self.copyToClipboard(document)
                        ? .copiedToClipboard
                        : .failed
                )
                return
            }
            self.logger.info(
                "Inserting confirmed transcript characters=\(text.count)"
            )
            guard self.paste(document) else {
                self.pendingInsertionTask = nil
                completion(.failed)
                return
            }
            self.pendingInsertionTask = nil
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            completion(.inserted)
        }
    }

    private func cursorIsAvailable(for applicationPID: Int32) -> Bool {
        let systemWide = AXUIElementCreateSystemWide()
        var focusedValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            systemWide,
            kAXFocusedUIElementAttribute as CFString,
            &focusedValue
        ) == .success,
              let focusedValue,
              CFGetTypeID(focusedValue) == AXUIElementGetTypeID() else {
            return false
        }
        let element = unsafeDowncast(focusedValue, to: AXUIElement.self)
        var pid: pid_t = 0
        guard AXUIElementGetPid(element, &pid) == .success,
              pid == applicationPID else {
            return false
        }

        var selectedRangeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXSelectedTextRangeAttribute as CFString,
            &selectedRangeValue
        ) == .success,
              let selectedRangeValue,
              CFGetTypeID(selectedRangeValue) == AXValueGetTypeID() else {
            return false
        }
        let axRange = unsafeDowncast(selectedRangeValue, to: AXValue.self)
        var range = CFRange()
        return AXValueGetValue(axRange, .cfRange, &range)
    }

    private func copyToClipboard(_ document: FormattedDocument) -> Bool {
        restoreTask?.cancel()
        restoreTask = nil
        pendingPasteboardItems = nil
        return write(document, to: NSPasteboard.general) != nil
    }

    private func paste(_ document: FormattedDocument) -> Bool {
        let pasteboard = NSPasteboard.general
        if pendingPasteboardItems == nil {
            pendingPasteboardItems = pasteboard.pasteboardItems?
                .map(PasteboardItemSnapshot.init)
        }
        restoreTask?.cancel()
        guard let insertionChangeCount = write(document, to: pasteboard) else {
            pendingPasteboardItems = nil
            return false
        }

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
        return true
    }

    private func write(
        _ document: FormattedDocument,
        to pasteboard: NSPasteboard
    ) -> Int? {
        pasteboard.clearContents()
        let item = NSPasteboardItem()
        item.setString(document.plainText, forType: .string)
        item.setData(Data(document.html.utf8), forType: .html)
        if let rtf = Self.rtfData(for: document.plainText) {
            item.setData(rtf, forType: .rtf)
        }
        guard pasteboard.writeObjects([item]) else { return nil }
        return pasteboard.changeCount
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
