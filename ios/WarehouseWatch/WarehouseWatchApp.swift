import SwiftUI

@main
struct WarehouseWatchApp: App {
    @WKApplicationDelegateAdaptor(WatchAppDelegate.self) private var appDelegate

    @State private var settings: WatchSettingsStore
    @State private var sync: SyncStore
    @State private var songs: SongsStore
    @State private var playlists: PlaylistsStore
    @State private var player: PlayerStore
    @State private var activity: SyncActivityLog

    private let phone: WatchPhoneSession
    private let plays: PlayReportQueue

    init() {
        let database = LibraryDatabase()
        let fileStore = FileStore(rootURL: FileStore.defaultRootURL())
        let settings = WatchSettingsStore()
        // built before the log so arrivals can be named as tracks, and owned
        // for the life of the app so the feed outlives any one sync
        let songs = SongsStore(database: database, fileStore: fileStore)
        let activity = SyncActivityLog(describe: { songs.describe($0) })
        let phone = WatchPhoneSession(settings: settings, fileStore: fileStore, activity: activity)
        phone.onReachabilityChange = { activity.phoneReachabilityChanged(to: $0) }
        // the library & every file arrive from the phone over watch
        // connectivity, so the watch never has to reach the server
        let downloader = PhoneRelayDownloader(
            phone: phone, database: database, fileStore: fileStore, activity: activity)
        let syncStore = SyncStore(
            database: database, fileStore: fileStore,
            fileDownloader: downloader,
            libraryProvider: RelayLibraryProvider(
                isReachable: { WatchPhoneSession.isPhoneReachable },
                sendWithReply: { try await phone.sendWithReply($0) },
                awaitLibrary: { try await phone.awaitLibrary(timeout: $0) }))
        _settings = State(initialValue: settings)
        _sync = State(initialValue: syncStore)
        _songs = State(initialValue: songs)
        _playlists = State(initialValue: PlaylistsStore(database: database))
        _activity = State(initialValue: activity)
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
                .environment(activity)
        }
    }
}
