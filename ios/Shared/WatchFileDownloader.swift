import Foundation

/// tries the phone for cache fills, with a deadline so a queued background
/// transfer never prevents the normal server download from making progress.
@MainActor
final class WatchFileDownloader: SingleFileDownloading {
    struct Transport {
        var isReachable: @MainActor () -> Bool
        var currentToken: @MainActor () -> String?
        var request: @MainActor (WatchFileTransfer, String, @escaping @MainActor (Bool) -> Void) -> Void
        var cancel: @MainActor (UUID) -> Void
    }

    private struct Pending {
        let transfer: WatchFileTransfer
        let token: String
        let continuation: CheckedContinuation<FileDownloadResult, Never>
        let deadline: Task<Void, Never>
    }

    private let fileStore: FileStore
    private let fallback: SingleFileDownloading
    private let timeout: Duration
    private let transport: Transport
    private var pending: [UUID: Pending] = [:]

    init(
        fileStore: FileStore, fallback: SingleFileDownloading,
        timeout: Duration = .seconds(30), transport: Transport
    ) {
        self.fileStore = fileStore
        self.fallback = fallback
        self.timeout = timeout
        self.transport = transport
    }

    @MainActor
    func download(_ type: LibraryFileType, filename: String, token: String, baseURL: URL) async -> Bool {
        await downloadResult(type, filename: filename, token: token, baseURL: baseURL, onPhase: { _ in }) == .downloaded
    }

    @MainActor
    func downloadResult(
        _ type: LibraryFileType, filename: String, token: String, baseURL: URL,
        onPhase: @escaping @MainActor @Sendable (FileDownloadPhase) -> Void
    ) async -> FileDownloadResult {
        guard !Task.isCancelled, WatchFileTransfer.validFilename(filename), token == transport.currentToken() else { return .failed }
        if fileStore.exists(type, filename) { return .downloaded }
        if transport.isReachable(), pending.count < PhoneFileProvider.maximumTransfers {
            onPhase(.waitingForPhone)
            let transfer = WatchFileTransfer(type: type, filename: filename)
            let received: FileDownloadResult = await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    guard !Task.isCancelled else {
                        continuation.resume(returning: .failed)
                        return
                    }
                    // artwork is visible now; give it a shorter phone wait
                    // than the music being filled ahead of playback.
                    let wait = type == .artwork ? min(timeout, .seconds(2)) : timeout
                    let deadline = Task { @MainActor [weak self] in
                        do { try await Task.sleep(for: wait) } catch { return }
                        self?.finish(transfer.id, result: .failed)
                    }
                    pending[transfer.id] = Pending(
                        transfer: transfer, token: token, continuation: continuation, deadline: deadline)
                    transport.request(transfer, token) { [weak self] accepted in
                        if !accepted { self?.finish(transfer.id, result: .failed) }
                    }
                }
            } onCancel: {
                Task { @MainActor in self.finish(transfer.id, result: .failed) }
            }
            if received != .failed { return received }
        }
        guard !Task.isCancelled, token == transport.currentToken() else { return .failed }
        return await fallback.downloadResult(type, filename: filename, token: token, baseURL: baseURL, onPhase: onPhase)
    }

    /// only a matching, still-awaited file may enter the cache. timed-out,
    /// cancelled and unsolicited deliveries are removed without replacing it.
    func receive(_ transfer: WatchFileTransfer, from temporary: URL) {
        defer { try? FileManager.default.removeItem(at: temporary) }
        guard let request = pending[transfer.id], request.transfer == transfer else { return }
        guard request.token == transport.currentToken() else {
            finish(transfer.id, result: .failed)
            return
        }
        do {
            if !fileStore.exists(transfer.type, transfer.filename) {
                try fileStore.moveIn(transfer.type, transfer.filename, from: temporary)
            }
            finish(transfer.id, result: .downloaded)
        } catch {
            finish(transfer.id, result: BackgroundDownload.isOutOfSpace(error) ? .outOfSpace : .failed)
        }
    }

    func failed(_ transfer: WatchFileTransfer) {
        guard pending[transfer.id]?.transfer == transfer else { return }
        finish(transfer.id, result: .failed)
    }

    private func finish(_ id: UUID, result: FileDownloadResult) {
        guard let request = pending.removeValue(forKey: id) else { return }
        request.deadline.cancel()
        if result != .downloaded { transport.cancel(id) }
        request.continuation.resume(returning: result)
    }
}
