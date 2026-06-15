import Testing
@testable import LocalVoiceCore

@Test func sessionTransitionsFromReadyToListeningAndBack() {
    var machine = SessionStateMachine()

    #expect(machine.handle(.start(.dictation)) == .listening(.dictation))
    #expect(machine.handle(.finish) == .finalizing(.dictation))
    #expect(machine.handle(.completed) == .ready)
}

@Test func switchingModeFinalizesCurrentSessionFirst() {
    var machine = SessionStateMachine()
    _ = machine.handle(.start(.dictation))

    #expect(machine.handle(.start(.english)) == .finalizing(.dictation))
    #expect(machine.pendingMode == .english)
}

@Test func selectedTextTranslationStartsProcessingWithoutRecording() {
    var machine = SessionStateMachine()

    #expect(machine.handle(.translateSelection) == .processing(.english))
    #expect(machine.handle(.processingSucceeded) == .inserting(.english))
    #expect(machine.handle(.insertionCompleted) == .ready)
}

@Test func selectedTextTranslationCanRestartFromFailedState() {
    var machine = SessionStateMachine()
    _ = machine.handle(.fail("模型未就绪"))

    #expect(machine.handle(.translateSelection) == .processing(.english))
}

@Test func insertionTargetIsCapturedBeforePermissionRequests() {
    var session = DictationStartSequence()

    session.record(.permissionRequest)
    session.record(.targetCapture)

    #expect(session.validationError == "必须在请求权限前捕获文本输入目标")
}

@Test func dictationShortcutNeverPromptsForAccessibility() {
    #expect(!PermissionPromptPolicy.dictationShortcut.promptsForAccessibility)
    #expect(PermissionPromptPolicy.explicitRequest.promptsForAccessibility)
}

@Test func accessibilityPromptIsShownOnlyOnce() {
    var history = AccessibilityPromptHistory()
    let firstPrompt = history.consumePrompt()
    let secondPrompt = history.consumePrompt()

    #expect(firstPrompt)
    #expect(!secondPrompt)
}
