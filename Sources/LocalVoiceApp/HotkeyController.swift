import AppKit
import Carbon.HIToolbox
import LocalVoiceCore

final class HotkeyController {
    var onShortcut: ((KeyboardShortcut) -> Bool)?
    var isRecordingShortcut: (() -> Bool)?
    var activeMode: (() -> VoiceMode?)?

    private static let signature: OSType = 0x4C564F49
    private var shortcuts: ShortcutPair?
    private var eventHandler: EventHandlerRef?
    private var registeredHotkeys: [EventHotKeyRef] = []
    private var eventTap: CFMachPort?
    private var eventTapRunLoopSource: CFRunLoopSource?
    private var localMonitor: Any?

    func start() {
        guard eventHandler == nil else { return }

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, userInfo in
                guard let event, let userInfo else { return noErr }
                var hotkeyID = EventHotKeyID()
                let status = GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hotkeyID
                )
                guard status == noErr,
                      hotkeyID.signature == HotkeyController.signature else {
                    return status
                }

                let controller = Unmanaged<HotkeyController>
                    .fromOpaque(userInfo)
                    .takeUnretainedValue()
                controller.handleRegisteredHotkey(id: hotkeyID.id)
                return noErr
            },
            1,
            &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            &eventHandler
        )

        localMonitor = NSEvent.addLocalMonitorForEvents(
            matching: .keyDown
        ) { [weak self] event in
            guard let self,
                  isRecordingShortcut?() == true else {
                return event
            }

            let handled = onShortcut?(shortcut(from: event)) ?? false
            return handled ? nil : event
        }

        registerShortcuts()
        configureEventTap()
    }

    func setShortcuts(_ shortcuts: ShortcutPair) {
        self.shortcuts = shortcuts
        guard eventHandler != nil else { return }
        registerShortcuts()
        configureEventTap()
    }

    func stop() {
        unregisterShortcuts()
        stopEventTap()
        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
        }
        if let eventHandler {
            RemoveEventHandler(eventHandler)
        }
        localMonitor = nil
        eventHandler = nil
    }

    private func registerShortcuts() {
        unregisterShortcuts()
        guard let shortcuts else { return }

        let modes: [(UInt32, VoiceMode)] = [
            (1, .dictation),
            (2, .english)
        ]
        for (id, mode) in modes {
            let shortcut = shortcuts.shortcut(for: mode)
            guard shortcut.modifierSides.isEmpty else { continue }
            var hotkey: EventHotKeyRef?
            let hotkeyID = EventHotKeyID(
                signature: Self.signature,
                id: id
            )
            let status = RegisterEventHotKey(
                UInt32(shortcut.keyCode),
                carbonModifiers(for: shortcut.modifiers),
                hotkeyID,
                GetApplicationEventTarget(),
                0,
                &hotkey
            )
            if status == noErr, let hotkey {
                registeredHotkeys.append(hotkey)
            }
        }
    }

    private func unregisterShortcuts() {
        for hotkey in registeredHotkeys {
            UnregisterEventHotKey(hotkey)
        }
        registeredHotkeys.removeAll()
    }

    private func configureEventTap() {
        stopEventTap()
        guard let shortcuts,
              shortcuts.containsSideSpecificShortcut else {
            return
        }

        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, userInfo in
                guard let userInfo else {
                    return Unmanaged.passUnretained(event)
                }
                let controller = Unmanaged<HotkeyController>
                    .fromOpaque(userInfo)
                    .takeUnretainedValue()
                return controller.handleEventTap(
                    type: type,
                    event: event
                )
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            return
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        eventTap = tap
        eventTapRunLoopSource = source
    }

    private func stopEventTap() {
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
        }
        if let eventTapRunLoopSource {
            CFRunLoopRemoveSource(
                CFRunLoopGetMain(),
                eventTapRunLoopSource,
                .commonModes
            )
        }
        eventTap = nil
        eventTapRunLoopSource = nil
    }

    private func handleEventTap(
        type: CGEventType,
        event: CGEvent
    ) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let eventTap {
                CGEvent.tapEnable(tap: eventTap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }

        guard type == .keyDown,
              let shortcuts else {
            return Unmanaged.passUnretained(event)
        }

        let eventShortcut = shortcut(from: event)
        guard let mode = shortcuts.mode(
            matching: eventShortcut,
            activeMode: activeMode?()
        ) else {
            return Unmanaged.passUnretained(event)
        }

        let handled = onShortcut?(shortcuts.shortcut(for: mode)) ?? false
        return handled ? nil : Unmanaged.passUnretained(event)
    }

    private func handleRegisteredHotkey(id: UInt32) {
        guard let shortcuts else { return }
        let mode: VoiceMode = id == 1 ? .dictation : .english
        _ = onShortcut?(shortcuts.shortcut(for: mode))
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
            modifiers: modifiers,
            modifierSides: modifierSides(fromRawFlags: flags.rawValue)
        )
    }

    private func carbonModifiers(
        for modifiers: ShortcutModifiers
    ) -> UInt32 {
        var value: UInt32 = 0
        if modifiers.contains(.command) { value |= UInt32(cmdKey) }
        if modifiers.contains(.shift) { value |= UInt32(shiftKey) }
        if modifiers.contains(.option) { value |= UInt32(optionKey) }
        if modifiers.contains(.control) { value |= UInt32(controlKey) }
        return value
    }

    private func shortcut(from event: NSEvent) -> KeyboardShortcut {
        var modifiers: ShortcutModifiers = []
        let flags = event.modifierFlags
            .intersection(.deviceIndependentFlagsMask)
        if flags.contains(.command) { modifiers.insert(.command) }
        if flags.contains(.shift) { modifiers.insert(.shift) }
        if flags.contains(.option) { modifiers.insert(.option) }
        if flags.contains(.control) { modifiers.insert(.control) }

        return KeyboardShortcut(
            keyCode: event.keyCode,
            modifiers: modifiers,
            modifierSides: modifierSides(
                fromRawFlags: UInt64(event.modifierFlags.rawValue)
            )
        )
    }

    private func modifierSides(fromRawFlags rawFlags: UInt64)
        -> ShortcutModifierSides {
        var sides: ShortcutModifierSides = []
        if rawFlags & SideModifierMask.leftControl != 0 {
            sides.insert(.leftControl)
        }
        if rawFlags & SideModifierMask.rightControl != 0 {
            sides.insert(.rightControl)
        }
        if rawFlags & SideModifierMask.leftShift != 0 {
            sides.insert(.leftShift)
        }
        if rawFlags & SideModifierMask.rightShift != 0 {
            sides.insert(.rightShift)
        }
        if rawFlags & SideModifierMask.leftCommand != 0 {
            sides.insert(.leftCommand)
        }
        if rawFlags & SideModifierMask.rightCommand != 0 {
            sides.insert(.rightCommand)
        }
        if rawFlags & SideModifierMask.leftOption != 0 {
            sides.insert(.leftOption)
        }
        if rawFlags & SideModifierMask.rightOption != 0 {
            sides.insert(.rightOption)
        }
        return sides
    }

    private enum SideModifierMask {
        static let leftControl: UInt64 = 0x00000001
        static let leftShift: UInt64 = 0x00000002
        static let rightShift: UInt64 = 0x00000004
        static let leftCommand: UInt64 = 0x00000008
        static let rightCommand: UInt64 = 0x00000010
        static let leftOption: UInt64 = 0x00000020
        static let rightOption: UInt64 = 0x00000040
        static let rightControl: UInt64 = 0x00002000
    }
}

private extension ShortcutPair {
    var containsSideSpecificShortcut: Bool {
        !dictation.modifierSides.isEmpty || !english.modifierSides.isEmpty
    }
}
