import SwiftUI
import WatchKit

struct WatchMenuView: View {
    @Environment(WatchSettingsStore.self) private var settings
    @Environment(SyncStore.self) private var sync
    @Environment(SongsStore.self) private var songs
    @Environment(PlaylistsStore.self) private var playlists
    @Environment(PlayerStore.self) private var player

    @State private var isSyncing = false
    @State private var syncOutcome: SyncOutcome?

    private enum SyncOutcome: Equatable {
        case upToDate
        case failed(String)
    }

    var body: some View {
        NavigationStack {
            List {
                if player.song != nil {
                    NavigationLink {
                        WatchNowPlayingView()
                    } label: {
                        Label("Now Playing", systemImage: "play.circle")
                    }
                }
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
            case .failed(let message):
                Label(message, systemImage: "exclamationmark.triangle.fill")
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
            let outcome = outcome(for: sync.state)
            syncOutcome = outcome
            WKInterfaceDevice.current().play(outcome == .upToDate ? .success : .failure)
            // hold the confirmation briefly so a no-op or instant sync is visible
            try? await Task.sleep(for: .seconds(2))
            syncOutcome = nil
        }
    }

    private func outcome(for state: SyncStore.State) -> SyncOutcome {
        switch state {
        case .error:
            return .failed("Sync failed")
        case .storageFull:
            return .failed("Storage full")
        case .upToDate(let failedDownloads) where failedDownloads > 0:
            return .failed("\(failedDownloads) failed")
        default:
            return .upToDate
        }
    }
}
