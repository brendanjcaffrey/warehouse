import SwiftUI

@main
struct WarehouseWatchApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @State private var settings: WatchSettingsStore
    @State private var sync: SyncStore
    @State private var songs: SongsStore
    @State private var playlists: PlaylistsStore
    @State private var player: PlayerStore

    private let phone: WatchPhoneSession
    private let plays: PlayReportQueue
    private let artwork: WatchArtworkFetcher

    init() {
        let database = LibraryDatabase()
        let fileStore = FileStore(rootURL: FileStore.defaultRootURL())
        let settings = WatchSettingsStore()
        let songs = SongsStore(database: database, fileStore: fileStore)
        let phone = WatchPhoneSession(settings: settings)
        let credentials: @Sendable () -> (token: String, baseURL: URL)? = {
            guard let token = settings.token, let baseURL = settings.baseURL() else { return nil }
            return (token: token, baseURL: baseURL)
        }
        // what the watch keeps is a bounded cache, not a mirror: files arrive
        // on demand & the least recently used are evicted once over budget.
        // one instance shared by everything that touches those files, so the
        // in-use set the player writes is honoured by every eviction pass
        let fileCache = FileCache(fileStore: fileStore)
        // music & artwork aren't synced, so the player & the rows pull them as
        // they need them
        let artwork = WatchArtworkFetcher(fileCache: fileCache, credentials: credentials)
        // tracks arrive & are evicted as the user plays, so the download marks
        // on the rows follow the cache rather than the last sync
        fileCache.onMusicChanged = { songs.refreshDownloads() }
        // the library still syncs; the files it references do not
        let syncStore = SyncStore(
            database: database, fileStore: fileStore, transfersFiles: false)
        // the library is trimmed server-side to the playlists chosen on the phone
        syncStore.syncedPlaylistIds = { settings.playlistIds }
        _settings = State(initialValue: settings)
        _sync = State(initialValue: syncStore)
        _songs = State(initialValue: songs)
        _playlists = State(initialValue: PlaylistsStore(database: database))
        // finished plays queue here & ride the connectivity session back to
        // the phone, which pushes them to the server
        let plays = PlayReportQueue(
            canSend: { phone.canSend },
            outstandingIds: { phone.outstandingPlayIds },
            send: { phone.send($0) })
        phone.onActivated = { plays.drain() }
        _player = State(initialValue: PlayerStore(
            fileStore: fileStore,
            fileCache: fileCache,
            fetchArtwork: { await artwork.fetch($0, priority: .nowPlaying) },
            onTrackPlayed: { plays.add(trackId: $0) },
            // a track that isn't cached is played straight off the server.
            // the download it replaces ran in this process & died whenever
            // watchos stopped scheduling us, which is every wrist drop
            streams: true))
        self.phone = phone
        self.plays = plays
        self.artwork = artwork

        // activate in init rather than the scene: the phone's settings pushes
        // can launch the app in the background & the session delegate must be
        // in place before the scene builds
        phone.activate()

        // one pass at launch, off the critical path: it is what collects the
        // mirror sync's leftovers on an upgraded watch — the index has never
        // seen those files, so they sort ahead of anything played — and it is
        // the only pass a session that plays nothing but cached tracks and
        // browses nothing new ever gets. nothing is playing yet, so the empty
        // in-use set costs nothing here
        Task { @MainActor in fileCache.evict() }
    }

    var body: some Scene {
        WindowGroup {
            WatchRootView()
                .environment(settings)
                .environment(sync)
                .environment(songs)
                .environment(playlists)
                .environment(player)
                .environment(\.artworkFetcher, artwork)
                .onChange(of: scenePhase, initial: true) {
                    // prefetch only runs frontmost. out of sight the app is
                    // most likely on a wrist mid-workout, where a download
                    // would be competing with the stream that is actually
                    // making sound; coming back is the chance to fill the
                    // cache & cover the next dead zone
                    player.setForeground(scenePhase == .active)
                }
        }
    }
}
