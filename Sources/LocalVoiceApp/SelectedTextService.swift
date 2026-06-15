import AppKit
import LocalVoiceCore
import OSLog

@MainActor
struct SelectedTextCapture {
    private static let logger = Logger(
        subsystem: "com.localvoice.app",
        category: "selected-text"
    )

    let request: SelectedTextTranslationRequest

    private let element: AXUIElement
    private let selectedRange: CFRange

    init(
        request: SelectedTextTranslationRequest,
        element: AXUIElement,
        selectedRange: CFRange
    ) {
        self.request = request
        self.element = element
        self.selectedRange = selectedRange
    }

    func isCurrent(currentApplicationPID: Int32?) -> Bool {
        guard currentApplicationPID == request.target.applicationPID else {
            Self.logger.notice(
                "Selection check failed: frontmost pid changed"
            )
            return false
        }

        let systemWide = AXUIElementCreateSystemWide()
        var focusedValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            systemWide,
            kAXFocusedUIElementAttribute as CFString,
            &focusedValue
        ) == .success,
              let focusedValue,
              CFGetTypeID(focusedValue) == AXUIElementGetTypeID() else {
            Self.logger.notice(
                "Selection check failed: focused element unavailable"
            )
            return false
        }
        guard CFEqual(
            unsafeDowncast(focusedValue, to: AXUIElement.self),
            element
        ) else {
            Self.logger.notice(
                "Selection check failed: focused element identity changed"
            )
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
            Self.logger.notice(
                "Selection check failed: selected range unavailable"
            )
            return false
        }
        let axRange = unsafeDowncast(selectedRangeValue, to: AXValue.self)
        var currentRange = CFRange()
        guard AXValueGetValue(axRange, .cfRange, &currentRange) else {
            Self.logger.notice(
                "Selection check failed: selected range unreadable"
            )
            return false
        }
        guard currentRange.location == selectedRange.location,
              currentRange.length == selectedRange.length else {
            Self.logger.notice(
                "Selection check failed: selected range changed"
            )
            return false
        }

        var selectedTextValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXSelectedTextAttribute as CFString,
            &selectedTextValue
        ) == .success else {
            Self.logger.notice(
                "Selection check failed: selected text unavailable"
            )
            return false
        }
        let canReplace = request.canReplace(
            currentApplicationPID: currentApplicationPID,
            currentSelectedText: selectedTextValue as? String
        )
        if !canReplace {
            Self.logger.notice(
                "Selection check failed: selected text changed"
            )
        }
        return canReplace
    }
}

@MainActor
final class SelectedTextService {
    func captureChineseSelection() -> SelectedTextCapture? {
        guard PermissionCoordinator.accessibilityGranted else { return nil }

        let systemWide = AXUIElementCreateSystemWide()
        var focusedValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            systemWide,
            kAXFocusedUIElementAttribute as CFString,
            &focusedValue
        ) == .success,
              let focusedValue,
              CFGetTypeID(focusedValue) == AXUIElementGetTypeID() else {
            return nil
        }
        let element = unsafeDowncast(focusedValue, to: AXUIElement.self)

        var selectedTextValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXSelectedTextAttribute as CFString,
            &selectedTextValue
        ) == .success,
              let selectedText = selectedTextValue as? String else {
            return nil
        }

        var selectedRangeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXSelectedTextRangeAttribute as CFString,
            &selectedRangeValue
        ) == .success,
              let selectedRangeValue,
              CFGetTypeID(selectedRangeValue) == AXValueGetTypeID() else {
            return nil
        }
        let axRange = unsafeDowncast(selectedRangeValue, to: AXValue.self)
        var selectedRange = CFRange()
        guard AXValueGetValue(axRange, .cfRange, &selectedRange),
              selectedRange.length > 0 else {
            return nil
        }

        var pid: pid_t = 0
        guard AXUIElementGetPid(element, &pid) == .success,
              let request = SelectedTextTranslationRequest(
                selectedText: selectedText,
                target: InsertionTarget(applicationPID: pid)
              ) else {
            return nil
        }

        return SelectedTextCapture(
            request: request,
            element: element,
            selectedRange: selectedRange
        )
    }
}
