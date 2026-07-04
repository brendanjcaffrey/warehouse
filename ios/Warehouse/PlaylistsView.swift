import SwiftUI

struct PlaylistsView: View {
    @Environment(PlaylistsStore.self) private var store
    @Environment(SyncStore.self) private var sync

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
        }
        .navigationTitle(folder?.name ?? "Playlists")
        .task {
            await store.load()
        }
        .onChange(of: sync.completedSyncs) {
            // pick up new playlists once a sync finishes
            Task { await store.load() }
        }
    }
}
