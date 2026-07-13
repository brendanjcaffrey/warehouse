import Foundation

/// handles a file arriving from the phone. media files move straight into
/// the file store — synchronously, because the system deletes the source as
/// soon as the delegate call returns — even when no sync is waiting, so
/// arrivals during background launches still shrink the next sync's missing
/// list. library data is read into memory for the awaiting sync to save
struct RelayFileReceiver: Sendable {
    enum Received: Equatable {
        case library(Data)
        case file(FileToDownload)
        case fileOutOfSpace(FileToDownload)
        case fileFailed(FileToDownload)
        case ignored
    }

    let fileStore: FileStore
    /// injectable so tests can simulate an out-of-space move failure
    var move: @Sendable (URL, URL) throws -> Void = { source, destination in
        try FileManager.default.moveItem(at: source, to: destination)
    }

    func receive(fileAt url: URL, metadata: [String: Any]?) -> Received {
        switch FileTransferMetadata(dictionary: metadata) {
        case .library:
            guard let data = try? Data(contentsOf: url) else { return .ignored }
            return .library(data)
        case .file(let file):
            guard !fileStore.exists(file.type, file.filename) else { return .file(file) }
            do {
                try FileManager.default.createDirectory(
                    at: fileStore.directoryURL(file.type), withIntermediateDirectories: true)
                try move(url, fileStore.fileURL(file.type, file.filename))
                return .file(file)
            } catch where BackgroundDownload.isOutOfSpace(error) {
                return .fileOutOfSpace(file)
            } catch {
                return .fileFailed(file)
            }
        case nil:
            return .ignored
        }
    }
}
