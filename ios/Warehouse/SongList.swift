import Foundation

struct Song: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let sortName: String
    let artistName: String
    let artistSortName: String
    let musicFilename: String
    let artworkFilename: String?

    var titleSortKey: String { sortName.isEmpty ? name : sortName }
    var artistSortKey: String { artistSortName.isEmpty ? artistName : artistSortName }
}

enum SongSortOption: String, CaseIterable, Identifiable {
    case title
    case artist

    var id: String { rawValue }

    var label: String {
        switch self {
        case .title:
            return "Title"
        case .artist:
            return "Artist"
        }
    }
}

struct SongSection: Identifiable {
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

    static func sortKey(for song: Song, sort: SongSortOption) -> (primary: String, secondary: String) {
        switch sort {
        case .title:
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

    private static func fold(_ value: String) -> String {
        value.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
    }
}
