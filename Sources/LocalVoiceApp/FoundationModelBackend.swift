import Foundation
import FoundationModels
import LocalVoiceCore

/// Backend that runs the prompt through Apple's on-device system model.
///
/// There is nothing for us to download or remove — the OS owns the model — so
/// `managedAsset` is `nil` and `prepare` is a no-op once the model reports
/// `.available`. Generation forwards the full LocalVoice prompt as a single user
/// turn, mirroring how the MLX backend feeds its chat template, so the prompt built
/// by `PromptBuilder` is the single source of truth across both backends.
actor FoundationModelBackend: LanguageModelBackend {
    nonisolated var descriptor: BackendDescriptor {
        BackendDescriptor(
            kind: .foundationModels,
            displayName: "系统模型（Apple 智能）",
            detail: "由 macOS 提供 · 无需下载 · 内容不离开本机"
        )
    }

    nonisolated var managedAsset: ManagedModelAsset? { nil }

    func availability() async -> BackendAvailability {
        switch SystemLanguageModel.default.availability {
        case .available:
            return .available
        case .unavailable(let reason):
            switch reason {
            case .appleIntelligenceNotEnabled:
                return .unavailable(reason: "请在系统设置中开启 Apple 智能")
            case .modelNotReady:
                return .unavailable(reason: "Apple 模型正在准备，请稍后重试")
            case .deviceNotEligible:
                return .unavailable(reason: "此设备不支持 Apple 智能")
            @unknown default:
                return .unavailable(reason: "Apple 智能暂不可用")
            }
        }
    }

    func prepare(
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> Double {
        guard case .available = await availability() else {
            throw LocalModelError.notLoaded
        }
        progress(1)
        return 0
    }

    func unload() async {}

    func generate(prompt: String) async throws -> ModelGenerationOutput {
        let clock = ContinuousClock()
        let start = clock.now
        let session = LanguageModelSession()
        do {
            let response = try await session.respond(
                to: prompt,
                options: GenerationOptions(
                    temperature: 0.1,
                    maximumResponseTokens: 2_048
                )
            )
            let elapsed = Self.seconds(from: start, to: clock.now)
            let text = response.content
            guard !text.isEmpty else {
                throw LocalModelError.emptyOutput
            }
            // FoundationModels does not surface per-token counts or prompt-prefill
            // timing; unreported fields stay 0 (see ModelGenerationOutput).
            return ModelGenerationOutput(
                text: text,
                inputTokens: 0,
                outputTokens: 0,
                promptPrefillSeconds: 0,
                firstTokenSeconds: elapsed,
                generationSeconds: elapsed
            )
        } catch let error as LanguageModelSession.GenerationError {
            // A guardrail refusal or context-window error must not surface to the
            // user mid-dictation. Throwing routes the request to the deterministic
            // fallback path in DraftProcessingService (usedFallback == true).
            throw LocalModelError.refused(error.localizedDescription)
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
