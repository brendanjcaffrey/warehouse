import SwiftUI

struct LibraryView: View {
    @Environment(NavigationRouter.self) private var router
    @Environment(PlaylistsStore.self) private var playlists
    @Environment(SongsStore.self) private var songs
    @Environment(SyncStore.self) private var sync

    private var topLevelPlaylists: [PlaylistItem] {
        PlaylistListBuilder.children(of: "", in: playlists.playlists)
    }

    var body: some View {
        @Bindable var router = router
        return NavigationStack(path: $router.libraryPath) {
            List {
                Section {
                    NavigationLink {
                        SongsView()
                    } label: {
                        Label("Songs", systemImage: "music.note")
                    }
                    NavigationLink {
                        ArtistsView()
                    } label: {
                        Label("Artists", systemImage: "music.microphone")
                    }
                    NavigationLink {
                        AlbumsView()
                    } label: {
                        Label("Albums", systemImage: "square.stack")
                    }
                }
                if !topLevelPlaylists.isEmpty {
                    Section("Playlists") {
                        PlaylistRows(playlists: topLevelPlaylists)
                    }
                }
            }
            .navigationTitle("Library")
            .task {
                await playlists.load()
                // playing a playlist from the context menu needs the songs too
                await songs.load()
            }
            .onChange(of: sync.completedSyncs) {
                // pick up new playlists once a sync finishes
                Task { await playlists.load() }
            }
            // destinations the now playing modal pushes onto this stack
            .navigationDestination(for: LibraryRoute.self) { route in
                switch route {
                case .artist(let artist):
                    ArtistView(artist: artist)
                case .album(let album):
                    AlbumView(album: album)
                case .songs(let song):
                    SongsView(scrollTo: song)
                case .playlist(let destination):
                    SongsView(playlist: destination.playlist, scrollTo: destination.song)
                }
            }
        }
    }
}
