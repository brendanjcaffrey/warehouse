import SwiftUI

/// picks which playlists the watch app syncs and optionally where it syncs from
struct WatchSettingsView: View {
    @Environment(PlaylistsStore.self) private var playlists
    @Environment(WatchSyncSettingsStore.self) private var settings

    var body: some View {
        List {
            Section {
                TextField("Same as phone", text: overrideBinding)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            } header: {
                Text("Sync URL")
            } footer: {
                Text("Where the watch downloads music from, if it can't reach "
                    + "the phone's server URL — e.g. a Tailscale Funnel URL. "
                    + "Use the public Funnel port 443 (the https default, so no "
                    + "port suffix), not nginx's internal 20601 port.")
            }
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

    private var overrideBinding: Binding<String> {
        Binding(
            get: { settings.serverURLOverride },
            set: { settings.setServerURLOverride($0) })
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
