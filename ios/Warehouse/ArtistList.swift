import Foundation

struct Artist: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let sortName: String
    let albums: [Album]

    var sortKey: String { sortName.isEmpty ? name : sortName }
}

struct ArtistSection: Identifiable {
    let title: String
    let artists: [Artist]

    var id: String { title }
}

/// pure helpers for grouping the flat song list by artist and turning those
/// into the searchable, letter-sectioned list shown in the artists view
enum ArtistListBuilder {
    /// groups songs by track artist, so artists with only non-album singles
    /// still appear; each artist's albums are built from their songs and
    /// sorted by year (unknown years last) with ties broken by title, and
    /// any songs without an album collect into an unknown album at the end
    static func artists(from songs: [Song]) -> [Artist] {
        var order = [String]()
        var grouped = [String: [Song]]()
        for song in songs where !song.artistName.isEmpty {
            let key = fold(song.artistName)
            if grouped[key] == nil {
                order.append(key)
            }
            grouped[key, default: []].append(song)
        }

        return order.compactMap { key in
            guard let songs = grouped[key] else { return nil }
            var albums = AlbumListBuilder.albums(from: songs).sorted {
                (yearKey($0), fold($0.titleSortKey)) < (yearKey($1), fold($1.titleSortKey))
            }
            if let unknown = AlbumListBuilder.unknownAlbum(from: songs) {
                albums.append(unknown)
            }
            return Artist(
                id: key,
                name: songs[0].artistName,
                sortName: songs.first { !$0.artistSortName.isEmpty }?.artistSortName ?? "",
                albums: albums)
        }
    }

    /// the library artist matching a track artist name, if any songs have it
    static func artist(named name: String, in songs: [Song]) -> Artist? {
        guard !name.isEmpty else { return nil }
        let key = fold(name)
        return artists(from: songs.filter { fold($0.artistName) == key }).first
    }

    /// the library artist for an album; album artists that never appear as a
    /// track artist (e.g. compilations) get a standalone entry with just this album
    static func artist(for album: Album, in songs: [Song]) -> Artist? {
        guard !album.artistName.isEmpty else { return nil }
        return artist(named: album.artistName, in: songs) ?? Artist(
            id: fold(album.artistName),
            name: album.artistName,
            sortName: album.artistSortName,
            albums: [album])
    }

    static func sections(_ artists: [Artist], matching search: String) -> [ArtistSection] {
        let query = search.trimmingCharacters(in: .whitespaces)
        var filtered = artists
        if !query.isEmpty {
            filtered = artists.filter { $0.name.localizedCaseInsensitiveContains(query) }
        }

        let keyed = filtered
            .map { (artist: $0, key: fold($0.sortKey)) }
            .sorted { $0.key < $1.key }

        var artistsByTitle = [String: [Artist]]()
        for entry in keyed {
            artistsByTitle[SongListBuilder.sectionTitle(for: entry.key), default: []].append(entry.artist)
        }

        var titles = artistsByTitle.keys.sorted()
        if let index = titles.firstIndex(of: "#") {
            titles.remove(at: index)
            titles.append("#")
        }
        return titles.map { ArtistSection(title: $0, artists: artistsByTitle[$0] ?? []) }
    }

    /// unknown years sort after known ones
    private static func yearKey(_ album: Album) -> Int {
        album.year == 0 ? Int.max : album.year
    }

    private static func fold(_ value: String) -> String {
        SongListBuilder.fold(value)
    }
}
