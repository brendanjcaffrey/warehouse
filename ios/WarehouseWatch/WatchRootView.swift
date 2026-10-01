import SwiftUI

struct WatchRootView: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(WatchSettingsStore.self) private var settings
    @Environment(SyncStore.self) private var sync
    @Environment(WatchLibraryReceiver.self) private var receiver
    @Environment(WatchLibraryStore.self) private var library
    @Environment(OfflineLibrary.self) private var offline
    @Environment(SongsStore.self) private var songs
    @Environment(PlaylistsStore.self) private var playlists
    @Environment(WatchRemoteStore.self) private var remote

    private var startup: WatchLibraryStore.State {
        if receiver.protocolSelected, receiver.refreshFailed, library.state != .ready, library.state != .empty {
            return .failed("Library refresh failed. Check that the iPhone and watch apps are up to date.")
        }
        return library.presentation(isConfigured: receiver.head?.libraryID != nil || settings.isConfigured)
    }

    var body: some View {
        Group {
            if startup == .ready {
                WatchMenuView()
            } else if remote.isPhonePlaying {
                // nothing of our own to browse yet, but the phone is playing:
                // the remote is the whole app in that case, so skip the
                // waiting screens rather than hiding the one useful thing
                NavigationStack {
                    WatchRemoteNowPlayingView()
                }
            } else {
                NavigationStack {
                    VStack {
                        startupContent
                        NavigationLink {
                            WatchDiagnosticView()
                        } label: {
                            Label("Diagnostics", systemImage: "waveform.path.ecg")
                        }
                        if remote.isAvailable {
                            NavigationLink {
                                WatchRemoteNowPlayingView()
                            } label: {
                                Label("Open iPhone Now Playing", systemImage: "iphone")
                            }
                        }
                    }
                }
            }
        }
        .task(id: settings.configurationChanges) {
            await receiver.waitForImport()
            requestSync()
            // load saved data for browsing while the latest sync runs
            await loadLibrary()
        }
        .onChange(of: sync.completedSyncs) {
            Task { await loadLibrary() }
        }
        .onChange(of: scenePhase) {
            // a sync that died offline is otherwise only retried when asked.
            // coming back to the front is the moment the wrist is likely in
            // range again, & it's the only signal the watch gets
            guard scenePhase == .active, sync.state == .offline else { return }
            requestSync()
        }
    }

    private func loadLibrary() async {
        await library.load()
        guard songs.errorMessage == nil, playlists.errorMessage == nil else { return }
        offline.reconcile(playlists: playlists.playlists, songs: songs.songs)
    }

    private func requestSync() {
        guard receiver.allowsLegacySync else { return }
        sync.requestWatchSync(
            token: settings.token, baseURL: settings.baseURL(),
            playlistIds: settings.playlistIds, generation: settings.configurationChanges)
    }

    @ViewBuilder
    private var startupContent: some View {
        switch startup {
        case .setup:
            WatchWaitingView()
        case .loading:
            ProgressView("Loading saved library…")
        case .needsSync:
            if receiver.protocolSelected {
                Text(!receiver.refreshFailed ? "Waiting for library from iPhone…" : "Library refresh failed. Waiting for iPhone…")
            } else {
                WatchSyncProgressView()
            }
        case .empty:
            ContentUnavailableView {
                Label("No Songs", systemImage: "music.note")
            } description: {
                Text("Choose playlists in the iPhone app's Apple Watch settings. Selected playlists may also contain no songs.")
            }
        case .failed(let message):
            ContentUnavailableView {
                Label("Can't Load Library", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            } actions: {
                refreshButton
            }
        case .ready:
            WatchMenuView()
        }
    }

    private var refreshButton: some View {
        Button("Try Again") {
            Task {
                await loadLibrary()
                requestSync()
            }
        }
        .disabled(sync.isBusy)
    }
}
