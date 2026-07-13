import Foundation
import SwiftProtobuf

/// answers the watch's library request: fetches the library from the server &
/// hands it over the relay as a file transfer, trimmed to the playlists the
/// watch syncs so only the tracks it actually keeps go over the wire. failures
/// ride back as a result payload, since a successful fetch is announced by the
/// file itself arriving
@MainActor
final class WatchLibrarySender {
    struct Credentials {
        let token: String
        let baseURL: URL
    }

    private let credentials: @MainActor () -> Credentials?
    private let playlistIds: @MainActor () -> [String]
    private let fetchLibrary: @MainActor (String, URL) async throws -> LibraryClient.LibraryResult
    private let spool: @MainActor (Library) throws -> URL
    private let transfer: @MainActor (URL, FileTransferMetadata) -> Void
    private let sendError: @MainActor (String) -> Void

    // spool is a parameter for tests; it writes to a temp file by default
    init(
        credentials: @escaping @MainActor () -> Credentials?,
        playlistIds: @escaping @MainActor () -> [String],
        fetchLibrary: @escaping @MainActor (String, URL) async throws -> LibraryClient.LibraryResult,
        spool: @escaping @MainActor (Library) throws -> URL = WatchLibrarySender.spoolToTemporaryFile,
        transfer: @escaping @MainActor (URL, FileTransferMetadata) -> Void,
        sendError: @escaping @MainActor (String) -> Void
    ) {
        self.credentials = credentials
        self.playlistIds = playlistIds
        self.fetchLibrary = fetchLibrary
        self.spool = spool
        self.transfer = transfer
        self.sendError = sendError
    }

    func send() async {
        guard let credentials = credentials() else {
            sendError("The phone isn't logged in.")
            return
        }
        do {
            switch try await fetchLibrary(credentials.token, credentials.baseURL) {
            case .library(let library):
                let filtered = LibraryFilter.filter(library, playlistIds: Set(playlistIds()))
                transfer(try spool(filtered), .library(updateTimeNs: filtered.updateTimeNs))
            case .error(let message):
                sendError(message)
            case .empty:
                sendError("The server returned an empty response.")
            }
        } catch {
            sendError(error.localizedDescription)
        }
    }

    /// the proto is spooled to disk because watch connectivity only transfers
    /// files; the wiring deletes it once the transfer finishes
    static func spoolToTemporaryFile(_ library: Library) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "watch-library-\(UUID().uuidString).pb")
        try library.serializedData().write(to: url)
        return url
    }
}
