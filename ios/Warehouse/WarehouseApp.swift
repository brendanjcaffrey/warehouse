import SwiftUI

@main
struct WarehouseApp: App {
    @Environment(\.scenePhase) private var scenePhase

    @State private var auth = AuthStore()
    @State private var sync: SyncStore
    @State private var songs: SongsStore
    @State private var playlists: PlaylistsStore
    @State private var updates: UpdatesStore
    @State private var player: PlayerStore
    @State private var router = NavigationRouter()
    @State private var seeded = false

    private let database: LibraryDatabase

    init() {
        let database = LibraryDatabase(inMemory: UITestSupport.enabled)
        self.database = database
        let fileStore = FileStore(rootURL: FileStore.defaultRootURL())
        let updatesStore = UpdatesStore(fileStore: fileStore)
        let syncStore = SyncStore(database: database, fileStore: fileStore)
        // artwork queued for upload must survive sync's file cleanup
        syncStore.protectedArtworkFilenames = { updatesStore.pendingArtworkFilenames }
        _sync = State(initialValue: syncStore)
        _songs = State(initialValue: SongsStore(database: database, fileStore: fileStore))
        _playlists = State(initialValue: PlaylistsStore(database: database))
        _updates = State(initialValue: updatesStore)
        _player = State(initialValue: PlayerStore(fileStore: fileStore, updates: updatesStore))
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
        }
    }
}
