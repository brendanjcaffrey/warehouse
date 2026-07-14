import SwiftUI

/// rows for a folder's children, shared by the library list & folder views
struct PlaylistRows: View {
    @Environment(AuthStore.self) private var auth
    @Environment(SongsStore.self) private var songs
    @Environment(PlayerStore.self) private var player

    let playlists: [PlaylistItem]

    var body: some View {
        ForEach(playlists) { playlist in
            if playlist.isFolder {
                playlistLink(playlist)
            } else {
                playlistLink(playlist)
                    .playbackContextMenu(
                        play: { play(playlist, shuffled: false) },
                        shuffle: { play(playlist, shuffled: true) })
            }
        }
    }

    /// plays a playlist's songs in playlist order, or shuffled
    private func play(_ playlist: PlaylistItem, shuffled: Bool) {
        let tracks = SongListBuilder.playlistSongs(songs.songs, trackIds: playlist.trackIds)
        if shuffled {
            player.playShuffled(tracks, token: auth.token, baseURL: auth.baseURL())
        } else {
            player.play(tracks, token: auth.token, baseURL: auth.baseURL())
        }
    }

    private func playlistLink(_ playlist: PlaylistItem) -> some View {
        NavigationLink {
            if playlist.isFolder {
                PlaylistsView(folder: playlist)
            } else {
                SongsView(playlist: playlist)
            }
        } label: {
            Label(playlist.name, systemImage: playlist.isFolder ? "folder" : "music.note.list")
        }
    }
}

/// a playlist folder's children; the top level lives in the library list
struct PlaylistsView: View {
    @Environment(PlaylistsStore.self) private var store
    @Environment(SongsStore.self) private var songs

    let folder: PlaylistItem

    private var rows: [PlaylistItem] {
        PlaylistListBuilder.children(of: folder.id, in: store.playlists)
    }

    var body: some View {
        Group {
            if rows.isEmpty {
                ContentUnavailableView(
                    "No Playlists",
                    systemImage: "music.note.list",
                    description: Text("This folder is empty."))
            } else {
                List {
                    PlaylistRows(playlists: rows)
                }
            }
        }
        .navigationTitle(folder.name)
        .task {
            // playing a playlist from the context menu needs the songs
            await songs.load()
        }
    }
}
