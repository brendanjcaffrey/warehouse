import SwiftUI

/// the play, play next, edit & go to buttons shared by the long press track
/// menu and the now playing view's tap menu; play & play next are left out
/// when their closures are nil, as on the now playing view where the track is
/// already playing, & edit is left out when the server isn't tracking changes
@ViewBuilder
func songMenuButtons(
    _ song: Song,
    library: [Song],
    playlists: [PlaylistItem] = [],
    play: (() -> Void)? = nil,
    playNext: (() -> Void)? = nil,
    edit: (() -> Void)? = nil,
    artistDestination: Binding<Artist?>,
    albumDestination: Binding<Album?>? = nil,
    songsDestination: Binding<Song?>? = nil,
    playlistDestination: Binding<PlaylistDestination?>? = nil
) -> some View {
    if let play {
        Button("Play", systemImage: "play", action: play)
    }
    if let playNext {
        Button("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward", action: playNext)
    }
    if let edit {
        Button("Edit", systemImage: "pencil", action: edit)
    }
    if let songsDestination {
        Button("Go to Song", systemImage: "music.note") {
            songsDestination.wrappedValue = song
        }
    }
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

extension View {
    /// hold on a track: play it now or next plus shortcuts to its artist,
    /// album, songs & playlist views
    func songContextMenu(
        _ song: Song,
        library: [Song],
        playlists: [PlaylistItem] = [],
        play: @escaping () -> Void,
        playNext: @escaping () -> Void,
        edit: (() -> Void)? = nil,
        artistDestination: Binding<Artist?>,
        albumDestination: Binding<Album?>? = nil,
        songsDestination: Binding<Song?>? = nil,
        playlistDestination: Binding<PlaylistDestination?>? = nil
    ) -> some View {
        contextMenu {
            songMenuButtons(
                song,
                library: library,
                playlists: playlists,
                play: play,
                playNext: playNext,
                edit: edit,
                artistDestination: artistDestination,
                albumDestination: albumDestination,
                songsDestination: songsDestination,
                playlistDestination: playlistDestination)
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
