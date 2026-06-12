import AppKit
import LocalVoiceCore

final class HotkeyController {
    var onShortcut: ((KeyboardShortcut) -> Bool)?

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    func start() {
        guard eventTap == nil else { return }

        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, userInfo in
            guard let userInfo else { return Unmanaged.passUnretained(event) }
            let controller = Unmanaged<HotkeyController>
                .fromOpaque(userInfo)
                .takeUnretainedValue()

            if type == .tapDisabledByTimeout,
               let tap = controller.eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
                return Unmanaged.passUnretained(event)
            }
            guard type == .keyDown else {
                return Unmanaged.passUnretained(event)
            }

            let shortcut = controller.shortcut(from: event)
            let handled = controller.onShortcut?(shortcut) ?? false
            return handled ? nil : Unmanaged.passUnretained(event)
        }

        let userInfo = Unmanaged.passUnretained(self).toOpaque()
        eventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: callback,
            userInfo: userInfo
        )

        guard let eventTap else { return }
        runLoopSource = CFMachPortCreateRunLoopSource(nil, eventTap, 0)
        if let runLoopSource {
            CFRunLoopAddSource(
                CFRunLoopGetMain(),
                runLoopSource,
                .commonModes
            )
        }
        CGEvent.tapEnable(tap: eventTap, enable: true)
    }

    func stop() {
        if let runLoopSource {
            CFRunLoopRemoveSource(
                CFRunLoopGetMain(),
                runLoopSource,
                .commonModes
            )
        }
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
        }
        runLoopSource = nil
        eventTap = nil
    }

    private func shortcut(from event: CGEvent) -> KeyboardShortcut {
        var modifiers: ShortcutModifiers = []
        let flags = event.flags
        if flags.contains(.maskCommand) { modifiers.insert(.command) }
        if flags.contains(.maskShift) { modifiers.insert(.shift) }
        if flags.contains(.maskAlternate) { modifiers.insert(.option) }
        if flags.contains(.maskControl) { modifiers.insert(.control) }

        return KeyboardShortcut(
            keyCode: UInt16(
                event.getIntegerValueField(.keyboardEventKeycode)
            ),
            modifiers: modifiers
        )
    }
}
