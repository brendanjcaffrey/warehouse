import SwiftUI

extension View {
    /// hold on a track: play it now or next plus shortcuts to its artist,
    /// album & playlist views
    func songContextMenu(
        _ song: Song,
        library: [Song],
        playlists: [PlaylistItem] = [],
        play: @escaping () -> Void,
        playNext: @escaping () -> Void,
        artistDestination: Binding<Artist?>,
        albumDestination: Binding<Album?>? = nil,
        playlistDestination: Binding<PlaylistDestination?>? = nil
    ) -> some View {
        contextMenu {
            Button("Play", systemImage: "play", action: play)
            Button("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward", action: playNext)
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
            if let playlistDestination {
                let containing = PlaylistListBuilder.containing(trackId: song.id, in: playlists)
                if !containing.isEmpty {
                    Menu {
                        ForEach(containing) { playlist in
                            Button(playlist.name) {
                                playlistDestination.wrappedValue = PlaylistDestination(playlist: playlist, song: song)
                            }
                        }
                    } label: {
                        Label("Show in Playlist", systemImage: "music.note.list")
                    }
                }
            }
        }
    }

    /// hold on an album: play or shuffle it plus a shortcut to its artist view
    func albumContextMenu(
        _ album: Album,
        library: [Song],
        play: @escaping () -> Void,
        shuffle: @escaping () -> Void,
        artistDestination: Binding<Artist?>
    ) -> some View {
        contextMenu {
            Button("Play", systemImage: "play", action: play)
            Button("Shuffle", systemImage: "shuffle", action: shuffle)
            if !album.artistName.isEmpty {
                Button("Go to Artist", systemImage: "music.microphone") {
                    artistDestination.wrappedValue = ArtistListBuilder.artist(for: album, in: library)
                }
            }
        }
    }

    /// hold on an artist, playlist or an album already inside its artist view:
    /// play or shuffle it
    func playbackContextMenu(
        play: @escaping () -> Void,
        shuffle: @escaping () -> Void
    ) -> some View {
        contextMenu {
            Button("Play", systemImage: "play", action: play)
            Button("Shuffle", systemImage: "shuffle", action: shuffle)
        }
    }
}
