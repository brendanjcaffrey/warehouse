import SwiftUI

struct WatchTrackListView: View {
    let title: String
    let songs: [Song]

    var body: some View {
        List {
            Section {
                HStack {
                    // playback comes in a later step
                    actionButton("Play", systemImage: "play.fill")
                    actionButton("Shuffle", systemImage: "shuffle")
                }
                .listRowBackground(Color.clear)
            }
            ForEach(songs) { song in
                WatchSongRow(song: song)
            }
        }
        .navigationTitle(title)
    }

    private func actionButton(_ title: String, systemImage: String) -> some View {
        Button {
        } label: {
            Label(title, systemImage: systemImage)
                .labelStyle(.iconOnly)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .disabled(true)
    }
}

struct WatchSongRow: View {
    @Environment(SongsStore.self) private var songs

    let song: Song

    var body: some View {
        HStack(spacing: 8) {
            WatchArtworkThumbnail(url: songs.artworkURL(song))
                .frame(width: 28, height: 28)
            VStack(alignment: .leading) {
                Text(song.name)
                    .lineLimit(1)
                Text(song.artistName)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }
}
