import SwiftUI

extension View {
    /// hold on a track: play it now plus shortcuts to its artist & album views
    func songContextMenu(
        _ song: Song,
        library: [Song],
        play: @escaping () -> Void,
        artistDestination: Binding<Artist?>,
        albumDestination: Binding<Album?>? = nil
    ) -> some View {
        contextMenu {
            Button("Play", systemImage: "play", action: play)
            Button("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward") {}
                .disabled(true)
            if !song.artistName.isEmpty {
                Button("Go to Artist", systemImage: "music.microphone") {
                    artistDestination.wrappedValue = ArtistListBuilder.artist(named: song.artistName, in: library)
                }
            }
            if let albumDestination, !song.albumName.isEmpty {
                Button("Go to Album", systemImage: "square.stack") {
                    albumDestination.wrappedValue = AlbumListBuilder.album(for: song, in: library)
                }
            }
        }
    }

    /// hold on an album: playback stubs plus a shortcut to its artist view
    func albumContextMenu(
        _ album: Album,
        library: [Song],
        artistDestination: Binding<Artist?>
    ) -> some View {
        contextMenu {
            Button("Play", systemImage: "play") {}
                .disabled(true)
            Button("Shuffle", systemImage: "shuffle") {}
                .disabled(true)
            if !album.artistName.isEmpty {
                Button("Go to Artist", systemImage: "music.microphone") {
                    artistDestination.wrappedValue = ArtistListBuilder.artist(for: album, in: library)
                }
            }
        }
    }

    /// hold on an artist, playlist or an album already inside its artist view:
    /// playback stubs only
    func playbackContextMenu() -> some View {
        contextMenu {
            Button("Play", systemImage: "play") {}
                .disabled(true)
            Button("Shuffle", systemImage: "shuffle") {}
                .disabled(true)
        }
    }
}
