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
        // downloads run on a background url session so they keep going while
        // the watch app is suspended
        let syncStore = SyncStore(
            database: database, fileStore: fileStore,
            fileDownloader: WatchBackgroundDownloader.shared)
        // only the selected playlists & their tracks are kept and downloaded
        syncStore.libraryFilter = { LibraryFilter.filter($0, playlistIds: Set(settings.playlistIds)) }
        _settings = State(initialValue: settings)
        _sync = State(initialValue: syncStore)
        _songs = State(initialValue: SongsStore(database: database, fileStore: fileStore))
        _playlists = State(initialValue: PlaylistsStore(database: database))
        let phone = WatchPhoneSession(settings: settings)
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
    }

    var body: some Scene {
        WindowGroup {
            WatchRootView()
                .environment(settings)
                .environment(sync)
                .environment(songs)
                .environment(playlists)
                .environment(player)
                .task {
                    phone.activate()
                }
        }
    }
}
