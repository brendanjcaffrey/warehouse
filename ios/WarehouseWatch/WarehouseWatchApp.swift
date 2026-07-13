import SwiftUI

@main
struct WarehouseWatchApp: App {
    @WKApplicationDelegateAdaptor(WatchAppDelegate.self) private var appDelegate

    @State private var settings: WatchSettingsStore
    @State private var sync: SyncStore
    @State private var songs: SongsStore
    @State private var playlists: PlaylistsStore
    @State private var player: PlayerStore

    private let phone: WatchPhoneSession
    private let plays: PlayReportQueue

    init() {
        let database = LibraryDatabase()
        let fileStore = FileStore(rootURL: FileStore.defaultRootURL())
        let settings = WatchSettingsStore()
        let phone = WatchPhoneSession(settings: settings, fileStore: fileStore)
        // the library & every file arrive from the phone over watch
        // connectivity, so the watch never has to reach the server
        let downloader = PhoneRelayDownloader(phone: phone, database: database, fileStore: fileStore)
        let syncStore = SyncStore(
            database: database, fileStore: fileStore,
            fileDownloader: downloader,
            libraryProvider: RelayLibraryProvider(
                isReachable: { WatchPhoneSession.isPhoneReachable },
                sendWithReply: { try await phone.sendWithReply($0) },
                awaitLibrary: { try await phone.awaitLibrary(timeout: $0) }))
        // only the selected playlists & their tracks are kept and downloaded
        syncStore.libraryFilter = { LibraryFilter.filter($0, playlistIds: Set(settings.playlistIds)) }
        _settings = State(initialValue: settings)
        _sync = State(initialValue: syncStore)
        _songs = State(initialValue: SongsStore(database: database, fileStore: fileStore))
        _playlists = State(initialValue: PlaylistsStore(database: database))
        // finished plays queue here & ride the connectivity session back to
        // the phone, which pushes them to the server
        let plays = PlayReportQueue(
            canSend: { phone.canSend },
            outstandingIds: { phone.outstandingPlayIds },
            send: { phone.send($0) })
        phone.onActivated = { plays.drain() }
        _player = State(initialValue: PlayerStore(
            fileStore: fileStore, onTrackPlayed: { plays.add(trackId: $0) }))
        self.phone = phone
        self.plays = plays

        WatchAppDelegate.onConnectivityTask = { phone.handleBackgroundTask($0) }
        WatchAppDelegate.onAppRefresh = { completion in
            Task { @MainActor in
                await downloader.keepDownloadsMoving()
                completion()
            }
        }
        // activate in init rather than the scene: incoming transfers launch
        // the app in the background & the delegate must be in place for that
        phone.activate()
    }

    var body: some Scene {
        WindowGroup {
            WatchRootView()
                .environment(settings)
                .environment(sync)
                .environment(songs)
                .environment(playlists)
                .environment(player)
        }
    }
}
