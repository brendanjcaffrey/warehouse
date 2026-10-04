import SwiftUI

extension EnvironmentValues {
    @Entry var watchLibraryRefresh: @MainActor () async -> Void = {}
}

struct WatchRootView: View {
    @Environment(\.watchLibraryRefresh) private var refresh
    @Environment(WatchLibraryReceiver.self) private var receiver
    @Environment(WatchLibraryStore.self) private var library
    @Environment(WatchRemoteStore.self) private var remote
    @Environment(PlayerStore.self) private var player
    @State private var navigation = RemoteNavigation()

    private var startup: WatchLibraryStore.State {
        if receiver.protocolSelected, receiver.refreshFailed, library.state != .ready, library.state != .empty {
            return .failed("Library refresh failed. Check that the iPhone and watch apps are up to date.")
        }
        return library.presentation(isConfigured: receiver.head?.libraryID != nil)
    }

    var body: some View {
        NavigationStack {
            Group {
                if startup == .ready {
                    WatchMenuView(openRemote: { navigation.open() })
                } else {
                    ScrollView {
                        VStack(spacing: 12) {
                            startupContent
                                .fixedSize(horizontal: false, vertical: true)
                            NavigationLink {
                                WatchDiagnosticView()
                            } label: {
                                Label("Diagnostics", systemImage: "waveform.path.ecg")
                            }
                            if remote.isAvailable {
                                Button {
                                    navigation.open()
                                } label: {
                                    Label("Open iPhone Now Playing", systemImage: "iphone")
                                }
                            }
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
            }
            .navigationTitle("Warehouse")
            .navigationDestination(isPresented: $navigation.isPresented) {
                WatchRemoteNowPlayingView()
            }
            .onChange(of: remote.isAvailable, initial: true) { updateRemoteOpen() }
            .onChange(of: remote.isPhonePlaying) { updateRemoteOpen() }
        }
    }

    private func updateRemoteOpen() {
        navigation.update(
            isRemoteAvailable: remote.isAvailable,
            isRemotePlaying: remote.isPhonePlaying,
            isPlayingLocally: player.isPlaying)
    }

    @ViewBuilder
    private var startupContent: some View {
        switch startup {
        case .setup:
            WatchWaitingView()
        case .loading:
            ProgressView("Loading saved library…")
        case .needsSync:
            Text("Waiting for library from iPhone…")
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
            WatchMenuView(openRemote: { navigation.open() })
        }
    }

    private var refreshButton: some View {
        Button("Try Again") {
            Task { await refresh() }
        }
    }
}
