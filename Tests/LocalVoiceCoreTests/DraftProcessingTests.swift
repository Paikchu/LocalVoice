import Foundation
import Testing
@testable import LocalVoiceCore

@Test func spokenStructureNormalizerCreatesNumberedList() {
    let output = SpokenStructureNormalizer.normalize(
        "第一点确认需求第二点完成开发第三点安排测试"
    )

    #expect(output == "1. 确认需求\n2. 完成开发\n3. 安排测试")
}

@Test func spokenStructureNormalizerSupportsCommonListMarkers() {
    #expect(
        SpokenStructureNormalizer.normalize(
            "第一个检查日志第二个修复问题第三个发布版本"
        ) == "1. 检查日志\n2. 修复问题\n3. 发布版本"
    )
    #expect(
        SpokenStructureNormalizer.normalize(
            "一是确认范围二是实现功能三是完成验证"
        ) == "1. 确认范围\n2. 实现功能\n3. 完成验证"
    )
}

@Test func spokenStructureNormalizerDoesNotConvertOrdinalContent() {
    let source = "这是第一版，计划第二季度发布，并交给第三方测试。"

    #expect(SpokenStructureNormalizer.normalize(source) == source)
}

@Test func spokenStructureNormalizerConvertsExplicitPunctuationCommands() {
    let output = SpokenStructureNormalizer.normalize(
        "今天完成开发逗号明天开始测试句号是否按计划发布问号换行请及时回复感叹号"
    )

    #expect(output == "今天完成开发，明天开始测试。是否按计划发布？\n请及时回复！")
}

@Test func spokenStructureNormalizerPreservesPunctuationTermsAsContent() {
    #expect(
        SpokenStructureNormalizer.normalize("逗号是中文标点")
            == "逗号是中文标点"
    )
    #expect(
        SpokenStructureNormalizer.normalize("这个字段叫句号状态")
            == "这个字段叫句号状态"
    )
}

@Test func sessionProcessesAndInsertsFinalTranscriptBeforeCompleting() {
    var machine = SessionStateMachine()

    #expect(machine.handle(.start(.dictation)) == .listening(.dictation))
    #expect(machine.handle(.finish) == .finalizing(.dictation))
    #expect(
        machine.handle(.finalTranscriptReady) == .processing(.dictation)
    )
    #expect(
        machine.handle(.processingSucceeded) == .inserting(.dictation)
    )
    #expect(machine.handle(.insertionCompleted) == .ready)
}

@Test func intentHintDetectsCommandsWithoutMisclassifyingEmailMentions() {
    #expect(
        IntentHintDetector.detect("帮我给李明发一封邮件，告诉他项目完成了")
            == .composeEmail
    )
    #expect(
        IntentHintDetector.detect("我收到一封邮件，里面提到了项目计划")
            == .plainText
    )
    #expect(
        IntentHintDetector.detect("不用发邮件，把这段话记下来")
            == .plainText
    )
}

@Test func resultValidatorAcceptsEquivalentWordingWhenFactsRemain() throws {
    let json = """
    {
      "intent": "composeEmail",
      "confidence": 0.94,
      "outputText": "李明，你好：\\n\\nLocalVoice 第一版已完成，15:00 可以开始测试。\\n测试地址：https://test.localvoice.app\\n测试编号：LV-1024\\n请在 6 月 15 日前反馈。\\n\\n祝好\\nMax",
      "email": {
        "subject": "LocalVoice 测试安排",
        "recipient": "李明",
        "body": "李明，你好：\\n\\nLocalVoice 第一版已完成，15:00 可以开始测试。\\n测试地址：https://test.localvoice.app\\n测试编号：LV-1024\\n请在 6 月 15 日前反馈。\\n\\n祝好\\nMax",
        "missingFields": []
      }
    }
    """

    let result = try ProcessingResultValidator.validate(
        Data(json.utf8),
        requiredFacts: [
            "LocalVoice",
            "https://test.localvoice.app",
            "LV-1024",
            "李明"
        ]
    )

    #expect(result.intent == .composeEmail)
    #expect(result.outputText.contains("15:00"))
}

@Test func resultValidatorAcceptsCompactEmailMetadata() throws {
    let json = """
    {
      "intent": "composeEmail",
      "confidence": 0.96,
      "outputText": "项目已经完成。",
      "email": {"recipient": "李明", "missingFields": []}
    }
    """

    let result = try ProcessingResultValidator.validate(
        Data(json.utf8),
        requiredFacts: []
    )

    #expect(result.email?.recipient == "李明")
    #expect(result.email?.body == "")
}

@Test func resultValidatorRejectsMissingHardFacts() {
    let json = """
    {
      "intent": "composeEmail",
      "confidence": 0.95,
      "outputText": "李明，你好：项目已经完成。",
      "email": null
    }
    """

    #expect(throws: ProcessingValidationError.self) {
        try ProcessingResultValidator.validate(
            Data(json.utf8),
            requiredFacts: ["LV-1024"]
        )
    }
}

@Test func factExtractorProtectsCodesLinksAmountsAndTimes() {
    let facts = FactExtractor.hardFacts(
        from: "编号LV-START，编号 LV-2048，预算 ¥1200.50，折扣 15%，15:30 查看https://local.voice/a然后继续"
    )

    #expect(facts.contains("LV-START"))
    #expect(facts.contains("LV-2048"))
    #expect(facts.contains("¥1200.50"))
    #expect(facts.contains("15%"))
    #expect(facts.contains("15:30"))
    #expect(facts.contains("https://local.voice/a"))
}

@Test func resultValidatorDowngradesLowConfidenceEmailIntent() throws {
    let json = """
    {
      "intent": "composeEmail",
      "confidence": 0.61,
      "outputText": "这是一段普通听写。",
      "email": null
    }
    """

    let result = try ProcessingResultValidator.validate(
        Data(json.utf8),
        requiredFacts: []
    )

    #expect(result.intent == .plainText)
}

@Test func documentFormatterProducesCanonicalEmailTextAndSafeHTML() {
    let source = """
      李明，你好：  \r


    \tLocalVoice 第一版已经完成。  \r

    祝好\r
    Max

    """

    let formatted = DocumentFormatter.format(source)

    #expect(
        formatted.plainText
            == "李明，你好：\n\nLocalVoice 第一版已经完成。\n\n祝好\nMax"
    )
    #expect(!formatted.plainText.contains("\t"))
    #expect(
        formatted.html.contains(
            #"<p style="margin:0 0 1em 0;text-indent:0">李明，你好：</p>"#
        )
    )
    #expect(
        formatted.html.contains(
            #"<p style="margin:0;text-indent:0">祝好<br>Max</p>"#
        )
    )
}

@Test func emailOutputFormatterAddsDeterministicGreetingAndClosing() {
    let output = EmailOutputFormatter.format(
        body: "LocalVoice 第一版已经完成，请周五前反馈。",
        recipient: "李明",
        signature: "Max"
    )

    #expect(
        output
            == "李明，您好：\n\nLocalVoice 第一版已经完成，请周五前反馈。\n\n祝好\nMax"
    )
}

@Test func emailOutputFormatterRemovesGeneratedGreetingPrefix() {
    let output = EmailOutputFormatter.format(
        body: "Hi Li Ming, LocalVoice is ready for testing.",
        recipient: "李明",
        signature: "Max"
    )

    #expect(
        output
            == "Dear 李明,\n\nLocalVoice is ready for testing.\n\nBest regards,\nMax"
    )
}

@Test func recipientExtractorPreservesOriginalChineseName() {
    #expect(
        RecipientExtractor.recipient(
            from: "帮我给李明发一封邮件，说项目已经完成"
        ) == "李明"
    )
}

@Test func benchmarkSampleCalculatesGenerationAndEndToEndSpeed() {
    let sample = ProcessingBenchmarkSample(
        modelID: "test-model",
        inputCharacters: 100,
        inputTokens: 50,
        outputCharacters: 120,
        outputTokens: 60,
        modelLoadSeconds: 0,
        promptPrefillSeconds: 0.25,
        firstTokenSeconds: 0.2,
        generationSeconds: 1.5,
        validationSeconds: 0.1,
        insertionSeconds: 0.15,
        totalSeconds: 2
    )

    #expect(sample.generationTokensPerSecond == 40)
    #expect(sample.outputCharactersPerSecond == 60)
    #expect(sample.promptPrefillTokensPerSecond == 200)
}

@Test func qualityEvaluationAcceptsSemanticEquivalentOutput() {
    let testCase = ProcessingQualityCase(
        id: "email-001",
        transcript: "帮我给李明发邮件，说项目完成了，请他周五前反馈",
        mode: .dictation,
        expectedIntent: .composeEmail,
        requiredFacts: ["李明", "周五"],
        semanticGroups: [
            ["项目完成", "项目已完成"],
            ["反馈", "回复"]
        ],
        requiresEmailStructure: true
    )
    let result = ProcessingResult(
        intent: .composeEmail,
        confidence: 0.96,
        outputText: "李明，你好：\n\n项目已完成，请在周五前回复。\n\n祝好\nMax",
        email: nil
    )

    let evaluation = ProcessingQualityEvaluator.evaluate(
        result,
        against: testCase
    )

    #expect(evaluation.passed)
    #expect(evaluation.semanticScore == 1)
}

@Test func qualityEvaluationRejectsLostFactsAndMissingEmailStructure() {
    let testCase = ProcessingQualityCase(
        id: "email-002",
        transcript: "给王芳发邮件，编号 LV-2048 已上线",
        mode: .dictation,
        expectedIntent: .composeEmail,
        requiredFacts: ["王芳", "LV-2048"],
        semanticGroups: [["上线", "发布"]],
        requiresEmailStructure: true
    )
    let result = ProcessingResult(
        intent: .composeEmail,
        confidence: 0.91,
        outputText: "产品已经发布。",
        email: nil
    )

    let evaluation = ProcessingQualityEvaluator.evaluate(
        result,
        against: testCase
    )

    #expect(!evaluation.passed)
    #expect(evaluation.missingFacts == ["LV-2048", "王芳"])
    #expect(!evaluation.hasExpectedStructure)
}

@Test func qualityCorpusContainsTwoHundredDecodableCases() throws {
    let url = try #require(
        Bundle.module.url(
            forResource: "processing-quality-corpus",
            withExtension: "json"
        )
    )
    let cases = try JSONDecoder().decode(
        [ProcessingQualityCase].self,
        from: Data(contentsOf: url)
    )

    #expect(cases.count == 200)
    #expect(cases.filter(\.requiresEmailStructure).count == 100)
    #expect(Set(cases.map(\.id)).count == 200)
}

@Test func promptBuilderRequestsStructuredOutputWithoutApplicationContext() {
    let prompt = PromptBuilder.processingPrompt(
        transcript: "帮我给李明发邮件，说明项目完成了",
        mode: .dictation,
        signature: "Max",
        intentHint: .composeEmail
    )

    #expect(prompt.contains("\"intent\""))
    #expect(prompt.contains("Max"))
    #expect(prompt.contains("逗号、句号、问号和感叹号"))
    #expect(prompt.contains("1.、2.、3."))
    #expect(!prompt.contains("当前应用正文"))
    #expect(!prompt.contains("屏幕内容"))
}

@Test func englishModeKeepsChineseTranscriptIntactBeforeModelTranslation() async {
    let model = CapturingLanguageModelService(
        response: ModelGenerationOutput(
            text: """
            {
              "intent": "plainText",
              "confidence": 0.99,
              "outputText": "We will start testing this afternoon.",
              "email": null
            }
            """
        )
    )
    let processor = DraftProcessingService(
        languageModel: model,
        timeout: .seconds(1)
    )

    _ = await processor.process(
        transcript: "嗯，今天 下午 我们开始测试",
        mode: .english,
        signature: ""
    )

    let prompt = await model.lastPrompt
    #expect(prompt?.contains("今天下午我们开始测试") == true)
    #expect(prompt?.contains("输出语言：英文") == true)
}

@Test func draftProcessorRetriesInvalidJSONOnce() async throws {
    let model = FakeLanguageModelService(
        responses: [
            ModelGenerationOutput(text: "not-json"),
            ModelGenerationOutput(
                text: """
                {
                  "intent": "composeEmail",
                  "confidence": 0.96,
                  "outputText": "李明，你好：\\n\\nLocalVoice 已完成。\\n\\n祝好\\nMax",
                  "email": {
                    "subject": "LocalVoice 进度",
                    "recipient": "李明",
                    "body": "李明，你好：\\n\\nLocalVoice 已完成。\\n\\n祝好\\nMax",
                    "missingFields": []
                  }
                }
                """
            )
        ]
    )
    let processor = DraftProcessingService(
        languageModel: model,
        timeout: .seconds(1)
    )

    let outcome = await processor.process(
        transcript: "帮我给李明发一封邮件，说 LocalVoice 已完成",
        mode: .dictation,
        signature: "Max"
    )

    #expect(outcome.result.intent == .composeEmail)
    #expect(!outcome.usedFallback)
    #expect(await model.requestCount == 2)
}

@Test func draftProcessorFallsBackWhenModelFails() async {
    let model = FakeLanguageModelService(error: TestModelError.failed)
    let processor = DraftProcessingService(
        languageModel: model,
        timeout: .seconds(1)
    )

    let outcome = await processor.process(
        transcript: "嗯，今天下午我们开始测试",
        mode: .dictation,
        signature: ""
    )

    #expect(outcome.usedFallback)
    #expect(outcome.result.intent == .plainText)
    #expect(outcome.result.outputText == "今天下午我们开始测试")
}

@Test func draftProcessorKeepsNumberedListWhenModelFails() async {
    let model = FakeLanguageModelService(error: TestModelError.failed)
    let processor = DraftProcessingService(
        languageModel: model,
        timeout: .seconds(1)
    )

    let outcome = await processor.process(
        transcript: "第一点确认需求第二点完成开发第三点安排测试",
        mode: .dictation,
        signature: ""
    )

    #expect(outcome.usedFallback)
    #expect(
        outcome.result.outputText
            == "1. 确认需求\n2. 完成开发\n3. 安排测试"
    )
}

@Test func draftProcessorRejectsModelOutputThatFlattensNumberedList() async {
    let flattened = ModelGenerationOutput(
        text: """
        {
          "intent": "plainText",
          "confidence": 0.99,
          "outputText": "确认需求，完成开发，安排测试。",
          "email": null
        }
        """
    )
    let model = FakeLanguageModelService(
        responses: [flattened, flattened]
    )
    let processor = DraftProcessingService(
        languageModel: model,
        timeout: .seconds(1)
    )

    let outcome = await processor.process(
        transcript: "第一点确认需求第二点完成开发第三点安排测试",
        mode: .dictation,
        signature: ""
    )

    #expect(outcome.usedFallback)
    #expect(
        outcome.result.outputText
            == "1. 确认需求\n2. 完成开发\n3. 安排测试"
    )
    #expect(await model.requestCount == 2)
}

@Test func longDictationRejectsASeverelyTruncatedModelResult() async {
    let transcript = Array(
        repeating: "这是一段用于验证长语音识别完整性的中文内容，每一句都应保留。",
        count: 12
    ).joined()
    let truncated = ModelGenerationOutput(
        text: """
        {
          "intent": "plainText",
          "confidence": 0.99,
          "outputText": "这是一段用于验证长语音识别完整性的中文内容。",
          "email": null
        }
        """
    )
    let model = FakeLanguageModelService(responses: [truncated, truncated])
    let processor = DraftProcessingService(
        languageModel: model,
        timeout: .seconds(1)
    )

    let outcome = await processor.process(
        transcript: transcript,
        mode: .dictation,
        signature: ""
    )

    #expect(outcome.usedFallback)
    #expect(outcome.result.outputText == transcript)
    #expect(await model.requestCount == 2)
}

@Test func longEnglishTranslationRetriesASeverelyTruncatedResult() async {
    let transcript = Array(
        repeating: "我们正在验证长语音翻译不会只保留开头后面的计划和结论也必须完整出现",
        count: 10
    ).joined()
    let truncated = ModelGenerationOutput(
        text: """
        {
          "intent": "plainText",
          "confidence": 0.99,
          "outputText": "We are verifying long voice translation.",
          "email": null
        }
        """
    )
    let completeTranslation = Array(
        repeating: "We are verifying that long voice translation preserves the plan and conclusion.",
        count: 10
    ).joined(separator: " ")
    let complete = ModelGenerationOutput(
        text: """
        {
          "intent": "plainText",
          "confidence": 0.99,
          "outputText": "\(completeTranslation)",
          "email": null
        }
        """
    )
    let model = FakeLanguageModelService(responses: [truncated, complete])
    let processor = DraftProcessingService(
        languageModel: model,
        timeout: .seconds(1)
    )

    let outcome = await processor.process(
        transcript: transcript,
        mode: .english,
        signature: ""
    )

    #expect(!outcome.usedFallback)
    #expect(outcome.result.outputText == completeTranslation)
    #expect(await model.requestCount == 2)
}

@Test func longEnglishTranslationProcessesCompleteSentenceChunks() async {
    let first = "第一部分说明产品团队需要检查实时预览、最终文本和光标插入，确保完整内容不会只剩开头。"
    let second = "第二部分说明工程团队需要检查模型输出长度、处理超时和回归测试，确保中间计划没有丢失。"
    let third = "第三部分说明发布条件、风险记录和最终结论都必须翻译，确保长语音的结尾仍然存在。"
    let translations = [
        "The product team checks the live preview, final text, and cursor insertion.",
        "The engineering team checks output length, timeouts, and regression tests.",
        "Release conditions, risks, and the final conclusion must remain translated."
    ]
    let responses = translations.map {
        ModelGenerationOutput(text: $0)
    }
    let model = FakeLanguageModelService(responses: responses)
    let processor = DraftProcessingService(
        languageModel: model,
        timeout: .seconds(1)
    )

    let outcome = await processor.process(
        transcript: first + second + third,
        mode: .english,
        signature: ""
    )

    #expect(!outcome.usedFallback)
    #expect(outcome.result.outputText == translations.joined(separator: " "))
    #expect(await model.requestCount == 3)
}

@Test func englishModeRetriesAnUntranslatedChineseResult() async {
    let untranslated = ModelGenerationOutput(
        text: """
        {
          "intent": "plainText",
          "confidence": 0.99,
          "outputText": "产品团队检查实时预览，工程团队检查最终文本。",
          "email": null
        }
        """
    )
    let translated = ModelGenerationOutput(
        text: """
        {
          "intent": "plainText",
          "confidence": 0.99,
          "outputText": "The product team checks the live preview, and the engineering team checks the final text.",
          "email": null
        }
        """
    )
    let model = FakeLanguageModelService(
        responses: [untranslated, translated]
    )
    let processor = DraftProcessingService(
        languageModel: model,
        timeout: .seconds(1)
    )

    let outcome = await processor.process(
        transcript: "产品团队检查实时预览，工程团队检查最终文本。",
        mode: .english,
        signature: ""
    )

    #expect(
        outcome.result.outputText
            == "The product team checks the live preview, and the engineering team checks the final text."
    )
    #expect(await model.requestCount == 2)
}

private enum TestModelError: Error {
    case failed
}

private actor CapturingLanguageModelService: LocalLanguageModelService {
    private let response: ModelGenerationOutput
    private(set) var lastPrompt: String?

    init(response: ModelGenerationOutput) {
        self.response = response
    }

    func generate(prompt: String) async throws -> ModelGenerationOutput {
        lastPrompt = prompt
        return response
    }
}

private actor FakeLanguageModelService: LocalLanguageModelService {
    private var responses: [ModelGenerationOutput]
    private let error: Error?
    private(set) var requestCount = 0

    init(
        responses: [ModelGenerationOutput] = [],
        error: Error? = nil
    ) {
        self.responses = responses
        self.error = error
    }

    func generate(prompt: String) async throws -> ModelGenerationOutput {
        requestCount += 1
        if let error {
            throw error
        }
        guard !responses.isEmpty else {
            throw TestModelError.failed
        }
        return responses.removeFirst()
    }
}
