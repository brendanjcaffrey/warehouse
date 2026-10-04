import AppIntents
import CoreSpotlight
import SwiftUI
import WatchConnectivity

@main
struct WarehouseApp: App {
    @Environment(\.scenePhase) private var scenePhase

    @State private var auth: AuthStore
    @State private var sync: SyncStore
    @State private var songs: SongsStore
    @State private var playlists: PlaylistsStore
    @State private var updates: UpdatesStore
    @State private var player: PlayerStore
    @State private var router: NavigationRouter
    @State private var watchSettings: WatchSyncSettingsStore
    @State private var diagnosticInbox: WatchDiagnosticInbox
    @State private var seeded = false
    @State private var restoredPlayback = false

    private let database: LibraryDatabase
    private let playbackState = PlaybackStateStore()
    private let intents: IntentPlaybackService
    private let watchSession: PhoneWatchSession

    init() {
        let database = LibraryDatabase(inMemory: UITestSupport.enabled)
        self.database = database
        let fileStore = FileStore(rootURL: FileStore.defaultRootURL())
        let authStore = AuthStore()
        let updatesStore = UpdatesStore(fileStore: fileStore)
        updatesStore.configure(token: authStore.token, baseURL: authStore.baseURL())
        let syncStore = SyncStore(database: database, fileStore: fileStore)
        // artwork queued for upload must survive sync's file cleanup
        syncStore.protectedArtworkFilenames = { updatesStore.pendingArtworkFilenames }
        let songsStore = SongsStore(database: database, fileStore: fileStore)
        let playlistsStore = PlaylistsStore(database: database)
        let playerStore = PlayerStore(fileStore: fileStore, onTrackPlayed: { play in
            Task { await updatesStore.addPlay(trackId: play.trackId, libraryID: play.libraryID) }
        })
        let routerStore = NavigationRouter()
        _auth = State(initialValue: authStore)
        _sync = State(initialValue: syncStore)
        _songs = State(initialValue: songsStore)
        _playlists = State(initialValue: playlistsStore)
        _updates = State(initialValue: updatesStore)
        _player = State(initialValue: playerStore)
        _router = State(initialValue: routerStore)

        let watchSettings = WatchSyncSettingsStore()
        let diagnosticInbox = WatchDiagnosticInbox()
        let watchSession = PhoneWatchSession(
            onPlay: { play in
                try updatesStore.recordWatchPlay(play)
                Task { await updatesStore.flush() }
            },
            // the watch app opened while the phone is playing acts as a
            // remote for it rather than starting a second stream
            nowPlaying: { RemotePlaybackPayload(player: playerStore) },
            onCommand: { playerStore.apply($0) },
            diagnosticInbox: diagnosticInbox)
        let content = try? PhoneWatchContentQueue(fileStore: fileStore, transport: .init(
            available: { WCSession.isSupported() && WCSession.default.activationState == .activated && WCSession.default.isWatchAppInstalled },
            outstanding: {
                WCSession.default.outstandingFileTransfers.compactMap {
                    guard $0.file.metadata?["kind"] as? String == "watchContentFile" else { return nil }
                    return $0.file.metadata.flatMap(WatchContentFile.init(dictionary:))
                }
            }, enqueue: { file, url in
                if let metadata = try? file.encode() { WCSession.default.transferFile(url, metadata: metadata) }
            }, cancel: { id in
                for transfer in WCSession.default.outstandingFileTransfers
                    where transfer.file.metadata.flatMap(WatchContentFile.init(dictionary:))?.id == id { transfer.cancel() }
            }, query: { file in
                guard let info = try? file.encode(kind: "watchContentQuery") else { return }
                let alreadyQueued = WCSession.default.outstandingUserInfoTransfers.contains {
                    $0.userInfo["kind"] as? String == "watchContentQuery" && WatchContentFile(dictionary: $0.userInfo) == file
                }
                if !alreadyQueued { WCSession.default.transferUserInfo(info) }
            }, report: { report in
                guard WCSession.isSupported(), WCSession.default.activationState == .activated,
                      let info = try? report.encode() else { return }
                let outstanding = WCSession.default.outstandingUserInfoTransfers.filter {
                    $0.userInfo["kind"] as? String == "watchLibraryDeliveryReport"
                }
                if outstanding.contains(where: { WatchLibraryDeliveryReport(dictionary: $0.userInfo) == report }) { return }
                outstanding.forEach { $0.cancel() }
                WCSession.default.transferUserInfo(info)
            }, inventory: { request in
                guard let info = try? request.encode() else { return }
                let outstanding = WCSession.default.outstandingUserInfoTransfers.filter {
                    $0.userInfo["kind"] as? String == "watchInventoryRequest"
                }
                if outstanding.contains(where: { WatchInventoryRequest(dictionary: $0.userInfo) == request }) { return }
                outstanding.forEach { $0.cancel() }
                WCSession.default.transferUserInfo(info)
            }))
        watchSession.content = content
        watchSettings.content = content
        let publisher = try? PhoneWatchLibraryPublisher(database: database, transport: .init(
            context: { head in
                guard WCSession.isSupported(), WCSession.default.activationState == .activated else {
                    throw WatchLibraryError.notLoaded
                }
                try WCSession.default.updateApplicationContext(try head.encode())
            }, outstanding: {
                Set(WCSession.default.outstandingFileTransfers.compactMap { $0.file.metadata?["watchLibraryKey"] as? String })
            }, enqueue: { url, key in
                WCSession.default.transferFile(url, metadata: ["kind": "watchLibrarySnapshot", "watchLibraryKey": key])
            }))
        publisher?.onSnapshot = { head, snapshot in content?.update(head: head, snapshot: snapshot) }
        publisher?.onSelectionReconciled = { watchSettings.reconcilePlaylistIds($0) }
        watchSession.publishLibrary = {
            try? content?.invalidate(identity: LibraryIdentity.make(token: authStore.token, baseURL: authStore.baseURL()),
                                     playlistIDs: watchSettings.playlistIds)
            publisher?.publish(identity: LibraryIdentity.make(token: authStore.token, baseURL: authStore.baseURL()),
                               playlistIDs: watchSettings.playlistIds)
        }
        syncStore.onLibrarySaved = {
            watchSession.publishLibrary?()
            Task { await updatesStore.flush() }
        }
        songsStore.onLibraryChanged = { watchSession.publishLibrary?() }
        watchSettings.onChange = { watchSession.push() }
        _watchSettings = State(initialValue: watchSettings)
        _diagnosticInbox = State(initialValue: diagnosticInbox)
        self.watchSession = watchSession
        // activate here rather than in the scene: watch connectivity launches
        // the app in the background to deliver queued plays, & the delegate
        // must be in place for that
        watchSession.activate()

        // intents run outside the swiftui environment; they resolve the live
        // stores through the app intents dependency manager instead
        let intents = IntentPlaybackService(
            auth: authStore, songs: songsStore, playlists: playlistsStore, player: playerStore)
        self.intents = intents
        AppDependencyManager.shared.add(dependency: playerStore)
        AppDependencyManager.shared.add(dependency: routerStore)
        AppDependencyManager.shared.add(dependency: intents)
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if UITestSupport.enabled && !seeded {
                    // hold the real ui until the fixture library is loaded
                    ProgressView()
                        .task {
                            await UITestSupport.seed(database)
                            seeded = true
                        }
                } else {
                    RootView()
                }
            }
                .environment(auth)
                .environment(sync)
                .environment(songs)
                .environment(playlists)
                .environment(updates)
                .environment(player)
                .environment(router)
                .environment(watchSettings)
                .environment(diagnosticInbox)
                .environment(\.phoneDiagnosticReporter, {
                    let device = UIDevice.current
                    return watchSession.diagnosticReport(deviceModel: device.model, systemVersion: device.systemVersion)
                })
                .onChange(of: auth.token) {
                    updates.configure(token: auth.token, baseURL: auth.baseURL())
                    // publish account changes while ordinary token refresh preserves library identity
                    watchSession.push()
                    // & the restored queue's, which was put back holding
                    // whatever token was around before the refresh
                    player.setCredentials(token: auth.token, baseURL: auth.baseURL())
                }
                .onChange(of: auth.serverURL) {
                    updates.configure(token: auth.token, baseURL: auth.baseURL())
                    watchSession.push()
                }
                .onChange(of: player.song?.id) {
                    watchSession.pushNowPlaying()
                    savePlayback()
                }
                .onChange(of: player.isPlaying) {
                    watchSession.pushNowPlaying()
                    savePlayback()
                }
                .onChange(of: player.isActuallyPlaying) {
                    watchSession.pushNowPlaying()
                }
                .onChange(of: player.queue.isShuffled) {
                    watchSession.pushNowPlaying()
                    savePlayback()
                }
                .onChange(of: player.repeatMode) {
                    watchSession.pushNowPlaying()
                    savePlayback()
                }
                .onChange(of: scenePhase) {
                    // push any stuck updates when coming back to the foreground
                    if scenePhase == .active {
                        Task { await updates.flush() }
                        watchSession.push()
                    } else {
                        // the last chance to write the playhead down: from here
                        // the app is suspended & may never run again
                        savePlayback()
                    }
                }
                .onChange(of: sync.completedSyncs) {
                    // refresh siri's entity vocabulary & the spotlight index
                    // after each library sync
                    WarehouseShortcuts.updateAppShortcutParameters()
                    let intents = intents
                    Task { await intents.refreshSpotlight() }
                }
                .task {
                    WarehouseShortcuts.updateAppShortcutParameters()
                    await intents.refreshSpotlight()
                }
                .task {
                    await restorePlayback()
                }
                .onContinueUserActivity(CSSearchableItemActionType) { activity in
                    // a library item tapped in spotlight
                    guard let id = activity.userInfo?[CSSearchableItemActivityIdentifier] as? String else {
                        return
                    }
                    let intents = intents
                    let router = router
                    Task { @MainActor in
                        try? await intents.prepare()
                        let route = SpotlightIndexer.route(
                            for: id, songs: intents.allSongs, playlists: intents.allPlaylists)
                        if let route {
                            router.navigate(to: route)
                        }
                    }
                }
        }
    }

    /// puts the last session's now playing queue back, once, at launch. the
    /// os throws the app away as soon as it stops making sound, so this is
    /// what the user sees after leaving it alone for a while
    @MainActor
    private func restorePlayback() async {
        guard !restoredPlayback, !UITestSupport.enabled else { return }
        restoredPlayback = true
        guard let snapshot = playbackState.load(),
              let songs = try? await database.songs(ids: snapshot.queue.songIDs)
        else {
            return
        }
        player.restore(
            snapshot, songs: songs, token: auth.token, baseURL: auth.baseURL())
    }

    @MainActor
    private func savePlayback() {
        guard !UITestSupport.enabled else { return }
        playbackState.save(player.snapshot)
    }
}
