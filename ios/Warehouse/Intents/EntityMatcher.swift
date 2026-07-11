import Foundation

/// pure lookup helpers backing the app entity queries; reuses the list
/// builders so name matching & ordering stay consistent with the app's views
enum EntityMatcher {
    static func albums(in songs: [Song], matching query: String) -> [Album] {
        SearchListBuilder.results(songs, scope: .albums, matching: query).albums
    }

    static func albums(in songs: [Song], ids: [String]) -> [Album] {
        let wanted = Set(ids)
        return AlbumListBuilder.albums(from: songs).filter { wanted.contains($0.id) }
    }

    static func artists(in songs: [Song], matching query: String) -> [Artist] {
        SearchListBuilder.results(songs, scope: .artists, matching: query).artists
    }

    static func artists(in songs: [Song], ids: [String]) -> [Artist] {
        let wanted = Set(ids)
        return ArtistListBuilder.artists(from: songs).filter { wanted.contains($0.id) }
    }

    static func songs(in songs: [Song], matching query: String) -> [Song] {
        SearchListBuilder.results(songs, scope: .songs, matching: query).songs
    }

    static func songs(in songs: [Song], ids: [String]) -> [Song] {
        let byId = Dictionary(songs.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return ids.compactMap { byId[$0] }
    }

    /// real playlists only, alphabetical; folders & the library playlist
    /// aren't playable
    static func playlists(in playlists: [PlaylistItem]) -> [PlaylistItem] {
        playlists
            .filter { !$0.isLibrary && !$0.isFolder }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    static func playlists(in playlists: [PlaylistItem], matching query: String) -> [PlaylistItem] {
        let query = query.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return [] }
        return self.playlists(in: playlists).filter { $0.name.localizedCaseInsensitiveContains(query) }
    }

    static func playlists(in playlists: [PlaylistItem], ids: [String]) -> [PlaylistItem] {
        let wanted = Set(ids)
        return self.playlists(in: playlists).filter { wanted.contains($0.id) }
    }

    /// the playlist's songs in playlist order
    static func songs(for playlist: PlaylistItem, in songs: [Song]) -> [Song] {
        SongListBuilder.playlistSongs(songs, trackIds: playlist.trackIds)
    }

    /// every song by an artist, in the artist view's album order
    static func songs(for artist: Artist) -> [Song] {
        artist.albums.flatMap(\.songs)
    }
}
