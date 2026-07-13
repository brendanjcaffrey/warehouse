import SwiftUI

/// picks which playlists the watch app syncs
struct WatchSettingsView: View {
    @Environment(PlaylistsStore.self) private var playlists
    @Environment(WatchSyncSettingsStore.self) private var settings

    var body: some View {
        List {
            let sections = PlaylistListBuilder.watchSections(in: playlists.playlists)
            if sections.isEmpty {
                Text("No playlists to choose from yet. Sync your library first.")
                    .foregroundStyle(.secondary)
            }
            ForEach(sections) { section in
                Section(section.title) {
                    ForEach(section.playlists) { playlist in
                        row(playlist)
                    }
                }
            }
        }
        .navigationTitle("Watch Playlists")
        .task {
            await playlists.load()
        }
    }

    private func row(_ playlist: PlaylistItem) -> some View {
        Button {
            settings.toggle(playlist.id)
        } label: {
            HStack {
                Text(playlist.name)
                    .foregroundStyle(.primary)
                Spacer()
                if settings.isSelected(playlist.id) {
                    Image(systemName: "checkmark")
                        .foregroundStyle(.tint)
                }
            }
        }
    }
}
