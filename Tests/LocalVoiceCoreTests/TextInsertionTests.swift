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
