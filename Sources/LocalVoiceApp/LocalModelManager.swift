import Combine
import Foundation
import LocalVoiceCore

@MainActor
final class LocalModelManager: ObservableObject {
    @Published private(set) var state: LanguageModelLifecycleState = .loading
    @Published private(set) var descriptor: LanguageModelBackendDescriptor

    let proxy: ActiveBackendProxy

    private let backend: any LanguageModelBackend
    private var task: Task<Void, Never>?

    init(backend: any LanguageModelBackend = FoundationModelBackend()) {
        self.backend = backend
        descriptor = backend.descriptor
        proxy = ActiveBackendProxy(backend)
    }

    var statusText: String {
        switch state {
        case .loading:
            return "正在准备"
        case .ready:
            return "已就绪"
        case .unavailable(let reason):
            return reason
        case .failed(let message):
            return "失败：\(message)"
        }
    }

    var isReady: Bool {
        state == .ready
    }

    var isBusy: Bool {
        state.isBusy
    }

    func preloadIfInstalled() {
        guard task == nil else { return }
        task = Task { [weak self] in
            guard let self else { return }
            await prepare()
            task = nil
        }
    }

    func clearFiles() async throws {
        // Foundation Models is OS-provided; no local files to clear.
    }

    func resetSelection() {
        // No selection to reset; Foundation Models is the only backend.
    }

    func shutdown() {
        task?.cancel()
        task = nil
        let b = backend
        Task { await b.unload() }
    }

    private func prepare() async {
        switch await backend.availability() {
        case .available:
            break
        case .unavailable(let reason):
            state = .unavailable(reason)
            return
        }
        state = .loading
        do {
            _ = try await backend.prepare { _ in }
            proxy.setBackend(backend)
            state = .ready
        } catch {
            state = .failed(error.localizedDescription)
        }
    }
}
