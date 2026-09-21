import SwiftUI

struct WatchOfflineView: View {
    @Environment(OfflineLibrary.self) private var offline
    @Environment(PlaylistsStore.self) private var playlists

    private var available: [PlaylistItem] {
        playlists.playlists.filter { !$0.isFolder && !$0.isLibrary }
    }

    var body: some View {
        List {
            Text("Choose playlists to keep on this watch. Keep this app open while preparing; reopening resumes downloads.")
                .font(.footnote)
            ForEach(available) { playlist in
                NavigationLink {
                    WatchOfflinePlaylistView(playlist: playlist)
                } label: {
                    VStack(alignment: .leading) {
                        Text(playlist.name)
                        if offline.isSelected(playlist.id) {
                            Text(offline.progress(playlist.id).label)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            ForEach(offline.selectedPlaylistIds.filter { id in !available.contains { $0.id == id } }, id: \.self) { id in
                Section(offline.name(id)) {
                    Text(offline.progress(id).label)
                    Text("No longer in your phone's library selection.")
                    Button("Remove Downloads", role: .destructive) { offline.remove(id) }
                }
            }
            if let error = offline.errorMessage { Text(error) }
        }
        .navigationTitle("Offline Playlists")
    }
}

struct WatchOfflinePlaylistView: View {
    @Environment(OfflineLibrary.self) private var offline
    @Environment(SongsStore.self) private var songs
    let playlist: PlaylistItem

    var body: some View {
        List {
            if offline.isSelected(playlist.id) {
                let progress = offline.progress(playlist.id)
                Text(progress.label)
                ProgressView(value: Double(progress.completed), total: Double(max(1, progress.total)))
                if progress.state != .ready {
                    if progress.state == .paused || progress.state == .failed || progress.state == .storageFull {
                        Button("Resume Preparation") { offline.resume(playlist.id) }
                    } else {
                        Button("Pause Preparation") { offline.pause(playlist.id) }
                    }
                    Button("Cancel Preparation") { offline.cancel(playlist.id) }
                }
                Button("Remove Downloads", role: .destructive) { offline.remove(playlist.id) }
            } else {
                Button("Prepare for Offline") { offline.prepare(playlist, songs: songs.songs) }
                    .disabled(playlist.trackIds.isEmpty)
            }
            Text("Keep the watch app open until Ready. Selected downloads are kept until you remove them. Playback is not required.")
                .font(.footnote)
            if let error = offline.errorMessage { Text(error) }
        }
        .navigationTitle(playlist.name)
    }
}

private extension OfflineLibrary.Progress {
    var label: String {
        let status: String
        switch state {
        case .notSelected: status = "Not selected"
        case .queued: status = "Waiting to download"
        case .waitingForPhone: status = "Waiting for iPhone"
        case .downloading: status = "Downloading"
        case .paused: status = "Paused"
        case .failed: status = "Incomplete — retry preparation or sync"
        case .storageFull: status = "Storage full — remove downloads"
        case .ready: status = "Ready"
        }
        return "\(completed)/\(total) tracks · \(status)"
    }
}
