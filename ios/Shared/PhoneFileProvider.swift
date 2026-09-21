import Foundation

/// serves only files already on the phone. the watch owns the http fallback.
@MainActor
final class PhoneFileProvider {
    static let maximumTransfers = 4

    private let fileStore: FileStore
    private let currentToken: () -> String?
    private let outstanding: () -> [WatchFileTransfer]
    private let enqueue: (WatchFileTransfer, URL) -> Void

    init(
        fileStore: FileStore,
        currentToken: @escaping () -> String?,
        outstanding: @escaping () -> [WatchFileTransfer],
        enqueue: @escaping (WatchFileTransfer, URL) -> Void
    ) {
        self.fileStore = fileStore
        self.currentToken = currentToken
        self.outstanding = outstanding
        self.enqueue = enqueue
    }

    func request(_ transfer: WatchFileTransfer, token: String) -> Bool {
        guard !token.isEmpty, token == currentToken(),
              WatchFileTransfer.validFilename(transfer.filename),
              fileStore.exists(transfer.type, transfer.filename)
        else { return false }
        let queued = outstanding()
        if queued.contains(transfer) { return true }
        guard queued.count < Self.maximumTransfers,
              !queued.contains(where: { $0.type == transfer.type && $0.filename == transfer.filename })
        else { return false }
        enqueue(transfer, fileStore.fileURL(transfer.type, transfer.filename))
        return true
    }
}
