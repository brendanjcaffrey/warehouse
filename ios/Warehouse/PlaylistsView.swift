import SwiftUI

struct PlaylistsView: View {
    @Environment(AuthStore.self) private var auth
    @Environment(PlaylistsStore.self) private var store
    @Environment(SongsStore.self) private var songs
    @Environment(SyncStore.self) private var sync
    @Environment(PlayerStore.self) private var player

    /// nil shows the top level, a folder shows its children
    let folder: PlaylistItem?

    init(folder: PlaylistItem? = nil) {
        self.folder = folder
    }

    private var rows: [PlaylistItem] {
        PlaylistListBuilder.children(of: folder?.id ?? "", in: store.playlists)
    }

    var body: some View {
        Group {
            if rows.isEmpty {
                ContentUnavailableView(
                    "No Playlists",
                    systemImage: "music.note.list",
                    description: Text(folder == nil
                        ? "Sync your library from the Settings tab."
                        : "This folder is empty."))
            } else {
                List(rows) { playlist in
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
        }
        .navigationTitle(folder?.name ?? "Playlists")
        .task {
            await store.load()
            // playing a playlist from the context menu needs the songs too
            await songs.load()
        }
        .onChange(of: sync.completedSyncs) {
            // pick up new playlists once a sync finishes
            Task { await store.load() }
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
