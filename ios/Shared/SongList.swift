import Foundation

struct Song: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let sortName: String
    let artistName: String
    let artistSortName: String
    let albumArtistName: String
    let albumArtistSortName: String
    let albumName: String
    let albumSortName: String
    let genre: String
    let year: Int
    let duration: TimeInterval
    let start: TimeInterval
    let finish: TimeInterval
    let discNumber: Int
    let trackNumber: Int
    var playCount = 0
    /// 0-100, 20 per star like itunes
    var rating = 0
    let musicFilename: String
    let artworkFilename: String?
    /// wall-clock instant the track entered the library; nil when the source had none
    var addedDate: Date?

    var titleSortKey: String { sortName.isEmpty ? name : sortName }
    var artistSortKey: String { artistSortName.isEmpty ? artistName : artistSortName }
}

enum SongSortOption: String, Identifiable {
    case playlistOrder
    case title
    case artist
    case dateAdded

    /// playlist order only makes sense inside a playlist
    static let libraryOptions: [SongSortOption] = [.title, .artist, .dateAdded]
    static let playlistOptions: [SongSortOption] = [.playlistOrder, .title, .artist, .dateAdded]

    var id: String { rawValue }

    var label: String {
        switch self {
        case .playlistOrder:
            return "Playlist Order"
        case .title:
            return "Title"
        case .artist:
            return "Artist"
        case .dateAdded:
            return "Date Added"
        }
    }

    /// sorts that show one flat list with no alphabetical section index
    var isFlat: Bool {
        self == .playlistOrder || self == .dateAdded
    }
}

struct SongSection: Identifiable, Equatable {
    let title: String
    let songs: [Song]

    var id: String { title }
}

/// pure helpers for turning a flat song list into the searchable, sorted,
/// letter-sectioned list shown in the songs view
enum SongListBuilder {
    static func sections(_ songs: [Song], sortedBy sort: SongSortOption, matching search: String) -> [SongSection] {
        let query = search.trimmingCharacters(in: .whitespaces)
        var filtered = songs
        if !query.isEmpty {
            filtered = songs.filter {
                $0.name.localizedCaseInsensitiveContains(query)
                    || $0.artistName.localizedCaseInsensitiveContains(query)
            }
        }

        if sort == .playlistOrder {
            // playlist order keeps the incoming order and skips letter sections
            return filtered.isEmpty ? [] : [SongSection(title: "", songs: filtered)]
        }

        if sort == .dateAdded {
            // newest-first, one flat section; a missing date sorts as oldest
            let sorted = filtered.sorted {
                ($0.addedDate ?? .distantPast) > ($1.addedDate ?? .distantPast)
            }
            return sorted.isEmpty ? [] : [SongSection(title: "", songs: sorted)]
        }

        let keyed = filtered
            .map { (song: $0, key: sortKey(for: $0, sort: sort)) }
            .sorted { ($0.key.primary, $0.key.secondary) < ($1.key.primary, $1.key.secondary) }

        var songsByTitle = [String: [Song]]()
        for entry in keyed {
            songsByTitle[sectionTitle(for: entry.key.primary), default: []].append(entry.song)
        }

        var titles = songsByTitle.keys.sorted()
        if let index = titles.firstIndex(of: "#") {
            titles.remove(at: index)
            titles.append("#")
        }
        return titles.map { SongSection(title: $0, songs: songsByTitle[$0] ?? []) }
    }

    /// filters a pre-ordered list by name or artist without resorting, so the
    /// watch songs list can filter songs that already arrive in display order
    static func filtered(_ songs: [Song], matching search: String) -> [Song] {
        let query = search.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return songs }
        return songs.filter {
            $0.name.localizedCaseInsensitiveContains(query)
                || $0.artistName.localizedCaseInsensitiveContains(query)
        }
    }

    /// the full unfiltered list in display order, so tapping a filtered result
    /// can play the whole list instead of just the visible matches
    static func orderedSongs(_ songs: [Song], trackIds: [String]?, sortedBy sort: SongSortOption) -> [Song] {
        var base = songs
        if let trackIds {
            base = playlistSongs(base, trackIds: trackIds)
        }
        return sections(base, sortedBy: sort, matching: "").flatMap(\.songs)
    }

    /// the section & row of a song within the built sections, for scrolling
    /// the list to it
    static func position(of song: Song, in sections: [SongSection]) -> (section: Int, row: Int)? {
        for (section, entry) in sections.enumerated() {
            if let row = entry.songs.firstIndex(of: song) {
                return (section, row)
            }
        }
        return nil
    }

    /// the playlist's songs in playlist order, skipping unknown track ids;
    /// a track can only appear once because duplicate ids would break list identity
    static func playlistSongs(_ songs: [Song], trackIds: [String]) -> [Song] {
        let byId = Dictionary(songs.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var seen = Set<String>()
        return trackIds.compactMap { id in
            guard seen.insert(id).inserted else { return nil }
            return byId[id]
        }
    }

    static func sortKey(for song: Song, sort: SongSortOption) -> (primary: String, secondary: String) {
        switch sort {
        // playlistOrder & dateAdded skip this path; fall back to the title key
        case .title, .playlistOrder, .dateAdded:
            return (fold(song.titleSortKey), fold(song.artistSortKey))
        case .artist:
            return (fold(song.artistSortKey), fold(song.titleSortKey))
        }
    }

    static func sectionTitle(for key: String) -> String {
        guard let first = key.unicodeScalars.first else { return "#" }
        let letter = Character(first)
        guard letter.isLetter, letter.isASCII else { return "#" }
        return String(letter).uppercased()
    }

    static func fold(_ value: String) -> String {
        value.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
    }
}
