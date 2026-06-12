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
