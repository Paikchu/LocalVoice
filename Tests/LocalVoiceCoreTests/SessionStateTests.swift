import Testing
@testable import LocalVoiceCore

@Test func sessionTransitionsFromReadyToListeningAndBack() {
    var machine = SessionStateMachine()

    #expect(machine.handle(.start(.dictation)) == .listening(.dictation))
    #expect(machine.handle(.finish) == .finalizing(.dictation))
    #expect(machine.handle(.completed) == .ready)
}

@Test func failedSessionCanStartListeningAgain() {
    var machine = SessionStateMachine()
    _ = machine.handle(.fail("No speech detected"))

    #expect(machine.handle(.start(.english)) == .listening(.english))
}

@Test func switchingModeFinalizesCurrentSessionFirst() {
    var machine = SessionStateMachine()
    _ = machine.handle(.start(.dictation))

    #expect(machine.handle(.start(.english)) == .finalizing(.dictation))
    #expect(machine.pendingMode == .english)
}

@Test func finishDuringModeSwitchCancelsPendingRestart() {
    var machine = SessionStateMachine()
    _ = machine.handle(.start(.dictation))
    _ = machine.handle(.start(.english))

    #expect(machine.handle(.finish) == .finalizing(.dictation))
    #expect(machine.pendingMode == nil)
    #expect(machine.handle(.completed) == .ready)
}

@Test func copiedFallbackCompletionCancelsPendingRestart() {
    var machine = SessionStateMachine()
    _ = machine.handle(.start(.dictation))
    _ = machine.handle(.start(.english))
    _ = machine.handle(.finalTranscriptReady)
    _ = machine.handle(.processingSucceeded)

    #expect(machine.pendingMode == .english)
    #expect(machine.handle(.completed) == .ready)
    #expect(machine.pendingMode == nil)
}

@Test func intentionalRecognitionStopKeepsFinalResultsAndSuppressesErrors() {
    let gate = RecognitionSessionGate()
    let session = gate.begin()

    gate.stop(session)

    #expect(gate.shouldDeliverResult(for: session))
    #expect(!gate.shouldDeliverError(for: session))
}

@Test func newRecognitionSessionRejectsCallbacksFromPreviousSession() {
    let gate = RecognitionSessionGate()
    let previous = gate.begin()
    let current = gate.begin()

    #expect(!gate.shouldDeliverResult(for: previous))
    #expect(!gate.shouldDeliverError(for: previous))
    #expect(gate.shouldDeliverResult(for: current))
    #expect(gate.shouldDeliverError(for: current))
}

@Test func finishDuringRecordingStartupIsDeliveredAfterStartupCompletes() {
    var gate = RecordingStartupGate()
    let startup = gate.begin()

    gate.requestFinish()

    #expect(gate.actionWhenReady(for: startup) == .startThenFinish)
}

@Test func cancelledRecordingStartupIsDiscarded() {
    var gate = RecordingStartupGate()
    let startup = gate.begin()

    gate.cancel()

    #expect(gate.actionWhenReady(for: startup) == .discard)
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
