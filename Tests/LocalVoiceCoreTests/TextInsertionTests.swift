import Testing
@testable import LocalVoiceCore

@Test func fallbackReactivatesTargetAfterPermissionPromptStealsFocus() {
    let target = InsertionTarget(applicationPID: 42)

    #expect(target.requiresActivation(currentApplicationPID: 84))
    #expect(!target.requiresActivation(currentApplicationPID: 42))
}

@Test func confirmedInsertionUsesPasteboardForEveryTargetApplication() {
    let request = ConfirmedInsertionRequest(
        text: "跨应用语音输入测试",
        target: InsertionTarget(applicationPID: 42)
    )

    #expect(request.route == .pasteboard)
    #expect(request.requiresActivation(currentApplicationPID: 84))
    #expect(!request.requiresActivation(currentApplicationPID: 42))
}

@Test func rebuiltUntrustedAppRequestsAccessibilityAgain() {
    #expect(AccessibilityPromptPolicy.shouldPrompt(isTrusted: false))
    #expect(!AccessibilityPromptPolicy.shouldPrompt(isTrusted: true))
}

@Test func insertionRequiresCurrentAccessibilityTrust() {
    let request = ConfirmedInsertionRequest(
        text: "Claude cursor insertion",
        target: InsertionTarget(applicationPID: 42)
    )

    #expect(!request.canAttemptInsertion(accessibilityGranted: false))
    #expect(request.canAttemptInsertion(accessibilityGranted: true))
}

@Test func changedSelectionFallsBackToClipboard() {
    #expect(
        TextInsertionPolicy.destination(
            accessibilityGranted: true,
            requiresCurrentSelection: true,
            selectionIsCurrent: false,
            cursorIsAvailable: true
        ) == .clipboard
    )
}

@Test func missingVoiceCursorFallsBackToClipboard() {
    #expect(
        TextInsertionPolicy.destination(
            accessibilityGranted: true,
            requiresCurrentSelection: false,
            selectionIsCurrent: true,
            cursorIsAvailable: false
        ) == .clipboard
    )
}

@Test func unknownVoiceCursorStillAttemptsPasteboardInsertion() {
    #expect(
        TextInsertionPolicy.destination(
            accessibilityGranted: true,
            requiresCurrentSelection: false,
            selectionIsCurrent: true,
            cursorAvailability: .unknown
        ) == .target
    )
}

@Test func currentTargetUsesPasteboardInsertion() {
    #expect(
        TextInsertionPolicy.destination(
            accessibilityGranted: true,
            requiresCurrentSelection: true,
            selectionIsCurrent: true,
            cursorIsAvailable: true
        ) == .target
    )
    #expect(
        TextInsertionPolicy.destination(
            accessibilityGranted: true,
            requiresCurrentSelection: false,
            selectionIsCurrent: true,
            cursorIsAvailable: true
        ) == .target
    )
}

@Test func missingAccessibilityFallsBackToClipboard() {
    #expect(
        TextInsertionPolicy.destination(
            accessibilityGranted: false,
            requiresCurrentSelection: false,
            selectionIsCurrent: true,
            cursorIsAvailable: true
        ) == .clipboard
    )
}

@Test func selectedChineseTextCreatesTranslationRequest() {
    let request = SelectedTextTranslationRequest(
        selectedText: "  请明天下午三点提醒我开会。  ",
        target: InsertionTarget(applicationPID: 42)
    )

    #expect(request?.sourceText == "请明天下午三点提醒我开会。")
    #expect(request?.target.applicationPID == 42)
    #expect(
        request?.matchesCurrentSelection(
            "  请明天下午三点提醒我开会。  "
        ) == true
    )
    #expect(request?.matchesCurrentSelection("另一段文字") == false)
    #expect(
        request?.replacementText(
            for: "Please remind me about the meeting tomorrow at 3 PM."
        ) == "  Please remind me about the meeting tomorrow at 3 PM.  "
    )
    #expect(
        request?.canReplace(
            currentApplicationPID: 42,
            currentSelectedText: "  请明天下午三点提醒我开会。  "
        ) == true
    )
    #expect(
        request?.canReplace(
            currentApplicationPID: 84,
            currentSelectedText: "  请明天下午三点提醒我开会。  "
        ) == false
    )
}

@Test func emptyOrNonChineseSelectionDoesNotCreateTranslationRequest() {
    #expect(
        SelectedTextTranslationRequest(
            selectedText: "   ",
            target: InsertionTarget(applicationPID: 42)
        ) == nil
    )
    #expect(
        SelectedTextTranslationRequest(
            selectedText: "already English",
            target: InsertionTarget(applicationPID: 42)
        ) == nil
    )
}

@Test func selectedTextReplacementRequiresValidEnglishOutput() {
    #expect(
        SelectedTextTranslationValidator.replacement(
            output: "Please remind me about the meeting tomorrow at 3 PM.",
            usedFallback: false
        ) == "Please remind me about the meeting tomorrow at 3 PM."
    )
    #expect(
        SelectedTextTranslationValidator.replacement(
            output: "请明天下午三点提醒我开会。",
            usedFallback: true
        ) == nil
    )
    #expect(
        SelectedTextTranslationValidator.replacement(
            output: "Please remind 我 about the meeting.",
            usedFallback: false
        ) == nil
    )
}
