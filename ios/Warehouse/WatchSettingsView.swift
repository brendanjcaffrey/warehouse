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
    @State private var deletionFailed = false

    var body: some View {
        List {
            Section("Downloads on Apple Watch") {
                WatchLibraryProgressView(progress: settings.progress())
                Text("Counts show the last download status reported by the watch. Updates may be delayed while disconnected.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
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
            Section("Diagnostics") {
                Button("Save iPhone Capture") {
                    if let report = phoneReport?() { diagnosticInbox.savePhone(report) }
                }
                if diagnosticInbox.reports.isEmpty {
                    Text("Send a capture from Diagnostics on the watch, then return here to share it.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(diagnosticInbox.reports, id: \.self) { url in
                        diagnosticRow(url)
                    }
                }
            }
        }
        .navigationTitle("Apple Watch")
        .alert("Couldn’t Delete Capture", isPresented: $deletionFailed) {
            Button("OK", role: .cancel) { }
        } message: {
            Text("The saved capture could not be removed. Try again.")
        }
        .task {
            await playlists.load()
            diagnosticInbox.refresh()
        }
    }

    private func diagnosticRow(_ url: URL) -> some View {
        ShareLink(item: url) {
            Label {
                VStack(alignment: .leading, spacing: 4) {
                    Text(url.deletingPathExtension().lastPathComponent)
                    Text(diagnosticInbox.capturedAt(for: url)?.formatted(date: .abbreviated, time: .shortened)
                         ?? "Creation date unavailable")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("watch-diagnostic-date-\(url.lastPathComponent)")
                }
            } icon: {
                Image(systemName: "square.and.arrow.up")
            }
        }
        .accessibilityIdentifier("watch-diagnostic-report-\(url.lastPathComponent)")
        .swipeActions {
            Button(role: .destructive) {
                do {
                    try diagnosticInbox.delete(url)
                } catch {
                    deletionFailed = true
                }
            } label: {
                Label("Delete", systemImage: "trash")
            }
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
