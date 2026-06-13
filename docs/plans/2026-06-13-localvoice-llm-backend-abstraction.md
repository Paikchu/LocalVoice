# LocalVoice — Pluggable LLM Backend (System Model + Downloadable Model)

**Date:** 2026-06-13
**Status:** Implemented on branch `worktree-llm-backend-abstraction`
**Goal:** Put the LLM logic behind one interface that supports two backends today —
Apple's on-device **system model** (FoundationModels) and the existing
**downloadable local model** (MLX / Hugging Face) — with a clean path to add more
(e.g. Ollama). Backend selection is **automatic**:

1. If the device supports the system model, use it (nothing to download).
2. Otherwise, prompt the user to download the local model (the existing flow).

---

## (a) Issues considered, and how each is handled

| # | Issue | Resolution in this change |
| --- | --- | --- |
| 1 | The two backends have **different lifecycles** — the MLX model is a downloadable/removable asset; the system model is OS-provided with nothing to download. | Asset management is an **optional** capability (`ManagedModelAsset`). MLX implements it; the system backend returns `managedAsset == nil`. The UI keys off that to hide Download/Remove. |
| 2 | System model has **no raw-prompt entry point** and prefers structured output. | The whole `PromptBuilder` prompt is forwarded as a single user turn via `respond(to:)`. This is information-preserving and mirrors how MLX feeds its chat template — one source of truth, no transcript loss. |
| 3 | `ModelGenerationOutput` carries **MLX-shaped metrics** (token counts, prefill time) the system model does not report. | Unreported fields stay `0` (already the initializer default). Documented as "not reported," not "zero time." |
| 4 | System-model **guardrails can refuse/rewrite** content, dangerous for verbatim preservation. | A `GenerationError` is mapped to `LocalModelError.refused` and **thrown**, which routes the request to the existing deterministic fallback in `DraftProcessingService` (`usedFallback == true`). No error surfaces mid-dictation. |
| 5 | System-model **availability is runtime** (Apple Intelligence off, ineligible HW, model still downloading). | `FoundationModelBackend.availability()` maps every `UnavailableReason` to a localized string. `LocalModelManager` checks availability first and falls back to the downloadable model when unavailable — including if it becomes unavailable between the check and `prepare`. |
| 6 | **`Sendable`/isolation** differs per backend. | Each backend owns its isolation: both concrete backends are `actor`s. `ActiveBackendProxy` reads its current backend under a lock synchronously and awaits outside the lock. |
| 7 | **No regression** to the drafting pipeline or its test mocks. | `DraftProcessingService` still depends on the narrow `LocalLanguageModelService` (generation only). `LanguageModelBackend` *refines* it; existing mocks compile unchanged. 142 tests pass. |

---

## (b) What was implemented

**New protocols (`Sources/LocalVoiceCore/LanguageModelBackend.swift`)**
- `BackendKind` (`.foundationModels`, `.downloadableLocal`) — add a case to extend.
- `BackendDescriptor` (display name + detail for the menu), `BackendAvailability`.
- `ManagedModelAsset` — optional download/remove capability.
- `LanguageModelBackend: LocalLanguageModelService` — generation + identity +
  availability + prepare/unload + optional `managedAsset`.
- `ActiveBackendProxy` — a stable `LocalLanguageModelService` the pipeline holds for
  life; the manager repoints it as backends activate.

**System backend (`Sources/LocalVoiceApp/FoundationModelBackend.swift`)**
- `actor FoundationModelBackend`. `availability()` reads
  `SystemLanguageModel.default.availability`. `generate` runs a `LanguageModelSession`
  with `GenerationOptions(temperature: 0.1, maximumResponseTokens: 2048)`, maps
  refusals to `LocalModelError.refused`, reports coarse timing.

**MLX backend (`Sources/LocalVoiceApp/MLXLanguageModelService.swift`)**
- Now conforms to `LanguageModelBackend` + `ManagedModelAsset` (its existing
  `isInstalled`/`installedRevision`/`removeFiles`/`prepare`/`unload` satisfy the
  contract). Behavior unchanged.

**Manager (`Sources/LocalVoiceApp/LocalModelManager.swift`)**
- Holds both backends + the proxy. `preloadIfInstalled()` now: prefer the system
  model if available; else use the downloadable model and run the download→ready
  flow. Publishes `descriptor` and `usingSystemModel` for the UI.

**Wiring & UI**
- `AppModel` builds `DraftProcessingService(languageModel: modelManager.proxy)`.
- `MenuBarContentView` shows `descriptor.displayName`/`detail`; when
  `usingSystemModel` it shows a green seal instead of Download/Remove.
- `project.yml` links `FoundationModels.framework`.

**Extending to Ollama later:** add an `OllamaBackend` conforming to
`LanguageModelBackend`, add `.ollama` to `BackendKind`, and slot it into the
manager's resolution order. Nothing in `DraftProcessingService` or the menu logic
changes.

---

## (c) Acceptance testing

**Automated (in `LocalVoiceCoreTests`, run via `swift test` — all 142 green)**
- `BackendProxyTests`: the proxy forwards to the initial backend, routes to the
  most-recently-set backend (the swap), and propagates backend errors. This guards
  the backend-agnostic generation contract and the live-swap mechanism.
- Existing `DraftProcessingTests` unchanged: confirms a thrown generation error
  (the path a system-model refusal takes) still produces a deterministic
  `usedFallback` result rather than surfacing an error (issue #4).

**Build**
- `swift build` (Core) and the full app build via `scripts/build-app.sh`
  (`xcodegen` + `xcodebuild`, `BUILD SUCCEEDED`) — verifies the FoundationModels
  link and the actor conformances on macOS 26.

**Manual device matrix** (FoundationModels needs real Apple-Intelligence hardware)
| Setting | Expected |
| --- | --- |
| Apple-silicon, AI **on** | Menu shows "系统模型（Apple 智能）" + green seal, "已就绪（系统模型）"; dictation works; no Download/Remove buttons. |
| AI **off** / ineligible Mac | Menu shows "本地下载模型" with the Download button; download → ready → dictation works (unchanged from today). |
| AI **off mid-session** | Next dictation either uses the installed local model or degrades to the deterministic fallback — never a silent failure. |
| Verbatim check (both backends) | Run dictation containing a URL, an email, and an amount; all must appear byte-identical in the inserted text (system-model guardrail check). |
