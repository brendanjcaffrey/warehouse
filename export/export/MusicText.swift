import Foundation

struct MusicTextError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

struct TrackText: Equatable {
    let lyrics: String
    let comments: String
}

struct TrackComments {
    let id: String
    let comments: String
}

struct LyricsKindPolicy {
    let allowed: Set<String>
    let blocked: Set<String>

    static let music = LyricsKindPolicy(
        allowed: ["MPEG audio file", "AAC audio file", "Purchased AAC audio file", "Purchased MPEG-4 video file"],
        blocked: ["WAV audio file"]
    )
}

protocol MusicTextSource {
    func fileTrackCount() throws -> Int
    func strings(_ property: String, lyricsOnly: Bool) throws -> [Any]
    func excludeLyricsKinds(_ kinds: Set<String>) throws
}

enum MusicTextExport {
    static func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw MusicTextError(message: message) }
    }

    private static func ids(_ values: [Any]) throws -> [String] {
        guard let ids = values as? [String] else {
            throw MusicTextError(message: "missing or non-text music persistent ids")
        }
        try require(ids.allSatisfy { $0.range(of: "^[0-9A-F]{16}$", options: .regularExpression) != nil },
                    "invalid music persistent id")
        try require(Set(ids).count == ids.count, "duplicate music persistent ids")
        return ids
    }

    private static func text(_ values: [Any], count: Int, field: String) throws -> [String] {
        guard let strings = values as? [String], strings.count == count else {
            throw MusicTextError(message: "missing, non-text or shortened music \(field) result")
        }
        try require(strings.allSatisfy { !$0.utf8.contains(0) }, "music \(field) contains a database-incompatible nul")
        return strings
    }

    static func read(comments: [TrackComments], source: MusicTextSource,
                     policy: LyricsKindPolicy = .music) throws -> [String: TrackText] {
        try require(!policy.allowed.isEmpty && policy.allowed.isDisjoint(with: policy.blocked),
                    "invalid or overlapping lyrics kind policy")
        let expected = try ids(comments.map(\.id))
        _ = try text(comments.map(\.comments), count: expected.count, field: "comments")
        let commentsByID = Dictionary(uniqueKeysWithValues: comments.map { ($0.id, $0.comments) })
        let count = try source.fileTrackCount()
        let inventoryIDs = try ids(source.strings("persistentID", lyricsOnly: false))
        try require(inventoryIDs.count == count, "incomplete music file-track inventory")
        let kinds = try text(source.strings("kind", lyricsOnly: false), count: inventoryIDs.count, field: "kinds")
        try require(Set(expected).isSubset(of: Set(inventoryIDs)), "export tracks missing from music file-track inventory")
        let unknown = Set(kinds).subtracting(policy.allowed.union(policy.blocked))
        try require(unknown.isEmpty, "unclassified music file types: \(unknown.sorted().joined(separator: ", "))")
        let allowedIDs = Set(zip(inventoryIDs, kinds).filter { policy.allowed.contains($0.1) }.map(\.0))

        // classify the complete inventory before excluding blocklisted lyrics.
        try source.excludeLyricsKinds(policy.blocked)
        let lyricIDs = try ids(source.strings("persistentID", lyricsOnly: true))
        try require(Set(lyricIDs) == allowedIDs, "allowlisted lyrics persistent id coverage mismatch")
        let lyrics = try text(source.strings("lyrics", lyricsOnly: true), count: lyricIDs.count, field: "lyrics")
        let lyricIDsAfter = try ids(source.strings("persistentID", lyricsOnly: true))
        let idsAfter = try ids(source.strings("persistentID", lyricsOnly: false))
        let kindsAfter = try text(source.strings("kind", lyricsOnly: false), count: inventoryIDs.count, field: "kinds")
        try require(lyricIDs == lyricIDsAfter && inventoryIDs == idsAfter && kinds == kindsAfter,
                    "music file-track inventory changed during text read; retry export")
        try require(try source.fileTrackCount() == count, "music file-track count changed during text read; retry export")

        let lyricsByID = Dictionary(uniqueKeysWithValues: zip(lyricIDs, lyrics))
        var result: [String: TrackText] = [:]
        let expectedSet = Set(expected)
        for id in inventoryIDs where expectedSet.contains(id) {
            // only explicitly blocklisted kinds assume empty lyrics.
            result[id] = TrackText(lyrics: lyricsByID[id] ?? "", comments: commentsByID[id]!)
        }
        return result
    }

    static func run<Result>(comments: [TrackComments], source: MusicTextSource,
                            rebuild: ([String: TrackText]) async throws -> Result) async throws -> Result {
        let snapshot = try read(comments: comments, source: source)
        return try await rebuild(snapshot)
    }
}
