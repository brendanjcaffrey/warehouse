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
        let phone = WatchPhoneSession(settings: settings)
        // files arrive from the server as tar bundles on a background url
        // session, so the chain keeps advancing while the app is suspended
        let downloader = WatchBundleDownloader.shared
        downloader.configure(activity: activity) {
            guard let token = settings.token, let baseURL = settings.baseURL() else { return nil }
            return (token: token, baseURL: baseURL)
        }
        let syncStore = SyncStore(
            database: database, fileStore: fileStore, fileDownloader: downloader)
        // the library is trimmed server-side to the playlists chosen on the phone
        syncStore.syncedPlaylistIds = { settings.playlistIds }
        syncStore.onLibraryReceived = { activity.receivedLibrary() }
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

        // activate in init rather than the scene: the phone's settings pushes
        // can launch the app in the background & the delegate must be in place
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
