import SwiftUI

@main
struct WarehouseWatchApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @State private var settings: WatchSettingsStore
    @State private var sync: SyncStore
    @State private var songs: SongsStore
    @State private var playlists: PlaylistsStore
    @State private var library: WatchLibraryStore
    @State private var player: PlayerStore
    @State private var offline: OfflineLibrary
    @State private var remote: WatchRemoteStore

    private let phone: WatchPhoneSession
    private let plays: PlayReportQueue
    private let artwork: WatchArtworkFetcher

    init() {
        let database = LibraryDatabase()
        let fileStore = FileStore(rootURL: FileStore.defaultRootURL())
        let settings = WatchSettingsStore()
        let songs = SongsStore(database: database, fileStore: fileStore)
        let playlists = PlaylistsStore(database: database)
        let phone = WatchPhoneSession(settings: settings)
        let credentials: @Sendable () -> (token: String, baseURL: URL)? = {
            guard let token = settings.token, let baseURL = settings.baseURL() else { return nil }
            return (token: token, baseURL: baseURL)
        }
        // selected offline music is retained; the rest is a bounded cache.
        // every eviction sees both offline selections and the player's in-use files.
        let fileCache = FileCache(fileStore: fileStore)
        // music & artwork aren't synced, so the player & the rows pull them as
        // they need them
        let files = WatchFileDownloader(
            fileStore: fileStore,
            transport: .init(
                isReachable: { phone.canSend && phone.isReachable }, currentToken: { settings.token },
                currentGeneration: { settings.fileGeneration },
                request: { phone.requestFile($0, token: $1, reply: $2) }, cancel: { phone.cancelFile($0) },
                fileSize: { await phone.fileSize($0, filename: $1, token: $2) }),
            fileCache: fileCache)
        phone.files = files
        let artwork = WatchArtworkFetcher(fileCache: fileCache, downloader: files, credentials: credentials)
        let offline = OfflineLibrary(fileCache: fileCache, downloader: files, prepareMusic: { files.setDesiredMusic($0) })
        files.onStored = { type in
            guard type == .music else { return }
            fileCache.evict()
            fileCache.noteMusicStored()
        }
        _offline = State(initialValue: offline)
        // the library still syncs; the files it references do not
        let syncStore = SyncStore(
            database: database, fileStore: fileStore, transfersFiles: false)
        // the library is trimmed server-side to the playlists chosen on the phone
        syncStore.syncedPlaylistIds = { settings.playlistIds }
        _settings = State(initialValue: settings)
        _sync = State(initialValue: syncStore)
        _songs = State(initialValue: songs)
        _playlists = State(initialValue: playlists)
        _library = State(initialValue: WatchLibraryStore(songs: songs, playlists: playlists))
        // finished plays queue here & ride the connectivity session back to
        // the phone, which pushes them to the server
        let plays = PlayReportQueue(
            canSend: { phone.canSend },
            outstandingIds: { phone.outstandingPlayIds },
            send: { phone.send($0) })
        phone.onActivated = { plays.drain() }
        // what the phone is playing, when it is: the app is a remote for it
        // rather than a second player fighting it for the headphones
        let remote = WatchRemoteStore(send: { phone.send($0) })
        phone.remote = remote
        _remote = State(initialValue: remote)
        let player = PlayerStore(
            fileStore: fileStore,
            fileCache: fileCache,
            prefetchDownloader: files,
            fetchArtwork: { await artwork.fetch($0, priority: .nowPlaying) },
            onTrackPlayed: { plays.add(trackId: $0) },
            // a track that isn't cached is played straight off the server.
            // the download it replaces ran in this process & died whenever
            // watchos stopped scheduling us, which is every wrist drop
            streams: true)
        player.onPrefetchDemand = { offline.setPlaybackDemand($0) }
        fileCache.onMusicChanged = { [weak offline, weak player] in
            songs.refreshDownloads()
            offline?.refreshFiles()
            player?.downloadsChanged()
        }
        _player = State(initialValue: player)
        self.phone = phone
        self.plays = plays
        self.artwork = artwork

        // activate in init rather than the scene: the phone's settings pushes
        // can launch the app in the background & the session delegate must be
        // in place before the scene builds
        phone.activate()

        // restore offline retention before collecting opportunistic cache leftovers.
        Task { @MainActor in fileCache.evict() }
    }

    var body: some Scene {
        WindowGroup {
            WatchRootView()
                .environment(settings)
                .environment(sync)
                .environment(songs)
                .environment(playlists)
                .environment(library)
                .environment(player)
                .environment(remote)
                .environment(offline)
                .environment(\.artworkFetcher, artwork)
                .environment(\.diagnosticSender, phone)
                .onChange(of: settings.configurationChanges, initial: true) {
                    offline.setCredentials(token: settings.token, baseURL: settings.baseURL())
                    player.setCredentials(token: settings.token, baseURL: settings.baseURL())
                    if !settings.isConfigured {
                        player.pause()
                    }
                }
                .onChange(of: settings.deepPrefetchDepth, initial: true) {
                    // how far the prefetch reaches is the phone's call: it is
                    // this watch's disk & this watch's battery being spent
                    player.deepPrefetchDepth = settings.deepPrefetchDepth
                    player.prefetchNext()
                }
                .onChange(of: scenePhase, initial: true) {
                    // prefetch only runs frontmost. out of sight the app is
                    // most likely on a wrist mid-workout, where a download
                    // would be competing with the stream that is actually
                    // making sound; coming back is the chance to fill the
                    // cache & cover the next dead zone
                    player.setForeground(scenePhase == .active)
                    offline.setForeground(scenePhase == .active)
                    // pushes only reach a watch that was listening at the
                    // time, so coming to the front is when to ask
                    if scenePhase == .active {
                        remote.requestState()
                    }
                }
        }
    }
}
