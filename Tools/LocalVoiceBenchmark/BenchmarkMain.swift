import Foundation
import LocalVoiceCore

@main
enum LocalVoiceBenchmark {
    static func main() async throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let corpusURL = CommandLine.arguments.count > 1
            ? URL(fileURLWithPath: CommandLine.arguments[1])
            : root.appendingPathComponent(
                "Tests/Fixtures/processing-quality-corpus.json"
            )
        let reportURL = CommandLine.arguments.count > 2
            ? URL(fileURLWithPath: CommandLine.arguments[2])
            : root.appendingPathComponent(
                "docs/reports/2026-06-12-localvoice-model-evaluation.md"
            )
        let limit = CommandLine.arguments.count > 3
            ? Int(CommandLine.arguments[3])
            : nil

        let allCases = try JSONDecoder().decode(
            [ProcessingQualityCase].self,
            from: Data(contentsOf: corpusURL)
        )
        let cases = selectCases(allCases, limit: limit)
        let model = MLXLanguageModelService()

        print("Preparing \(MLXLanguageModelService.modelID)")
        let loadSeconds = try await model.prepare { progress in
            let percent = Int(progress * 100)
            if percent == 100 {
                print("Model progress: \(percent)%")
            }
        }
        print("Model ready in \(format(loadSeconds))s")
        let modelRevision = await model.installedRevision()

        let warmup = ProcessingQualityCase(
            id: "warmup",
            transcript: "记录一下，LocalVoice 已准备开始测试",
            mode: .dictation,
            expectedIntent: .plainText,
            requiredFacts: ["LocalVoice"],
            semanticGroups: [["开始测试", "准备测试"]],
            requiresEmailStructure: false
        )
        _ = await DraftProcessingService(
            languageModel: model,
            timeout: .seconds(30)
        ).process(
            transcript: warmup.transcript,
            mode: warmup.mode,
            signature: "Max"
        )

        let clock = ContinuousClock()
        let benchmarkStart = clock.now
        var rows: [BenchmarkRow] = []
        for (index, testCase) in cases.enumerated() {
            let processor = DraftProcessingService(
                languageModel: model,
                timeout: .seconds(30)
            )
            let outcome = await processor.process(
                transcript: testCase.transcript,
                mode: testCase.mode,
                signature: "Max"
            )
            let quality = ProcessingQualityEvaluator.evaluate(
                outcome.result,
                against: testCase
            )
            rows.append(
                BenchmarkRow(
                    testCase: testCase,
                    outcome: outcome,
                    quality: quality
                )
            )
            print(
                "[\(index + 1)/\(cases.count)] \(testCase.id) "
                    + "\(quality.passed ? "PASS" : "FAIL") "
                    + "\(format(outcome.totalSeconds))s"
            )
        }
        let wallSeconds = seconds(
            benchmarkStart.duration(to: clock.now)
        )

        let report = makeReport(
            rows: rows,
            loadSeconds: loadSeconds,
            wallSeconds: wallSeconds,
            corpusCount: allCases.count,
            modelRevision: modelRevision
        )
        try FileManager.default.createDirectory(
            at: reportURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try report.write(to: reportURL, atomically: true, encoding: .utf8)
        print("Report: \(reportURL.path)")
    }

    private static func selectCases(
        _ cases: [ProcessingQualityCase],
        limit: Int?
    ) -> [ProcessingQualityCase] {
        guard let limit, limit < cases.count else { return cases }
        let emails = cases.filter(\.requiresEmailStructure)
        let plain = cases.filter { !$0.requiresEmailStructure }
        let half = max(1, limit / 2)
        return Array(emails.prefix(half))
            + Array(plain.prefix(limit - half))
    }

    private static func makeReport(
        rows: [BenchmarkRow],
        loadSeconds: Double,
        wallSeconds: Double,
        corpusCount: Int,
        modelRevision: String
    ) -> String {
        let totals = rows.map(\.outcome.totalSeconds)
        let generations = rows.compactMap(\.outcome.generation)
        let generationRates = generations.map {
            rate(Double($0.outputTokens), $0.generationSeconds)
        }
        let characterRates = rows.map {
            rate(
                Double($0.outcome.result.outputText.count),
                $0.outcome.totalSeconds
            )
        }
        let firstTokens = generations.map(\.firstTokenSeconds)
        let passed = rows.filter(\.quality.passed).count
        let fallback = rows.filter(\.outcome.usedFallback).count
        let withinTimeout = totals.filter { $0 <= 2.5 }.count
        let emailRows = rows.filter(\.testCase.requiresEmailStructure)
        let plainRows = rows.filter { !$0.testCase.requiresEmailStructure }
        let firstPassJSON = rows.filter {
            $0.outcome.generationAttempts == 1 && !$0.outcome.usedFallback
        }.count
        let repairedJSON = rows.filter {
            $0.outcome.generationAttempts == 2 && !$0.outcome.usedFallback
        }.count
        let inputLengths = rows.map { Double($0.testCase.transcript.count) }
        let commit = commandOutput(
            "/usr/bin/git",
            ["rev-parse", "--short", "HEAD"]
        )
        let chip = commandOutput(
            "/usr/sbin/sysctl",
            ["-n", "machdep.cpu.brand_string"]
        )

        return """
        # LocalVoice 本地模型测试评估报告

        - 日期：2026-06-12
        - 模型：`\(MLXLanguageModelService.modelID)`
        - 模型 revision：`\(modelRevision)`
        - 运行方式：MLX Swift，4-bit，本地推理
        - 芯片：\(chip)
        - 设备内存：\(format(Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824)) GB
        - macOS：\(ProcessInfo.processInfo.operatingSystemVersionString)
        - 应用 commit：`\(commit)`
        - 质量集：共 \(corpusCount) 条，本次执行 \(rows.count) 条
        - 样本：邮件 \(emailRows.count) 条，普通听写 \(plainRows.count) 条；输入字符 P50 / P90 / P95 为 \(percentiles(inputLengths))
        - 已下载模型加载：\(format(loadSeconds)) 秒

        ## 速度

        | 指标 | 结果 |
        |---|---:|
        | 首 token P50 / P90 / P95 | \(percentiles(firstTokens)) 秒 |
        | 本地整理 P50 / P90 / P95 | \(percentiles(totals)) 秒 |
        | 模型生成 tokens/s P50 / P90 / P95 | \(percentiles(generationRates)) |
        | 用户内容字符/s P50 / P90 / P95 | \(percentiles(characterRates)) |
        | 本地整理吞吐 | \(format(rate(Double(rows.count), wallSeconds))) 条/秒 |
        | 2.5 秒内完成 | \(withinTimeout)/\(rows.count)（\(percentage(withinTimeout, rows.count))） |

        ## 质量

        | 指标 | 结果 |
        |---|---:|
        | 语义与结构通过 | \(passed)/\(rows.count)（\(percentage(passed, rows.count))） |
        | 邮件场景通过 | \(emailRows.filter(\.quality.passed).count)/\(emailRows.count) |
        | 普通听写通过 | \(plainRows.filter(\.quality.passed).count)/\(plainRows.count) |
        | JSON 首次成功 | \(firstPassJSON)/\(rows.count)（\(percentage(firstPassJSON, rows.count))） |
        | JSON 修复后成功 | \(repairedJSON) |
        | 降级次数 | \(fallback) |
        | 事实丢失案例 | \(rows.filter { !$0.quality.missingFacts.isEmpty }.count) |
        | 意图错误案例 | \(rows.filter { !$0.quality.intentMatches }.count) |

        ## 失败案例

        \(failureLines(rows))

        ## 验收判断

        - 本地整理 P95：\(format(percentile(totals, 0.95))) 秒。
        - 插入服务固定调度等待约 0.22 秒；据此估算整理加插入 P95 为 \(format(percentile(totals, 0.95) + 0.22)) 秒，但该值不替代真实跨应用实测。
        - 推理超时目标：`≤ 2.5 秒`；\(withinTimeout == rows.count ? "通过" : "未通过")。
        - 语义等价目标：`≥ 95%`；实测 \(percentage(passed, rows.count))，\(Double(passed) / Double(rows.count) >= 0.95 ? "通过" : "未通过")。
        - 邮件结构通过率：\(percentage(emailRows.filter(\.quality.passed).count, emailRows.count))。
        - 停止录音到真实跨应用粘贴的 `≤ 2 秒` 目标仍需人工端到端验收；本次基准未包含 ASR finalization 和目标应用响应时间。
        - 结果采用意图、硬事实、语义组和邮件结构判定，不要求逐字一致。
        - 插入格式由纯文本、HTML、RTF 三种剪贴板表示保证；段首缩进固定为 0。
        """
    }

    private static func failureLines(_ rows: [BenchmarkRow]) -> String {
        let failures = rows.filter { !$0.quality.passed }.prefix(20)
        guard !failures.isEmpty else { return "- 无" }
        return failures.map {
            "- `\($0.testCase.id)`：intent=\($0.quality.intentMatches)，"
                + "missing=\($0.quality.missingFacts.joined(separator: ","))，"
                + "semantic=\(format($0.quality.semanticScore))，"
                + "structure=\($0.quality.hasExpectedStructure)，"
                + "output=`\(reportExcerpt($0.outcome.result.outputText))`"
        }.joined(separator: "\n")
    }

    private static func reportExcerpt(_ value: String) -> String {
        String(value.prefix(240))
            .replacingOccurrences(of: "`", with: "'")
            .replacingOccurrences(of: "\n", with: "\\n")
    }

    private static func percentiles(_ values: [Double]) -> String {
        "\(format(percentile(values, 0.5))) / "
            + "\(format(percentile(values, 0.9))) / "
            + "\(format(percentile(values, 0.95)))"
    }

    private static func percentile(
        _ values: [Double],
        _ fraction: Double
    ) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let index = Int(
            ceil(Double(sorted.count) * fraction)
        ).clamped(to: 1...sorted.count) - 1
        return sorted[index]
    }

    private static func percentage(_ value: Int, _ total: Int) -> String {
        guard total > 0 else { return "0%" }
        return "\(format(Double(value) / Double(total) * 100))%"
    }

    private static func rate(_ amount: Double, _ duration: Double) -> Double {
        duration > 0 ? amount / duration : 0
    }

    private static func seconds(_ duration: Duration) -> Double {
        let parts = duration.components
        return Double(parts.seconds)
            + Double(parts.attoseconds) / 1_000_000_000_000_000_000
    }

    private static func format(_ value: Double) -> String {
        String(format: "%.2f", value)
    }

    private static func commandOutput(
        _ executable: String,
        _ arguments: [String]
    ) -> String {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(decoding: data, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return output.isEmpty ? "unknown" : output
        } catch {
            return "unknown"
        }
    }
}

private struct BenchmarkRow {
    let testCase: ProcessingQualityCase
    let outcome: DraftProcessingOutcome
    let quality: ProcessingQualityEvaluation
}

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
