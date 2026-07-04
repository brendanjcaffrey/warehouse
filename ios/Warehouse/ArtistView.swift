import SwiftUI

struct ArtistView: View {
    @Environment(AuthStore.self) private var auth
    @Environment(SongsStore.self) private var store
    @Environment(PlayerStore.self) private var player

    let artist: Artist

    private var artistSongs: [Song] {
        artist.albums.flatMap(\.songs)
    }

    var body: some View {
        List {
            Section {
                HStack(spacing: 12) {
                    playbackButton("Play", systemImage: "play.fill") {
                        player.play(artistSongs, token: auth.token, baseURL: auth.baseURL())
                    }
                    playbackButton("Shuffle", systemImage: "shuffle") {
                        player.playShuffled(artistSongs, token: auth.token, baseURL: auth.baseURL())
                    }
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
                    // no go to artist since we're already on it
                    .playbackContextMenu(
                        play: { player.play(album.songs, token: auth.token, baseURL: auth.baseURL()) },
                        shuffle: { player.playShuffled(album.songs, token: auth.token, baseURL: auth.baseURL()) })
                }
            }
        }
        .listStyle(.plain)
        .navigationTitle(artist.name)
        .navigationBarTitleDisplayMode(.inline)
    }

    private func playbackButton(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
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
