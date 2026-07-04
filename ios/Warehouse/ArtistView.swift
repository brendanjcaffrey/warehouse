import SwiftUI

struct ArtistView: View {
    @Environment(SongsStore.self) private var store

    let artist: Artist

    var body: some View {
        List {
            Section {
                HStack(spacing: 12) {
                    playbackButton("Play", systemImage: "play.fill")
                    playbackButton("Shuffle", systemImage: "shuffle")
                }
            }
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
            Section {
                ForEach(artist.albums) { album in
                    NavigationLink {
                        AlbumView(album: album)
                    } label: {
                        ArtistAlbumRow(
                            album: album,
                            artworkURL: store.artworkURL(filename: album.artworkFilename))
                    }
                }
            }
        }
        .listStyle(.plain)
        .navigationTitle(artist.name)
        .navigationBarTitleDisplayMode(.inline)
    }

    private func playbackButton(_ title: String, systemImage: String) -> some View {
        Button {
            // playback isn't implemented yet
        } label: {
            Label(title, systemImage: systemImage)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
    }
}

struct ArtistAlbumRow: View {
    let album: Album
    let artworkURL: URL?

    var body: some View {
        HStack(spacing: 12) {
            ArtworkThumbnail(url: artworkURL)
                .frame(width: 44, height: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text(album.name)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if album.year > 0 {
                    Text(String(album.year))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}
