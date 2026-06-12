import Testing
@testable import LocalVoiceCore

@Test func removesChineseFillersWithoutChangingMeaningfulDemonstrative() {
    #expect(TextCorrector.correct("嗯，那个……我们开始", language: .chinese) == "我们开始")
    #expect(TextCorrector.correct("那个今天下午开会", language: .chinese) == "今天下午开会")
    #expect(TextCorrector.correct("那个方案可行", language: .chinese) == "那个方案可行")
}

@Test func removesEnglishFillersAndCapitalizesSentence() {
    #expect(TextCorrector.correct("um, you know, we should start", language: .english) == "We should start")
    #expect(TextCorrector.correct("Well, we should start", language: .english) == "We should start")
}

@Test func removesAdjacentRepeatedPhrase() {
    #expect(TextCorrector.correct("我们需要 我们需要 尽快发布", language: .chinese) == "我们需要尽快发布")
}
