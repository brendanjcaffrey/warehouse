import Foundation

struct Album: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let sortName: String
    let artistName: String
    let artistSortName: String
    let genre: String
    let year: Int
    let artworkFilename: String?
    let songs: [Song]

    var titleSortKey: String { sortName.isEmpty ? name : sortName }
    var artistSortKey: String { artistSortName.isEmpty ? artistName : artistSortName }

    /// songs split into their discs, in disc order; songs are already sorted by
    /// disc & track number so each disc's songs stay contiguous
    var discs: [DiscGroup] {
        var order = [Int]()
        var grouped = [Int: [Song]]()
        for song in songs {
            if grouped[song.discNumber] == nil {
                order.append(song.discNumber)
            }
            grouped[song.discNumber, default: []].append(song)
        }
        return order.map { DiscGroup(discNumber: $0, songs: grouped[$0] ?? []) }
    }

    /// only multi disc albums show disc headers in the track list
    var hasMultipleDiscs: Bool {
        discs.count > 1
    }
}

struct DiscGroup: Identifiable, Hashable, Sendable {
    let discNumber: Int
    let songs: [Song]

    var id: Int { discNumber }
}

enum AlbumSortOption: String, Identifiable, CaseIterable {
    case title
    case artist
    case year

    var id: String { rawValue }

    var label: String {
        switch self {
        case .title:
            return "Title"
        case .artist:
            return "Artist"
        case .year:
            return "Year"
        }
    }
}

struct AlbumSection: Identifiable {
    let title: String
    let albums: [Album]

    var id: String { title }
}

/// pure helpers for grouping the flat song list into albums and turning those
/// into the searchable, sorted, sectioned list shown in the albums view
enum AlbumListBuilder {
    /// groups songs into albums keyed by album artist & album name, with
    /// tracks in disc & track number order; songs without an album are left out
    static func albums(from songs: [Song]) -> [Album] {
        var order = [String]()
        var grouped = [String: [Song]]()
        for song in songs where !song.albumName.isEmpty {
            let key = "\(fold(albumArtist(for: song).name))\u{1F}\(fold(song.albumName))"
            if grouped[key] == nil {
                order.append(key)
            }
            grouped[key, default: []].append(song)
        }

        return order.compactMap { key in
            guard let songs = grouped[key] else { return nil }
            let tracks = songs.sorted {
                ($0.discNumber, $0.trackNumber, fold($0.name)) < ($1.discNumber, $1.trackNumber, fold($1.name))
            }
            let artist = albumArtist(for: tracks[0])
            return Album(
                id: key,
                name: tracks[0].albumName,
                sortName: tracks.first { !$0.albumSortName.isEmpty }?.albumSortName ?? "",
                artistName: artist.name,
                artistSortName: artist.sortName,
                genre: tracks.first { !$0.genre.isEmpty }?.genre ?? "",
                year: tracks.map(\.year).max() ?? 0,
                artworkFilename: tracks.compactMap(\.artworkFilename).first,
                songs: tracks)
        }
    }

    /// a pseudo-album collecting songs with no album name, shown at the end
    /// of the artist view; nil when every song has an album
    static func unknownAlbum(from songs: [Song]) -> Album? {
        let loose = songs.filter { $0.albumName.isEmpty }
        guard !loose.isEmpty else { return nil }
        let tracks = loose.sorted {
            ($0.discNumber, $0.trackNumber, fold($0.name)) < ($1.discNumber, $1.trackNumber, fold($1.name))
        }
        // the doubled separator can't collide with a real album's key
        return Album(
            id: "\(fold(tracks[0].artistName))\u{1F}\u{1F}",
            name: "Unknown Album",
            sortName: "",
            artistName: tracks[0].artistName,
            artistSortName: tracks.first { !$0.artistSortName.isEmpty }?.artistSortName ?? "",
            genre: tracks.first { !$0.genre.isEmpty }?.genre ?? "",
            year: 0,
            artworkFilename: tracks.compactMap(\.artworkFilename).first,
            songs: tracks)
    }

    /// the library album a song belongs to, if it has one
    static func album(for song: Song, in songs: [Song]) -> Album? {
        guard !song.albumName.isEmpty else { return nil }
        let key = "\(fold(albumArtist(for: song).name))\u{1F}\(fold(song.albumName))"
        let matching = songs.filter {
            !$0.albumName.isEmpty && "\(fold(albumArtist(for: $0).name))\u{1F}\(fold($0.albumName))" == key
        }
        return albums(from: matching).first
    }

    static func sections(_ albums: [Album], sortedBy sort: AlbumSortOption, matching search: String) -> [AlbumSection] {
        let query = search.trimmingCharacters(in: .whitespaces)
        var filtered = albums
        if !query.isEmpty {
            filtered = albums.filter {
                $0.name.localizedCaseInsensitiveContains(query)
                    || $0.artistName.localizedCaseInsensitiveContains(query)
            }
        }

        if sort == .year {
            return yearSections(filtered)
        }

        let keyed = filtered
            .map { (album: $0, key: sortKey(for: $0, sort: sort)) }
            .sorted { ($0.key.primary, $0.key.secondary) < ($1.key.primary, $1.key.secondary) }

        var albumsByTitle = [String: [Album]]()
        for entry in keyed {
            albumsByTitle[SongListBuilder.sectionTitle(for: entry.key.primary), default: []].append(entry.album)
        }

        var titles = albumsByTitle.keys.sorted()
        if let index = titles.firstIndex(of: "#") {
            titles.remove(at: index)
            titles.append("#")
        }
        return titles.map { AlbumSection(title: $0, albums: albumsByTitle[$0] ?? []) }
    }

    static func sortKey(for album: Album, sort: AlbumSortOption) -> (primary: String, secondary: String) {
        switch sort {
        case .title, .year:
            return (fold(album.titleSortKey), fold(album.artistSortKey))
        case .artist:
            return (fold(album.artistSortKey), fold(album.titleSortKey))
        }
    }

    /// the album artist when set, otherwise the track artist
    static func albumArtist(for song: Song) -> (name: String, sortName: String) {
        song.albumArtistName.isEmpty
            ? (song.artistName, song.artistSortName)
            : (song.albumArtistName, song.albumArtistSortName)
    }

    /// year sort groups albums under year headers, oldest first, with
    /// unknown years at the end
    private static func yearSections(_ albums: [Album]) -> [AlbumSection] {
        var albumsByYear = [Int: [Album]]()
        for album in albums {
            albumsByYear[album.year, default: []].append(album)
        }

        var years = albumsByYear.keys.sorted()
        if let index = years.firstIndex(of: 0) {
            years.remove(at: index)
            years.append(0)
        }
        return years.map { year in
            let sorted = (albumsByYear[year] ?? []).sorted {
                (fold($0.artistSortKey), fold($0.titleSortKey)) < (fold($1.artistSortKey), fold($1.titleSortKey))
            }
            return AlbumSection(title: year == 0 ? "Unknown Year" : String(year), albums: sorted)
        }
    }

    private static func fold(_ value: String) -> String {
        SongListBuilder.fold(value)
    }
}
