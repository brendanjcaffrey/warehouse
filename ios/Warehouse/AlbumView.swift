import SwiftUI

struct AlbumView: View {
    @Environment(AuthStore.self) private var auth
    @Environment(SongsStore.self) private var store
    @Environment(SyncStore.self) private var sync
    @Environment(PlayerStore.self) private var player

    let album: Album

    @State private var artistDestination: Artist?

    var body: some View {
        List {
            Section {
                header
                HStack(spacing: 12) {
                    playbackButton("Play", systemImage: "play.fill")
                    playbackButton("Shuffle", systemImage: "shuffle")
                }
            }
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
            Section {
                ForEach(album.songs) { song in
                    Button {
                        player.play(song, token: auth.token, baseURL: auth.baseURL())
                    } label: {
                        HStack {
                            Text(song.name)
                                .lineLimit(1)
                                .truncationMode(.tail)
                            Spacer(minLength: 8)
                            if store.isDownloaded(song) {
                                Image(systemName: "arrow.down.circle")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        // taps anywhere on the row should register, not just on its content
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    // no go to album since we're already on it
                    .songContextMenu(
                        song,
                        library: store.songs,
                        play: { player.play(song, token: auth.token, baseURL: auth.baseURL()) },
                        artistDestination: $artistDestination)
                }
            }
        }
        .listStyle(.plain)
        .navigationTitle(album.name)
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(item: $artistDestination) { artist in
            ArtistView(artist: artist)
        }
        .onChange(of: sync.completedSyncs) {
            // pick up newly downloaded files once a sync finishes
            Task { await store.load() }
        }
        .onChange(of: sync.downloadRefreshTicks) {
            // refresh the downloaded icons periodically during long downloads
            Task { await store.load() }
        }
    }

    private var header: some View {
        VStack(spacing: 4) {
            ArtworkThumbnail(
                url: store.artworkURL(filename: album.artworkFilename),
                maxPixelSize: 660)
                .frame(width: 220, height: 220)
            Text(album.artistName)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .padding(.top, 12)
            Text(album.name)
                .font(.title2)
                .fontWeight(.bold)
                .multilineTextAlignment(.center)
            if !detailLine.isEmpty {
                Text(detailLine)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
    }

    private var detailLine: String {
        var parts = [String]()
        if !album.genre.isEmpty {
            parts.append(album.genre)
        }
        if album.year > 0 {
            parts.append(String(album.year))
        }
        return parts.joined(separator: " · ")
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
