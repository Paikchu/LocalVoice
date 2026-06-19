import Foundation
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

@Test func rendersLeftAndRightModifierShortcutsForMenu() {
    let left = KeyboardShortcut(
        keyCode: 14,
        modifiers: [.command],
        modifierSides: [.leftCommand]
    )
    let right = KeyboardShortcut(
        keyCode: 14,
        modifiers: [.command],
        modifierSides: [.rightCommand]
    )

    #expect(left.displayString == "左⌘E")
    #expect(right.displayString == "右⌘E")
}

@Test func distinguishesLeftAndRightModifierShortcuts() {
    let pair = ShortcutPair(
        dictation: KeyboardShortcut(
            keyCode: 14,
            modifiers: [.command],
            modifierSides: [.leftCommand]
        ),
        english: KeyboardShortcut(
            keyCode: 14,
            modifiers: [.command],
            modifierSides: [.rightCommand]
        )
    )

    #expect(pair.validationError == nil)
    #expect(
        pair.mode(
            matching: KeyboardShortcut(
                keyCode: 14,
                modifiers: [.command],
                modifierSides: [.leftCommand]
            )
        ) == .dictation
    )
    #expect(
        pair.mode(
            matching: KeyboardShortcut(
                keyCode: 14,
                modifiers: [.command],
                modifierSides: [.rightCommand]
            )
        ) == .english
    )
}

@Test func legacyGenericModifierShortcutMatchesEitherSide() {
    let shortcut = KeyboardShortcut(keyCode: 14, modifiers: [.command])

    #expect(
        shortcut.matches(
            KeyboardShortcut(
                keyCode: 14,
                modifiers: [.command],
                modifierSides: [.leftCommand]
            )
        )
    )
    #expect(
        shortcut.matches(
            KeyboardShortcut(
                keyCode: 14,
                modifiers: [.command],
                modifierSides: [.rightCommand]
            )
        )
    )
}

@Test func decodesLegacyShortcutWithoutModifierSides() throws {
    let data = Data(
        #"{"keyCode":14,"modifiers":1}"#.utf8
    )

    let shortcut = try JSONDecoder().decode(KeyboardShortcut.self, from: data)

    #expect(shortcut == KeyboardShortcut(keyCode: 14, modifiers: [.command]))
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
