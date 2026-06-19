import Foundation
import FoundationModels
import LocalVoiceCore

actor FoundationModelBackend: LanguageModelBackend {
    nonisolated var descriptor: LanguageModelBackendDescriptor {
        LanguageModelBackendDescriptor(
            kind: .foundationModels,
            title: "Foundation Models",
            detail: "由 macOS 提供 · 无需额外下载 · 内容不离开本机"
        )
    }

    func availability() async -> LanguageModelBackendAvailability {
        switch SystemLanguageModel.default.availability {
        case .available:
            return .available
        case .unavailable(let reason):
            switch reason {
            case .appleIntelligenceNotEnabled:
                return .unavailable("请在系统设置中开启 Apple 智能")
            case .modelNotReady:
                return .unavailable("系统模型正在准备，请稍后重试")
            case .deviceNotEligible:
                return .unavailable("此 Mac 不支持 Apple 智能")
            @unknown default:
                return .unavailable("Foundation Models 暂不可用")
            }
        }
    }

    func prepare(
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> Double {
        guard case .available = await availability() else {
            throw FoundationModelBackendError.unavailable
        }
        progress(1)
        return 0
    }

    func unload() async {}

    func generate(prompt: String) async throws -> ModelGenerationOutput {
        guard case .available = await availability() else {
            throw FoundationModelBackendError.unavailable
        }

        let clock = ContinuousClock()
        let start = clock.now
        do {
            let response = try await LanguageModelSession().respond(
                to: prompt,
                options: GenerationOptions(
                    temperature: 0.1,
                    maximumResponseTokens: 2_048
                )
            )
            let text = response.content
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else {
                throw FoundationModelBackendError.emptyOutput
            }
            let elapsed = Self.seconds(from: start, to: clock.now)
            return ModelGenerationOutput(
                text: text,
                firstTokenSeconds: elapsed,
                generationSeconds: elapsed
            )
        } catch let error as FoundationModelBackendError {
            throw error
        } catch {
            throw FoundationModelBackendError.generationFailed(
                error.localizedDescription
            )
        }
    }

    private static func seconds(
        from start: ContinuousClock.Instant,
        to end: ContinuousClock.Instant
    ) -> Double {
        let components = start.duration(to: end).components
        return Double(components.seconds)
            + Double(components.attoseconds) / 1_000_000_000_000_000_000
    }
}

private enum FoundationModelBackendError: LocalizedError {
    case unavailable
    case emptyOutput
    case generationFailed(String)

    var errorDescription: String? {
        switch self {
        case .unavailable:
            return "Foundation Models 暂不可用"
        case .emptyOutput:
            return "Foundation Models 未返回内容"
        case .generationFailed(let message):
            return "Foundation Models 处理失败：\(message)"
        }
    }
}
