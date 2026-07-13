import Foundation
import SwiftProtobuf
import UIKit

/// connects the relay engine to the wc session, file store & server client,
/// so the watch can sync through the phone instead of reaching the server
enum WatchRelayWiring {
    @MainActor
    static func install(
        session: PhoneWatchSession,
        fileStore: FileStore,
        auth: AuthStore
    ) -> WatchRelayEngine {
        let client = LibraryClient()

        let engine = WatchRelayEngine(
            isOnPhone: { fileStore.exists($0.type, $0.filename) },
            transfer: { file in
                session.transferFile(
                    at: fileStore.fileURL(file.type, file.filename), metadata: .file(file))
            },
            outstandingTransfers: { session.outstandingFileTransfers },
            sendResult: { session.send($0) })

        session.onFileRequest = { engine.handle($0) }
        session.onCancelFileRequests = {
            engine.cancelAll()
            session.cancelOutstandingFileTransfers()
        }
        session.onFileTransferFinished = { metadata, url, error in
            switch metadata {
            case .file(let file):
                engine.transferDidFinish(file: file, error: error)
            case .library:
                // the library proto was spooled to a temp file just for this
                try? FileManager.default.removeItem(at: url)
            }
        }
        session.onVersionRequest = {
            guard let token = auth.token, let baseURL = auth.baseURL() else {
                return .error("The phone isn't logged in.")
            }
            do {
                switch try await client.fetchVersion(token: token, baseURL: baseURL) {
                case .updateTimeNs(let updateTimeNs):
                    return .updateTimeNs(updateTimeNs)
                case .error(let message):
                    return .error(message)
                case .empty:
                    return .error("The server returned an empty response.")
                }
            } catch let error as URLError where error.isOfflineError {
                return .offline
            } catch {
                return .error(error.localizedDescription)
            }
        }
        session.onLibraryRequest = {
            Task { @MainActor in
                await sendLibrary(session: session, client: client, auth: auth)
            }
        }

        return engine
    }

    @MainActor
    private static func sendLibrary(session: PhoneWatchSession, client: LibraryClient, auth: AuthStore) async {
        guard let token = auth.token, let baseURL = auth.baseURL() else {
            session.send(LibraryResultPayload(error: "The phone isn't logged in."))
            return
        }
        do {
            try await withPhoneRuntime {
                switch try await client.fetchLibrary(token: token, baseURL: baseURL) {
                case .library(let library):
                    // the watch trims this to its synced playlists itself,
                    // the same way it does for a direct fetch today
                    let url = FileManager.default.temporaryDirectory
                        .appending(path: "watch-library-\(UUID().uuidString).pb")
                    try library.serializedData().write(to: url)
                    session.transferFile(at: url, metadata: .library(updateTimeNs: library.updateTimeNs))
                case .error(let message):
                    session.send(LibraryResultPayload(error: message))
                case .empty:
                    session.send(LibraryResultPayload(error: "The server returned an empty response."))
                }
            }
        } catch {
            session.send(LibraryResultPayload(error: error.localizedDescription))
        }
    }

    /// keeps ios from suspending the app mid-fetch when a watch request woke
    /// it in the background; each request buys a fresh window
    @MainActor
    private static func withPhoneRuntime<T>(_ body: () async throws -> T) async rethrows -> T {
        let taskId = UIApplication.shared.beginBackgroundTask()
        defer { UIApplication.shared.endBackgroundTask(taskId) }
        return try await body()
    }
}
