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

@Test func recognitionAccumulatorReplacesRevisedCurrentSegment() {
    var accumulator = RecognitionTranscriptAccumulator()

    _ = accumulator.consume("今天下午开会", isFinal: false)
    let transcript = accumulator.consume(
        "今天下午我们开会",
        isFinal: false
    )

    #expect(transcript == "今天下午我们开会")
}

@Test func recognitionAccumulatorKeepsEarlierSegmentsAfterAReset() {
    var accumulator = RecognitionTranscriptAccumulator()

    _ = accumulator.consume(
        "今天我们进行一段较长的中文语音测试。",
        isFinal: false
    )
    let transcript = accumulator.consume(
        "产品团队需要检查最终文本。",
        isFinal: false
    )

    #expect(
        transcript
            == "今天我们进行一段较长的中文语音测试。产品团队需要检查最终文本。"
    )
}

@Test func recognitionAccumulatorMergesSlidingWindowOverlap() {
    var accumulator = RecognitionTranscriptAccumulator()

    _ = accumulator.consume(
        "工程团队需要检查本地模型不会丢掉后半段",
        isFinal: false
    )
    let transcript = accumulator.consume(
        "不会丢掉后半段并且结尾必须完整保留",
        isFinal: false
    )

    #expect(
        transcript
            == "工程团队需要检查本地模型不会丢掉后半段并且结尾必须完整保留"
    )
}

@Test func recognitionAccumulatorTreatsShortUnrelatedTextAsANewSegment() {
    var accumulator = RecognitionTranscriptAccumulator()

    _ = accumulator.consume("今天我们", isFinal: false)
    let transcript = accumulator.consume("需要", isFinal: false)

    #expect(transcript == "今天我们需要")
}

@Test func recognitionAccumulatorKeepsCurrentPrefixWhenFinalIsASuffix() {
    var accumulator = RecognitionTranscriptAccumulator()

    _ = accumulator.consume(
        "团队需要确认最后完整保留",
        isFinal: false
    )
    let transcript = accumulator.consume(
        "需要确认最后完整保留",
        isFinal: true
    )

    #expect(transcript == "团队需要确认最后完整保留")
}
