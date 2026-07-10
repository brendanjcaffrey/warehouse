import SwiftUI

struct LibraryView: View {
    @Environment(NavigationRouter.self) private var router

    var body: some View {
        @Bindable var router = router
        return NavigationStack(path: $router.libraryPath) {
            List {
                NavigationLink {
                    SongsView()
                } label: {
                    Label("Songs", systemImage: "music.note")
                }
                NavigationLink {
                    PlaylistsView()
                } label: {
                    Label("Playlists", systemImage: "music.note.list")
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
            .navigationTitle("Library")
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
