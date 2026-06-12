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
