import Testing
@testable import LocalVoiceCore

@Test func commitsPrefixAfterTwoMatchingHypotheses() {
    var assembler = StableTextAssembler(requiredMatches: 2)

    #expect(assembler.consume("今天我们讨论产品路线").committed.isEmpty)
    let update = assembler.consume("今天我们讨论产品路线和计划")

    #expect(update.committed == "今天我们讨论产品路线")
    #expect(update.unstable == "和计划")
}

@Test func neverCommitsTheSamePrefixTwice() {
    var assembler = StableTextAssembler(requiredMatches: 2)
    _ = assembler.consume("hello world")
    _ = assembler.consume("hello world again")
    let update = assembler.consume("hello world again today")

    #expect(update.committed == " again")
}

@Test func finalizesOnlyRemainingTail() {
    var assembler = StableTextAssembler(requiredMatches: 2)
    _ = assembler.consume("hello world")
    _ = assembler.consume("hello world again")

    #expect(assembler.finalize("hello world again") == " again")
}

@Test func realtimeProjectionReplacesRevisedHypothesis() {
    var projection = RealtimeTextProjection()

    #expect(projection.update("今天下午") == "今天下午")
    #expect(projection.update("今天上午开会") == "今天上午开会")
    #expect(projection.currentText == "今天上午开会")
}

@Test func latestTextBufferCoalescesPendingUpdates() {
    var buffer = LatestTextBuffer<String>()

    buffer.submit("我们")
    #expect(buffer.takeLatest() == "我们")
    buffer.submit("我们明天")
    buffer.submit("我们明天下午开会")
    #expect(buffer.takeLatest() == "我们明天下午开会")
    #expect(buffer.takeLatest() == nil)
}
