import Testing
@testable import LocalVoiceCore

@Test func recognitionUpdatesPreviewWithoutCreatingInsertion() {
    var draft = DictationDraft()

    draft.updatePreview("跨应用")
    draft.updatePreview("跨应用语音输入")

    #expect(draft.previewText == "跨应用语音输入")
    #expect(!draft.isConfirmed)
}

@Test func confirmationReturnsLatestPreviewOnlyOnce() {
    var draft = DictationDraft()
    draft.updatePreview("跨应用语音输入测试")

    #expect(draft.confirm() == "跨应用语音输入测试")
    #expect(draft.confirm() == nil)
}

@Test func cancellationClearsPreviewWithoutInsertion() {
    var draft = DictationDraft()
    draft.updatePreview("不应写入")

    draft.cancel()

    #expect(draft.previewText.isEmpty)
    #expect(draft.confirm() == nil)
}
