import Foundation
import SwiftProtobuf

/// pure planning for the watch's bundle-based sync: which single request to
/// make next, and the little bit of state that has to survive process death
enum BundleSync {
    /// the server rejects bundles bigger than these
    static let maxMusicPerBundle = 50
    static let maxArtworkPerBundle = 1000

    enum BundleError: LocalizedError, Equatable {
        case server(String)
        case emptyResponse

        var errorDescription: String? {
            switch self {
            case .server(let message):
                return message
            case .emptyResponse:
                return "The server returned an empty response."
            }
        }
    }

    /// persisted as json so a background wake can pick the chain back up
    /// without the ui running; progress itself is always recounted from disk
    struct State: Codable, Equatable, Sendable {
        var pendingFiles: [FileToDownload] = []
        /// a bundle the server already built but the watch hasn't finished
        /// downloading, so a relaunch re-downloads instead of re-registering
        /// (the server caches every registered bundle)
        var pendingBundleId: String?
        var retriesUsed = 0
    }

    enum Step: Equatable, Sendable {
        case register(type: LibraryFileType, filenames: [String])
        case download(bundleId: String)
        case finished
    }

    static func cap(for type: LibraryFileType) -> Int {
        switch type {
        case .music: return maxMusicPerBundle
        case .artwork: return maxArtworkPerBundle
        }
    }

    /// the one request to make next: finish downloading an already-registered
    /// bundle, else register the next chunk of files not yet on disk, music
    /// before artwork
    static func nextStep(state: State, isOnDisk: (FileToDownload) -> Bool) -> Step {
        if let bundleId = state.pendingBundleId {
            return .download(bundleId: bundleId)
        }
        for type in LibraryFileType.allCases {
            let missing = state.pendingFiles.filter { $0.type == type && !isOnDisk($0) }
            if !missing.isEmpty {
                return .register(type: type, filenames: missing.prefix(cap(for: type)).map(\.filename))
            }
        }
        return .finished
    }

    static func registrationRequest(type: LibraryFileType, filenames: [String]) throws -> Data {
        var request = BundleRequest()
        request.type = type == .music ? .music : .artwork
        request.filenames = filenames
        return try request.serializedData()
    }

    static func bundleId(fromResponseData data: Data) throws -> String {
        let response = try BundleResponse(serializedBytes: data)
        switch response.response {
        case .id(let id):
            return id
        case .error(let message):
            throw BundleError.server(message)
        case .none:
            throw BundleError.emptyResponse
        }
    }

    static func defaultStateURL() -> URL {
        URL.applicationSupportDirectory.appending(path: "bundle-sync.json")
    }

    static func loadState(from url: URL) -> State? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(State.self, from: data)
    }

    static func save(_ state: State, to url: URL) {
        guard let data = try? JSONEncoder().encode(state) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
