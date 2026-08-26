import SwiftUI
import WatchKit

struct WatchMenuView: View {
    @Environment(WatchSettingsStore.self) private var settings
    @Environment(SyncStore.self) private var sync
    @Environment(SongsStore.self) private var songs
    @Environment(PlaylistsStore.self) private var playlists
    @Environment(PlayerStore.self) private var player
    @Environment(WatchRemoteStore.self) private var remote

    @State private var isSyncing = false
    @State private var syncOutcome: SyncOutcome?
    @State private var showingRemote = false
    @State private var autoOpen = RemoteAutoOpen()

    private enum SyncOutcome: Equatable {
        case upToDate
        case offline
        case failed(String)
    }

    var body: some View {
        NavigationStack {
            List {
                if remote.isAvailable {
                    Button {
                        autoOpen.noteOpened()
                        showingRemote = true
                    } label: {
                        Label("Playing on iPhone", systemImage: "iphone")
                    }
                }
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
            .navigationDestination(isPresented: $showingRemote) {
                WatchRemoteNowPlayingView()
            }
            .onChange(of: remote.isAvailable, initial: true) {
                // opening the app while the phone is playing means the remote
                // is what was wanted; browsing our own library is a step back
                // away. only the once, though — backing out has to hold
                guard autoOpen.shouldOpen(
                    isRemoteAvailable: remote.isAvailable, isPlayingLocally: player.isPlaying)
                else { return }
                showingRemote = true
            }
        }
    }

    @ViewBuilder
    private var syncLabel: some View {
        if isSyncing {
            Label {
                Text("Checking…")
            } icon: {
                ProgressView()
            }
        } else if let syncOutcome {
            switch syncOutcome {
            case .upToDate:
                Label("Up to date", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            case .offline:
                Label("Offline", systemImage: "wifi.slash")
                    .foregroundStyle(.orange)
            case .failed(let message):
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
            }
        } else {
            Label("Check for Updates", systemImage: "arrow.trianglehead.2.clockwise")
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

    /// the watch only ever fetches library data, so the file-transfer states
    /// can't happen here
    private func outcome(for state: SyncStore.State) -> SyncOutcome {
        switch state {
        case .error:
            return .failed("Check failed")
        case .offline:
            // nothing was checked, so don't claim the library is current
            return .offline
        default:
            return .upToDate
        }
    }
}
