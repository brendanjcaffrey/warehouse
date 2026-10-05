import CryptoKit
import Foundation
import SwiftProtobuf

/// the head travels in application context; the complete snapshot travels as a file.
struct WatchLibraryHead: Codable, Equatable, Sendable {
    var version = 1
    let publisher: UUID
    let revision: Int64
    let libraryID: String?
    let playlistIDs: [String]
    var metadataReady: Bool
    var failed: Bool?

    /// content identity survives forward metadata revisions within the same publisher and library.
    func retainsContent(from previous: WatchLibraryHead) -> Bool {
        version == previous.version && publisher == previous.publisher && libraryID?.isEmpty == false
            && libraryID == previous.libraryID && revision >= previous.revision
    }

    func encode() throws -> [String: Any] {
        ["watchLibraryHead": try JSONEncoder().encode(self)]
    }

    init(publisher: UUID, revision: Int64, libraryID: String?, playlistIDs: [String], metadataReady: Bool = false) {
        self.publisher = publisher
        self.revision = revision
        self.libraryID = libraryID
        self.playlistIDs = playlistIDs
        self.metadataReady = metadataReady
        failed = nil
    }

    init?(context: [String: Any]) {
        guard let data = context["watchLibraryHead"] as? Data,
              let head = try? JSONDecoder().decode(Self.self, from: data) else { return nil }
        self = head
    }
}

/// requests report committed metadata, never merely the latest received control head.
struct WatchLibraryRequest: Codable, Equatable, Sendable {
    var acceptedHead: WatchLibraryHead?

    init(acceptedHead: WatchLibraryHead?) { self.acceptedHead = acceptedHead }

    init?(dictionary: [String: Any]) {
        guard dictionary["kind"] as? String == "watchLibraryRequest" else { return nil }
        acceptedHead = WatchLibraryHead(context: dictionary)
    }

    func encode() throws -> [String: Any] {
        var info = try acceptedHead?.encode() ?? [:]
        info["kind"] = "watchLibraryRequest"
        return info
    }
}

struct WatchLibrarySnapshot: Codable, Equatable, Sendable {
    let head: WatchLibraryHead
    let libraryData: Data

    var library: Library { get throws { try Library(serializedBytes: libraryData) } }
    var music: Set<String> { get throws { Set(try library.tracks.map(\.musicFilename)) } }
    var artwork: Set<String> { get throws { Set(try library.tracks.map(\.artworkFilename).filter { !$0.isEmpty }) } }

    func validatedLibrary() throws -> Library {
        guard head.version == 1, head.revision > 0, head.metadataReady, head.failed != true, head.libraryID?.isEmpty == false else {
            throw WatchLibraryError.unsupported
        }
        let library = try library
        let tracks = Set(library.tracks.map(\.id))
        let playlists = Dictionary(library.playlists.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        guard tracks.count == library.tracks.count, !tracks.contains(""),
              playlists.count == library.playlists.count, playlists[""] == nil,
              Set(head.playlistIDs).count == head.playlistIDs.count,
              Set(head.playlistIDs).isSubset(of: Set(playlists.keys)) else { throw WatchLibraryError.invalid }
        for track in library.tracks {
            try FileStore.checkFilename(track.musicFilename)
            if !track.artworkFilename.isEmpty { try FileStore.checkFilename(track.artworkFilename) }
            guard track.duration.isFinite, track.start.isFinite, track.finish.isFinite,
                  track.year <= Int32.max, track.trackNumber <= Int32.max, track.discNumber <= Int32.max,
                  track.playCount <= Int64.max else { throw WatchLibraryError.invalid }
        }
        for playlist in library.playlists {
            guard Set(playlist.trackIds).isSubset(of: tracks) else { throw WatchLibraryError.invalid }
            var ancestors = Set([playlist.id])
            var parent = playlist.parentID
            while !parent.isEmpty {
                guard ancestors.insert(parent).inserted, let folder = playlists[parent] else { throw WatchLibraryError.invalid }
                parent = folder.parentID
            }
        }
        let selected = try Self.selected(library, ids: head.playlistIDs)
        guard Set(selected.tracks.map(\.id)) == tracks,
              Set(selected.playlists.map(\.id)) == Set(playlists.keys) else { throw WatchLibraryError.invalid }
        return library
    }

    static func selected(_ library: Library, ids: [String]) throws -> Library {
        let byID = Dictionary(library.playlists.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var included = Set(ids)
        var trackIDs = Set<String>()
        for id in ids {
            guard let playlist = byID[id], !playlist.isLibrary,
                  !library.playlists.contains(where: { $0.parentID == id }) else { throw WatchLibraryError.invalid }
            trackIDs.formUnion(playlist.trackIds)
            var parent = playlist.parentID
            var seen = Set([id])
            while !parent.isEmpty {
                guard seen.insert(parent).inserted, let folder = byID[parent] else { throw WatchLibraryError.invalid }
                included.insert(parent)
                parent = folder.parentID
            }
        }
        let available = Set(library.tracks.map(\.id))
        guard available.count == library.tracks.count, byID.count == library.playlists.count,
              trackIDs.isSubset(of: available) else { throw WatchLibraryError.invalid }
        var result = library
        result.tracks = library.tracks.filter { trackIDs.contains($0.id) }.map {
            var track = $0
            track.playlistIds = track.playlistIds.filter { included.contains($0) }
            return track
        }
        result.playlists = library.playlists.filter { included.contains($0.id) }.map {
            var playlist = $0
            playlist.trackIds = playlist.trackIds.filter { trackIDs.contains($0) }
            return playlist
        }
        let artists = Set(result.tracks.flatMap { [$0.artistID, $0.albumArtistID] })
        let albums = Set(result.tracks.map(\.albumID))
        let genres = Set(result.tracks.map(\.genreID))
        result.artists = result.artists.filter { artists.contains($0.key) }
        result.albums = result.albums.filter { albums.contains($0.key) }
        result.genres = result.genres.filter { genres.contains($0.key) }
        return result
    }
}

enum WatchLibraryError: Error {
    case unsupported
    case invalid
    case notLoaded
}

/// token signatures and expiries are excluded; this is a namespace, not authentication.
enum LibraryIdentity {
    static func make(token: String?, baseURL: URL?) -> String? {
        guard let token, let baseURL, let username = JWT.username(of: token) else { return nil }
        var origin = baseURL.absoluteString
        while origin.hasSuffix("/") { origin.removeLast() }
        return SHA256.hash(data: Data("\(origin)\n\(username)".utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
