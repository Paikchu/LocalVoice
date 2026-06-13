import Combine
import Foundation

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

    let service: MLXLanguageModelService
    private var task: Task<Void, Never>?

    init(service: MLXLanguageModelService = MLXLanguageModelService()) {
        self.service = service
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
            return "已就绪"
        case .failed(let message):
            return "失败：\(message)"
        }
    }

    var isReady: Bool {
        state == .ready
    }

    func preloadIfInstalled() {
        guard task == nil else { return }
        task = Task { [weak self] in
            guard let self else { return }
            let installed = await service.isInstalled()
            guard installed else {
                state = .notInstalled
                task = nil
                return
            }
            await load(download: false)
        }
    }

    func download() {
        guard task == nil else { return }
        task = Task { [weak self] in
            await self?.load(download: true)
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

    private func removeFilesAndUpdateState() async throws {
        do {
            try await service.removeFiles()
            state = .notInstalled
            lastLoadSeconds = 0
        } catch {
            state = .failed(error.localizedDescription)
            throw error
        }
    }

    func shutdown() {
        task?.cancel()
        task = nil
        Task {
            await service.unload()
        }
    }

    private func load(download: Bool) async {
        state = download ? .downloading(0) : .loading
        do {
            let duration = try await service.prepare { [weak self] progress in
                Task { @MainActor in
                    guard let self, download else { return }
                    self.state = .downloading(progress)
                }
            }
            lastLoadSeconds = duration
            state = .ready
        } catch {
            state = .failed(error.localizedDescription)
        }
        task = nil
    }
}
