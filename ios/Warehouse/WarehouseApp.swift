import AppIntents
import CoreSpotlight
import SwiftUI

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
    @State private var seeded = false

    private let database: LibraryDatabase
    private let intents: IntentPlaybackService

    init() {
        let database = LibraryDatabase(inMemory: UITestSupport.enabled)
        self.database = database
        let fileStore = FileStore(rootURL: FileStore.defaultRootURL())
        let authStore = AuthStore()
        let updatesStore = UpdatesStore(fileStore: fileStore)
        let syncStore = SyncStore(database: database, fileStore: fileStore)
        // artwork queued for upload must survive sync's file cleanup
        syncStore.protectedArtworkFilenames = { updatesStore.pendingArtworkFilenames }
        let songsStore = SongsStore(database: database, fileStore: fileStore)
        let playlistsStore = PlaylistsStore(database: database)
        let playerStore = PlayerStore(fileStore: fileStore, updates: updatesStore)
        let routerStore = NavigationRouter()
        _auth = State(initialValue: authStore)
        _sync = State(initialValue: syncStore)
        _songs = State(initialValue: songsStore)
        _playlists = State(initialValue: playlistsStore)
        _updates = State(initialValue: updatesStore)
        _player = State(initialValue: playerStore)
        _router = State(initialValue: routerStore)

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
                .onChange(of: scenePhase) {
                    // push any stuck updates when coming back to the foreground
                    if scenePhase == .active {
                        Task { await updates.flush() }
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
}
