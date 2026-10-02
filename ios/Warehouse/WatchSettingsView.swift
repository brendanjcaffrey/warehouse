import SwiftUI

extension EnvironmentValues {
    @Entry var phoneDiagnosticReporter: (@MainActor () -> WatchDiagnosticReport)?
}

/// the phone owns selection; download counts come from durable watch receipts.
struct WatchSettingsView: View {
    @Environment(PlaylistsStore.self) private var playlists
    @Environment(WatchSyncSettingsStore.self) private var settings
    @Environment(\.phoneDiagnosticReporter) private var phoneReport
    @Environment(WatchDiagnosticInbox.self) private var diagnosticInbox

    var body: some View {
        List {
            Section("Downloads on Apple Watch") {
                WatchLibraryProgressView(progress: settings.progress())
                Text("Counts show the last download status reported by the watch. Updates may be delayed while disconnected.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Section("Diagnostics") {
                Button("Save iPhone Capture") {
                    if let report = phoneReport?() { diagnosticInbox.savePhone(report) }
                }
                if diagnosticInbox.reports.isEmpty {
                    Text("Send a capture from Diagnostics on the watch, then return here to share it.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(diagnosticInbox.reports, id: \.self) { url in
                        ShareLink(item: url) {
                            Label(url.deletingPathExtension().lastPathComponent, systemImage: "square.and.arrow.up")
                        }
                    }
                }
            }
            let sections = PlaylistListBuilder.watchSections(in: playlists.playlists)
            if sections.isEmpty {
                Text("No playlists to choose from yet. Sync your library first.")
                    .foregroundStyle(.secondary)
            }
            Text("Selecting a playlist automatically copies and keeps its music and artwork on the watch. "
                + "Deselecting removes files no other selected playlist needs.")
                .font(.footnote)
                .foregroundStyle(.secondary)
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
            diagnosticInbox.refresh()
        }
    }

    private func row(_ playlist: PlaylistItem) -> some View {
        Button {
            settings.toggle(playlist.id)
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(playlist.name)
                        .foregroundStyle(.primary)
                    if settings.isSelected(playlist.id) {
                        WatchLibraryProgressView(progress: settings.progress(playlistID: playlist.id), compact: true)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if settings.isSelected(playlist.id) {
                    Image(systemName: "checkmark")
                        .foregroundStyle(.tint)
                }
            }
        }
        .accessibilityIdentifier("watch-playlist-\(playlist.id)")
        .accessibilityValue(settings.isSelected(playlist.id) ? "Selected" : "Not selected")
    }
}
