import SwiftUI

struct LibraryView: View {
    var body: some View {
        NavigationStack {
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
        }
    }
}
