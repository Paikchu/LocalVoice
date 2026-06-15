import Combine
import Foundation
import LocalVoiceCore

@MainActor
final class LocalModelManager: ObservableObject {
    @Published private(set) var state: LanguageModelLifecycleState =
        .notInstalled
    @Published private(set) var lastLoadSeconds: Double = 0
    @Published private(set) var selectedBackend: LanguageModelBackendKind
    @Published private(set) var descriptor: LanguageModelBackendDescriptor

    let proxy: ActiveBackendProxy

    private let qwenBackend: any LanguageModelBackend
    private let foundationBackend: any LanguageModelBackend
    private let preferenceStore: LanguageModelPreferenceStore
    private var activeBackend: any LanguageModelBackend
    private var task: Task<Void, Never>?

    init(
        qwenBackend: any LanguageModelBackend = MLXLanguageModelService(),
        foundationBackend: any LanguageModelBackend = FoundationModelBackend(),
        preferenceStore: LanguageModelPreferenceStore =
            LanguageModelPreferenceStore()
    ) {
        let selected = preferenceStore.load()
        let active = selected == .qwen ? qwenBackend : foundationBackend

        self.qwenBackend = qwenBackend
        self.foundationBackend = foundationBackend
        self.preferenceStore = preferenceStore
        selectedBackend = selected
        descriptor = active.descriptor
        activeBackend = active
        proxy = ActiveBackendProxy(active)
    }

    var statusText: String {
        switch state {
        case .notInstalled:
            return "尚未下载"
        case .downloading(let progress):
            let percent = Int(progress * 100)
            return percent > 0 ? "下载中 \(percent)%" : "下载中"
        case .loading:
            return "正在准备"
        case .ready:
            return "已就绪"
        case .removing:
            return "正在移除"
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

    var managesDownload: Bool {
        selectedBackend == .qwen
    }

    func preloadIfInstalled() {
        guard task == nil else { return }
        task = Task { [weak self] in
            guard let self else { return }
            await prepareSelectedBackend(download: false)
            task = nil
        }
    }

    func select(_ backend: LanguageModelBackendKind) {
        guard task == nil, backend != selectedBackend else { return }

        let previous = activeBackend
        selectedBackend = backend
        preferenceStore.save(backend)
        activeBackend = backend == .qwen ? qwenBackend : foundationBackend
        descriptor = activeBackend.descriptor
        proxy.setBackend(activeBackend)
        lastLoadSeconds = 0
        state = .loading

        task = Task { [weak self] in
            guard let self else { return }
            await previous.unload()
            await prepareSelectedBackend(download: false)
            task = nil
        }
    }

    func download() {
        guard task == nil,
              selectedBackend == .qwen,
              state.allowsDownload else { return }
        task = Task { [weak self] in
            guard let self else { return }
            await prepareSelectedBackend(download: true)
            task = nil
        }
    }

    func remove() {
        guard task == nil,
              selectedBackend == .qwen,
              state.allowsRemoval else { return }
        state = .removing
        task = Task { [weak self] in
            guard let self else { return }
            do {
                await qwenBackend.unload()
                try await removeQwenFiles()
            } catch {}
            task = nil
        }
    }

    func clearFiles() async throws {
        task?.cancel()
        task = nil
        try await removeQwenFiles()
    }

    func resetSelection() {
        task?.cancel()
        task = nil
        selectedBackend = .defaultValue
        preferenceStore.save(.defaultValue)
        activeBackend = qwenBackend
        descriptor = qwenBackend.descriptor
        proxy.setBackend(qwenBackend)
        state = .notInstalled
        lastLoadSeconds = 0
    }

    func shutdown() {
        task?.cancel()
        task = nil
        let backend = activeBackend
        Task {
            await backend.unload()
        }
    }

    private func prepareSelectedBackend(download: Bool) async {
        switch await activeBackend.availability() {
        case .available:
            break
        case .unavailable(let reason):
            state = .unavailable(reason)
            return
        }

        if selectedBackend == .qwen, !download {
            let installed = await activeBackend.managedAsset?.isInstalled()
                ?? false
            guard installed else {
                state = .notInstalled
                return
            }
        }

        state = download ? .downloading(0) : .loading
        do {
            let duration = try await activeBackend.prepare {
                [weak self] progress in
                Task { @MainActor in
                    guard let self, download else { return }
                    self.state = .downloading(progress)
                }
            }
            lastLoadSeconds = duration
            proxy.setBackend(activeBackend)
            state = .ready
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    private func removeQwenFiles() async throws {
        do {
            try await qwenBackend.managedAsset?.removeFiles()
            if selectedBackend == .qwen {
                state = .notInstalled
                lastLoadSeconds = 0
            }
        } catch {
            if selectedBackend == .qwen {
                state = .failed(error.localizedDescription)
            }
            throw error
        }
    }
}
