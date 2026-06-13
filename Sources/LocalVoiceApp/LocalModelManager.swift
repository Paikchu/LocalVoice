import Combine
import Foundation
import LocalVoiceCore

/// Owns backend selection and lifecycle for the menu UI.
///
/// Selection is automatic per the product rule:
///   1. If the device supports the system model (Apple 智能), use it — nothing to
///      download or remove.
///   2. Otherwise fall back to the downloadable local model and drive the existing
///      download → ready flow.
///
/// `DraftProcessingService` holds `proxy` for its whole lifetime; this manager
/// repoints the proxy at whichever backend becomes active.
@MainActor
final class LocalModelManager: ObservableObject {
    enum State: Equatable {
        case notInstalled
        case downloading(Double)
        case loading
        case ready
        case failed(String)
    }

    @Published private(set) var state: State = .notInstalled
    @Published private(set) var lastLoadSeconds: Double = 0
    @Published private(set) var descriptor: BackendDescriptor
    /// True while the OS-provided system model is the active backend. The UI hides
    /// the download/remove controls in this case.
    @Published private(set) var usingSystemModel: Bool = false

    /// Stable generation entry point handed to `DraftProcessingService`.
    let proxy: ActiveBackendProxy

    private let systemBackend: any LanguageModelBackend
    private let downloadableBackend: any LanguageModelBackend
    private var active: any LanguageModelBackend
    private var task: Task<Void, Never>?

    init(
        systemBackend: any LanguageModelBackend = FoundationModelBackend(),
        downloadableBackend: any LanguageModelBackend = MLXLanguageModelService()
    ) {
        self.systemBackend = systemBackend
        self.downloadableBackend = downloadableBackend
        self.active = downloadableBackend
        self.descriptor = downloadableBackend.descriptor
        self.proxy = ActiveBackendProxy(downloadableBackend)
    }

    var statusText: String {
        switch state {
        case .notInstalled:
            return "未下载"
        case .downloading(let progress):
            let percent = Int(progress * 100)
            return percent > 0 ? "下载中 \(percent)%" : "下载中"
        case .loading:
            return "加载中"
        case .ready:
            return usingSystemModel ? "已就绪（系统模型）" : "已就绪"
        case .failed(let message):
            return "失败：\(message)"
        }
    }

    var isReady: Bool {
        state == .ready
    }

    /// Resolve the backend at startup: prefer the system model, else fall back to the
    /// installed-or-not downloadable model. Name kept for the existing call site.
    func preloadIfInstalled() {
        guard task == nil else { return }
        task = Task { [weak self] in
            guard let self else { return }
            if case .available = await systemBackend.availability() {
                await activateSystemModel()
                task = nil
                return
            }
            // Device does not support the system model: prompt to download instead.
            useDownloadableBackend()
            let installed = await downloadableBackend.managedAsset?.isInstalled() ?? false
            guard installed else {
                state = .notInstalled
                task = nil
                return
            }
            await load(download: false)
            task = nil
        }
    }

    func download() {
        guard task == nil else { return }
        task = Task { [weak self] in
            guard let self else { return }
            useDownloadableBackend()
            await load(download: true)
            task = nil
        }
    }

    func remove() {
        task?.cancel()
        task = Task { [weak self] in
            guard let self else { return }
            do {
                try await removeFilesAndUpdateState()
            } catch {}
            task = nil
        }
    }

    func clearFiles() async throws {
        task?.cancel()
        task = nil
        try await removeFilesAndUpdateState()
    }

    func shutdown() {
        task?.cancel()
        task = nil
        let backend = active
        Task {
            await backend.unload()
        }
    }

    private func activateSystemModel() async {
        active = systemBackend
        descriptor = systemBackend.descriptor
        usingSystemModel = true
        state = .loading
        do {
            let duration = try await systemBackend.prepare { _ in }
            lastLoadSeconds = duration
            proxy.setBackend(systemBackend)
            state = .ready
        } catch {
            // System model became unavailable between the check and prepare: fall
            // back to the downloadable model rather than leaving dictation dead.
            useDownloadableBackend()
            let installed = await downloadableBackend.managedAsset?.isInstalled() ?? false
            if installed {
                await load(download: false)
            } else {
                state = .notInstalled
            }
        }
    }

    private func useDownloadableBackend() {
        active = downloadableBackend
        descriptor = downloadableBackend.descriptor
        usingSystemModel = false
    }

    private func removeFilesAndUpdateState() async throws {
        do {
            try await downloadableBackend.managedAsset?.removeFiles()
            useDownloadableBackend()
            state = .notInstalled
            lastLoadSeconds = 0
        } catch {
            state = .failed(error.localizedDescription)
            throw error
        }
    }

    private func load(download: Bool) async {
        state = download ? .downloading(0) : .loading
        do {
            let duration = try await active.prepare { [weak self] progress in
                Task { @MainActor in
                    guard let self, download else { return }
                    self.state = .downloading(progress)
                }
            }
            lastLoadSeconds = duration
            proxy.setBackend(active)
            state = .ready
        } catch {
            state = .failed(error.localizedDescription)
        }
    }
}
