import Foundation

enum SearchScope: String, CaseIterable, Identifiable, Sendable {
    case artists
    case albums
    case songs

    var id: String { rawValue }

    var label: String {
        switch self {
        case .artists:
            return "Artists"
        case .albums:
            return "Albums"
        case .songs:
            return "Songs"
        }
    }
}

struct SearchResults: Equatable, Sendable {
    var artists = [Artist]()
    var albums = [Album]()
    var songs = [Song]()

    var isEmpty: Bool { artists.isEmpty && albums.isEmpty && songs.isEmpty }
}

/// pure helpers for the app wide search tab; reuses the per-list builders so
/// matching and ordering stay consistent with the library views
enum SearchListBuilder {
    static func results(_ songs: [Song], scope: SearchScope, matching search: String) -> SearchResults {
        let query = search.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return SearchResults() }

        var results = SearchResults()
        switch scope {
        case .artists:
            let artists = ArtistListBuilder.artists(from: songs)
            results.artists = ArtistListBuilder.sections(artists, matching: query).flatMap(\.artists)
        case .albums:
            let albums = AlbumListBuilder.albums(from: songs)
            results.albums = AlbumListBuilder.sections(albums, sortedBy: .title, matching: query).flatMap(\.albums)
        case .songs:
            results.songs = SongListBuilder.sections(songs, sortedBy: .title, matching: query).flatMap(\.songs)
        }
        return results
    }
}
