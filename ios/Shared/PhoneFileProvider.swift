import Foundation

/// serves only files already on the phone. the watch owns the http fallback.
@MainActor
final class PhoneFileProvider {
    static let maximumTransfers = 4

    private let fileStore: FileStore
    private let currentToken: () -> String?
    private let outstanding: () -> [WatchFileTransfer]
    private let enqueue: (WatchFileTransfer, URL) -> Void
    private let cancelTransfer: (UUID) -> Void
    private let progress: (UUID) -> Double
    private let diagnostics: WatchDiagnostics

    init(
        fileStore: FileStore,
        currentToken: @escaping () -> String?,
        outstanding: @escaping () -> [WatchFileTransfer],
        enqueue: @escaping (WatchFileTransfer, URL) -> Void,
        cancel: @escaping (UUID) -> Void = { _ in },
        progress: @escaping (UUID) -> Double = { _ in 0 },
        diagnostics: WatchDiagnostics? = nil
    ) {
        self.fileStore = fileStore
        self.currentToken = currentToken
        self.outstanding = outstanding
        self.enqueue = enqueue
        self.cancelTransfer = cancel
        self.progress = progress
        self.diagnostics = diagnostics ?? .shared
    }

    func request(_ transfer: WatchFileTransfer, token: String) -> PhoneFileReply {
        let reply = classifyAndRequest(transfer, token: token)
        diagnostics.record(.init(kind: .phoneReply(reply), id: transfer.id, source: .phone,
                                 fileType: transfer.type, reply: reply,
                                 bytes: reply == .accepted ? fileSize(transfer.type, filename: transfer.filename, token: token) : nil))
        return reply
    }

    private func classifyAndRequest(_ transfer: WatchFileTransfer, token: String) -> PhoneFileReply {
        guard !token.isEmpty, token == currentToken() else { return .unauthorized }
        guard WatchFileTransfer.validFilename(transfer.filename) else { return .invalidRequest }
        let queued = outstanding()
        if queued.contains(transfer) { return .accepted }
        guard fileStore.exists(transfer.type, transfer.filename) else { return .cacheMiss }
        guard !queued.contains(where: { $0.file == transfer.file }) else { return .duplicate }
        guard queued.count < Self.maximumTransfers else { return .queueFull }
        enqueue(transfer, fileStore.fileURL(transfer.type, transfer.filename))
        return .accepted
    }

    func finished(_ transfer: WatchFileTransfer, error: Error?) {
        diagnostics.record(.init(kind: error == nil ? .phoneDelivered : .phoneFailed,
                                 id: transfer.id, source: .phone, fileType: transfer.type, error: error))
    }

    func fileSize(_ type: LibraryFileType, filename: String, token: String) -> Int64? {
        guard !token.isEmpty, token == currentToken(), WatchFileTransfer.validFilename(filename) else { return nil }
        let url = fileStore.fileURL(type, filename)
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey]),
              let size = values.fileSize, size > 0 else { return nil }
        return Int64(size)
    }

    /// the watch compares this snapshot with its current intent. the phone
    /// must not cancel jobs using a watch snapshot that can arrive out of order.
    func progress(token: String) -> [PhoneFileProgress]? {
        guard !token.isEmpty, token == currentToken() else { return nil }
        return outstanding().map { transfer in
            PhoneFileProgress(transfer: transfer, fraction: progress(transfer.id))
        }
    }

    func cancel(_ id: UUID) {
        cancelTransfer(id)
    }
}
