import AppKit
import Carbon.HIToolbox
import LocalVoiceCore

final class HotkeyController {
    var onShortcut: ((KeyboardShortcut) -> Bool)?
    var isRecordingShortcut: (() -> Bool)?

    private static let signature: OSType = 0x4C564F49
    private var shortcuts: ShortcutPair?
    private var eventHandler: EventHandlerRef?
    private var registeredHotkeys: [EventHotKeyRef] = []
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
    }

    func setShortcuts(_ shortcuts: ShortcutPair) {
        self.shortcuts = shortcuts
        guard eventHandler != nil else { return }
        registerShortcuts()
    }

    func stop() {
        unregisterShortcuts()
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

    private func handleRegisteredHotkey(id: UInt32) {
        guard let shortcuts else { return }
        let mode: VoiceMode = id == 1 ? .dictation : .english
        _ = onShortcut?(shortcuts.shortcut(for: mode))
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
            modifiers: modifiers
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
}
