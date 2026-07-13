import Foundation
import SwiftProtobuf

/// how a relayed library fetch can fail: the phone reported a server error,
/// or the library file never arrived
enum RelayLibraryError: Error {
    case server(String)
    case timeout
}

/// serves version & library data by asking the phone over watch connectivity
/// instead of the server. an unreachable phone throws the same offline error
/// a direct fetch would, so the sync falls back to its cached data
final class RelayLibraryProvider: LibraryProviding, Sendable {
    private let isReachable: @Sendable () -> Bool
    private let sendWithReply: @Sendable ([String: Any]) async throws -> [String: Any]
    private let awaitLibrary: @Sendable (TimeInterval) async throws -> Data
    private let libraryTimeout: TimeInterval

    init(
        isReachable: @escaping @Sendable () -> Bool,
        sendWithReply: @escaping @Sendable ([String: Any]) async throws -> [String: Any],
        awaitLibrary: @escaping @Sendable (TimeInterval) async throws -> Data,
        libraryTimeout: TimeInterval = 600
    ) {
        self.isReachable = isReachable
        self.sendWithReply = sendWithReply
        self.awaitLibrary = awaitLibrary
        self.libraryTimeout = libraryTimeout
    }

    func fetchVersion(token: String, baseURL: URL) async throws -> LibraryClient.VersionResult {
        switch VersionReply(dictionary: try await reply(to: RelayRequest.version)) {
        case .updateTimeNs(let updateTimeNs):
            return .updateTimeNs(updateTimeNs)
        case .error(let message):
            return .error(message)
        case .offline, nil:
            // the phone is reachable but the server isn't (or the reply was
            // junk); either way there's nothing new to sync
            throw URLError(.notConnectedToInternet)
        }
    }

    func fetchLibrary(token: String, baseURL: URL) async throws -> LibraryClient.LibraryResult {
        guard RelayRequest.isAccepted(try await reply(to: RelayRequest.library)) else {
            throw URLError(.notConnectedToInternet)
        }
        do {
            return .library(try Library(serializedBytes: try await awaitLibrary(libraryTimeout)))
        } catch RelayLibraryError.server(let message) {
            return .error(message)
        } catch RelayLibraryError.timeout {
            throw URLError(.timedOut)
        }
    }

    private func reply(to request: String) async throws -> [String: Any] {
        guard isReachable() else { throw URLError(.notConnectedToInternet) }
        do {
            return try await sendWithReply(RelayRequest.encode(request))
        } catch {
            // an undelivered message is the relay's flavor of being offline
            throw URLError(.notConnectedToInternet)
        }
    }
}
