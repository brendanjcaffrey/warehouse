import SwiftUI

/// picks which playlists the watch's library is trimmed to, the url it
/// reaches the server on, & how far ahead of the playhead it fills its cache
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
            Section {
                Picker("Tracks ahead", selection: depthBinding) {
                    ForEach(depthOptions, id: \.self) { depth in
                        Text(Self.depthLabel(depth)).tag(depth)
                    }
                }
            } header: {
                Text("Fill Ahead")
            } footer: {
                Text("How far past the track playing the watch keeps downloading "
                    + "while its app is on screen — the only time it isn't "
                    + "throttled. Put a playlist on, leave the app up, and walk "
                    + "out of signal with it on disk. It stops when the watch's "
                    + "cache is full, and it costs battery and storage, so it's "
                    + "off unless you ask for it.")
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

    private var depthBinding: Binding<Int> {
        Binding(
            get: { settings.deepPrefetchDepth },
            set: { settings.setDeepPrefetchDepth($0) })
    }

    /// the depths on offer, coarser as they go: past a couple of hundred
    /// tracks the difference between one and the next is more disk than any
    /// watch has, so the cache budget is what stops the fill rather than this
    private static let depths = [0, 10, 25, 50, 100, 250, 1000, WatchSyncSettingsStore.maxDeepPrefetchDepth]

    private var depthOptions: [Int] {
        // a depth stored by an older build needn't be one of these, & a picker
        // with nothing selected reads as broken
        Set(Self.depths + [settings.deepPrefetchDepth]).sorted()
    }

    private static func depthLabel(_ depth: Int) -> String {
        depth == 0 ? "Off" : "\(depth.formatted()) tracks"
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
