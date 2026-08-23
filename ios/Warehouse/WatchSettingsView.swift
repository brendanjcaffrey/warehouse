import SwiftUI

/// picks which playlists the watch's library is trimmed to, and the url it
/// reaches the server on
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
                Text("Server URL")
            } footer: {
                Text("Where the watch reaches the server, for its library and "
                    + "for tracks as they play. The watch can't join the tailnet, "
                    + "so this needs to be a public URL — the Tailscale Funnel URL, "
                    + "on the default HTTPS port 443 (no port suffix), not nginx's "
                    + "internal 20601. Left blank, the watch uses the phone's server "
                    + "URL, which only works if that's reachable off the tailnet.")
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
        .navigationTitle("Apple Watch")
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
