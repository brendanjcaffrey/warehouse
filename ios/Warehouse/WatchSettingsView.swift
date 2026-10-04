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
    @State private var showingPlaylistSelection = false

    var body: some View {
        List {
            Section("Downloads on Apple Watch") {
                WatchLibraryProgressView(progress: settings.progress())
                Text("Counts show the last download status reported by the watch. Updates may be delayed while disconnected.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Section {
                Button("Selected Playlists") {
                    showingPlaylistSelection = true
                }
                .accessibilityIdentifier("watch-selected-playlists")
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
        .sheet(isPresented: $showingPlaylistSelection) {
            WatchPlaylistSelectionView(playlistIds: settings.playlistIds)
        }
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

}

private struct WatchPlaylistSelectionView: View {
    @Environment(PlaylistsStore.self) private var playlists
    @Environment(WatchSyncSettingsStore.self) private var settings
    @Environment(\.dismiss) private var dismiss
    @State private var selectedIds: Set<String>
    @State private var confirmingChanges = false

    init(playlistIds: [String]) {
        _selectedIds = State(initialValue: Set(playlistIds))
    }

    var body: some View {
        NavigationStack {
            List {
                let sections = PlaylistListBuilder.watchSections(in: playlists.playlists)
                if sections.isEmpty {
                    Text("No playlists to choose from yet. Sync your library first.")
                        .foregroundStyle(.secondary)
                }
                Text("Selecting a playlist automatically copies and keeps its music and artwork on the watch. "
                    + "Changes apply only after you save and confirm.")
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
            .navigationTitle("Selected Playlists")
            .onChange(of: settings.playlistIds) { old, new in
                selectedIds.subtract(Set(old).subtracting(new))
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { confirmingChanges = true }
                        .disabled(selectedIds == Set(settings.playlistIds))
                }
            }
            .alert("Apply Playlist Changes?", isPresented: $confirmingChanges) {
                Button("Cancel", role: .cancel) { }
                Button("Apply Changes") {
                    settings.setPlaylistIds(selectedIds.sorted())
                    dismiss()
                }
            } message: {
                Text("Selected playlists will be copied to the watch. Music and artwork from deselected playlists "
                    + "will be removed unless another selected playlist needs them.")
            }
        }
    }

    private func row(_ playlist: PlaylistItem) -> some View {
        Button {
            if selectedIds.contains(playlist.id) {
                selectedIds.remove(playlist.id)
            } else {
                selectedIds.insert(playlist.id)
            }
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
                if selectedIds.contains(playlist.id) {
                    Image(systemName: "checkmark")
                        .foregroundStyle(.tint)
                }
            }
        }
        .accessibilityIdentifier("watch-playlist-\(playlist.id)")
        .accessibilityValue(selectedIds.contains(playlist.id) ? "Selected" : "Not selected")
    }
}
