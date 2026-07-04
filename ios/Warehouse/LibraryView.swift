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
                disabledRow("Artists", systemImage: "music.microphone")
                disabledRow("Albums", systemImage: "square.stack")
            }
            .navigationTitle("Library")
        }
    }

    private func disabledRow(_ title: String, systemImage: String) -> some View {
        // these will become navigation links as the corresponding views are built
        Label(title, systemImage: systemImage)
            .foregroundStyle(.tertiary)
    }
}
