import AppKit

@MainActor
final class TextInsertionService {
    private var targetApplicationPID: pid_t?
    private var targetElement: AXUIElement?
    private var insertionLocation: CFIndex?
    private var insertedUTF16Length = 0
    private var usedFallback = false
    private var pendingPasteboardItems: [PasteboardItemSnapshot]?
    private var restoreTask: Task<Void, Never>?

    func captureTarget() {
        targetApplicationPID = NSWorkspace.shared.frontmostApplication?
            .processIdentifier

        let systemWide = AXUIElementCreateSystemWide()
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(
            systemWide,
            kAXFocusedUIElementAttribute as CFString,
            &value
        )
        if result == .success, let value {
            targetElement = unsafeDowncast(value, to: AXUIElement.self)
            insertionLocation = selectedTextRange(of: targetElement)
        } else {
            targetElement = nil
            insertionLocation = nil
        }
        insertedUTF16Length = 0
        usedFallback = false
    }

    func update(_ text: String, isFinal: Bool) {
        guard !text.isEmpty,
              NSWorkspace.shared.frontmostApplication?.processIdentifier
                == targetApplicationPID else {
            return
        }

        if replaceSessionText(text) {
            return
        }

        if isFinal, !usedFallback {
            usedFallback = true
            paste(text)
        }
    }

    private func selectedTextRange(of element: AXUIElement?) -> CFIndex? {
        guard let element else { return nil }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXSelectedTextRangeAttribute as CFString,
            &value
        ) == .success,
        let value,
        CFGetTypeID(value) == AXValueGetTypeID() else {
            return nil
        }

        var range = CFRange()
        guard AXValueGetValue(
            unsafeDowncast(value, to: AXValue.self),
            .cfRange,
            &range
        ) else {
            return nil
        }
        return range.location
    }

    private func replaceSessionText(_ text: String) -> Bool {
        guard let targetElement, let insertionLocation else { return false }

        var range = CFRange(
            location: insertionLocation,
            length: insertedUTF16Length
        )
        guard let rangeValue = AXValueCreate(.cfRange, &range),
              AXUIElementSetAttributeValue(
                targetElement,
                kAXSelectedTextRangeAttribute as CFString,
                rangeValue
              ) == .success,
              AXUIElementSetAttributeValue(
                targetElement,
                kAXSelectedTextAttribute as CFString,
                text as CFTypeRef
              ) == .success else {
            return false
        }

        insertedUTF16Length = text.utf16.count
        return true
    }

    private func paste(_ text: String) {
        let pasteboard = NSPasteboard.general
        if pendingPasteboardItems == nil {
            pendingPasteboardItems = pasteboard.pasteboardItems?
                .map(PasteboardItemSnapshot.init)
        }
        restoreTask?.cancel()
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

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
        keyDown?.post(tap: .cgAnnotatedSessionEventTap)
        keyUp?.post(tap: .cgAnnotatedSessionEventTap)

        restoreTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(180))
            guard !Task.isCancelled else { return }
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            if let previousItems = self?.pendingPasteboardItems {
                pasteboard.writeObjects(previousItems.map(\.pasteboardItem))
            }
            self?.pendingPasteboardItems = nil
            self?.restoreTask = nil
        }
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
