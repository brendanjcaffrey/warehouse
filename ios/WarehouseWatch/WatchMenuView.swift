import SwiftUI
import WatchKit

struct WatchMenuView: View {
    @Environment(WatchSettingsStore.self) private var settings
    @Environment(SyncStore.self) private var sync
    @Environment(SongsStore.self) private var songs
    @Environment(PlaylistsStore.self) private var playlists

    @State private var isSyncing = false
    @State private var syncOutcome: SyncOutcome?

    private enum SyncOutcome {
        case upToDate
        case failed
    }

    var body: some View {
        NavigationStack {
            List {
                NavigationLink {
                    WatchTrackListView(
                        title: "Songs",
                        songs: SongListBuilder.orderedSongs(songs.songs, trackIds: nil, sortedBy: .title))
                } label: {
                    Label("Songs", systemImage: "music.note")
                }
                ForEach(PlaylistListBuilder.children(of: "", in: playlists.playlists)) { playlist in
                    NavigationLink {
                        WatchTrackListView(
                            title: playlist.name,
                            songs: SongListBuilder.playlistSongs(songs.songs, trackIds: playlist.trackIds))
                    } label: {
                        Label(playlist.name, systemImage: "music.note.list")
                    }
                }
                Button(action: runSync) {
                    syncLabel
                }
                .disabled(isSyncing)
            }
            .navigationTitle("Warehouse")
        }
    }

    @ViewBuilder
    private var syncLabel: some View {
        if isSyncing {
            Label {
                Text("Syncing…")
            } icon: {
                ProgressView()
            }
        } else if let syncOutcome {
            switch syncOutcome {
            case .upToDate:
                Label("Up to date", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            case .failed:
                Label("Sync failed", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
            }
        } else {
            Label("Sync", systemImage: "arrow.trianglehead.2.clockwise")
        }
    }

    private func runSync() {
        guard !isSyncing else { return }
        Task {
            isSyncing = true
            syncOutcome = nil
            await sync.sync(token: settings.token, baseURL: settings.baseURL())
            isSyncing = false
            if case .error = sync.state {
                syncOutcome = .failed
                WKInterfaceDevice.current().play(.failure)
            } else {
                syncOutcome = .upToDate
                WKInterfaceDevice.current().play(.success)
            }
            // hold the confirmation briefly so a no-op or instant sync is visible
            try? await Task.sleep(for: .seconds(2))
            syncOutcome = nil
        }
    }
}
