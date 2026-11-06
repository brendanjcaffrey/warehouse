import SwiftUI

enum TrackTextField: String {
    case lyrics = "Lyrics"
    case comments = "Comments"

    func text(in song: Song) -> String {
        self == .lyrics ? song.lyrics : song.comments
    }
}

/// playback selects live lyrics; a menu captures the track independently of playback.
enum TrackTextSelection: Identifiable {
    case nowPlayingLyrics
    case track(Song, TrackTextField)

    struct TrackIdentity: Hashable {
        let libraryID: String?
        let trackID: String
    }

    var id: String {
        switch self {
        case .nowPlayingLyrics: "nowPlayingLyrics"
        case let .track(song, field): "\(song.libraryID ?? "")/\(song.id)/\(field.rawValue)"
        }
    }

    var field: TrackTextField {
        switch self {
        case .nowPlayingLyrics: .lyrics
        case let .track(_, field): field
        }
    }

    func song(current: Song?, library: [Song]) -> Song? {
        let selected: Song?
        switch self {
        case .nowPlayingLyrics: selected = current
        case let .track(song, _): selected = song
        }
        guard let selected else { return nil }
        return library.first { $0.id == selected.id && $0.libraryID == selected.libraryID } ?? selected
    }

    func scrollID(for song: Song) -> TrackIdentity {
        TrackIdentity(libraryID: song.libraryID, trackID: song.id)
    }
}

/// shared saved-text reader; its editor captures a value before playback can advance.
struct TrackTextReader: View {
    @Environment(PlayerStore.self) private var player
    @Environment(SongsStore.self) private var songs
    @Environment(UpdatesStore.self) private var updates
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var editingSong: Song?

    let selection: TrackTextSelection

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let song = selection.song(current: player.song, library: songs.songs) {
                header(song)
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        if selection.field.text(in: song).isEmpty {
                            Text("No \(selection.field.rawValue.lowercased()) for this track.")
                                .foregroundStyle(.secondary)
                                .accessibilityIdentifier("readerEmpty")
                        } else {
                            Text(selection.field.text(in: song))
                                .textSelection(.enabled)
                                .accessibilityIdentifier("readerText")
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.bottom)
                }
                .accessibilityIdentifier("trackTextScroll")
                // replacing the scroll view resets its actual offset only when the track changes.
                .id(selection.scrollID(for: song))
            } else {
                ContentUnavailableView("No Track Playing", systemImage: "music.note")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .sheet(item: $editingSong) { song in
            EditTrackView(song: song)
        }
    }

    @ViewBuilder
    private func header(_ song: Song) -> some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 8) {
                trackInfo(song)
                editButton(song)
            }
        } else {
            HStack(alignment: .top) {
                trackInfo(song)
                Spacer(minLength: 8)
                editButton(song)
            }
        }
    }

    private func trackInfo(_ song: Song) -> some View {
        VStack(alignment: .leading) {
            Text(song.name)
                .font(.headline)
                .lineLimit(2)
                .accessibilityIdentifier("readerTrackTitle")
            Text(song.artistName)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private func editButton(_ song: Song) -> some View {
        if updates.canEditTracks {
            Button("Edit") { editingSong = song }
                .accessibilityIdentifier("readerEdit")
        }
    }

}

struct TrackTextSheet: View {
    @Environment(\.dismiss) private var dismiss
    let selection: TrackTextSelection

    var body: some View {
        NavigationStack {
            TrackTextReader(selection: selection)
                .padding()
                .navigationTitle(selection.field.rawValue)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                    }
                }
        }
    }
}
