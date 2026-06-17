import Testing
@testable import LocalVoiceCore

@Test func rejectsShortcutWithoutModifier() {
    let shortcut = KeyboardShortcut(keyCode: 2, modifiers: [])

    #expect(shortcut.validationError != nil)
}

@Test func rejectsDuplicateShortcuts() {
    let dictation = KeyboardShortcut(keyCode: 2, modifiers: [.command, .shift])
    let english = KeyboardShortcut(keyCode: 2, modifiers: [.command, .shift])

    #expect(ShortcutPair(dictation: dictation, english: english).validationError != nil)
}

@Test func rendersShortcutForMenu() {
    let shortcut = KeyboardShortcut(keyCode: 2, modifiers: [.command, .shift])

    #expect(shortcut.displayString == "⌘⇧D")
}

@Test func matchesOnlyConfiguredGlobalShortcuts() {
    let pair = ShortcutPair(
        dictation: KeyboardShortcut(
            keyCode: 2,
            modifiers: [.command, .shift]
        ),
        english: KeyboardShortcut(
            keyCode: 14,
            modifiers: [.command, .shift]
        )
    )

    #expect(
        pair.mode(
            matching: KeyboardShortcut(
                keyCode: 0,
                modifiers: []
            )
        ) == nil
    )
    #expect(pair.mode(matching: pair.dictation) == .dictation)
    #expect(pair.mode(matching: pair.english) == .english)
}

@Test func resolvesShortcutForGlobalHotkeyRegistration() {
    let pair = ShortcutPair(
        dictation: KeyboardShortcut(
            keyCode: 2,
            modifiers: [.command, .shift]
        ),
        english: KeyboardShortcut(
            keyCode: 14,
            modifiers: [.command, .shift]
        )
    )

    #expect(pair.shortcut(for: .dictation) == pair.dictation)
    #expect(pair.shortcut(for: .english) == pair.english)
}

@Test func recordingDoesNotDependOnAccessibilityPermission() {
    let permissions = VoicePermissionState(
        microphoneGranted: true,
        speechRecognitionGranted: true,
        accessibilityGranted: false
    )

    #expect(permissions.canRecord)
    #expect(!permissions.canInsertText)
}

@Test func playsActivationSoundWhenRecordingShortcutStartsOrFinishes() {
    #expect(
        DictationActivationSoundPolicy.shouldPlay(
            currentState: .ready,
            shortcutMode: .dictation
        )
    )
    #expect(
        DictationActivationSoundPolicy.shouldPlay(
            currentState: .listening(.dictation),
            shortcutMode: .dictation
        )
    )
}

@Test func skipsActivationSoundWhenShortcutCannotChangeRecordingState() {
    #expect(
        !DictationActivationSoundPolicy.shouldPlay(
            currentState: .processing(.dictation),
            shortcutMode: .dictation
        )
    )
    #expect(
        !DictationActivationSoundPolicy.shouldPlay(
            currentState: .inserting(.english),
            shortcutMode: .english
        )
    )
}

@Test func activationSoundUsesCrispSystemCue() {
    #expect(DictationActivationSoundPolicy.soundName == "Glass")
}

@Test func activationSoundSettingsDefaultToEnabledGlass() {
    let settings = DictationActivationSoundSettings()

    #expect(settings.isEnabled)
    #expect(settings.option == .glass)
    #expect(settings.soundName == "Glass")
}

@Test func activationSoundOptionsExposeSeveralSystemCues() {
    #expect(DictationActivationSoundOption.allCases.count >= 4)
    #expect(
        DictationActivationSoundOption.allCases.map(\.systemSoundName)
            .contains("Ping")
    )
}

@Test func disabledActivationSoundDoesNotPlayForShortcut() {
    #expect(
        !DictationActivationSoundPolicy.shouldPlay(
            currentState: .ready,
            shortcutMode: .dictation,
            settings: DictationActivationSoundSettings(isEnabled: false)
        )
    )
}
