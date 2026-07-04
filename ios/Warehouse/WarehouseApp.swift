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

    init() {
        let database = LibraryDatabase()
        let fileStore = FileStore(rootURL: FileStore.defaultRootURL())
        let updatesStore = UpdatesStore()
        _sync = State(initialValue: SyncStore(database: database, fileStore: fileStore))
        _songs = State(initialValue: SongsStore(database: database, fileStore: fileStore))
        _playlists = State(initialValue: PlaylistsStore(database: database))
        _updates = State(initialValue: updatesStore)
        _player = State(initialValue: PlayerStore(fileStore: fileStore, updates: updatesStore))
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(auth)
                .environment(sync)
                .environment(songs)
                .environment(playlists)
                .environment(updates)
                .environment(player)
                .onChange(of: scenePhase) {
                    // push any stuck updates when coming back to the foreground
                    if scenePhase == .active {
                        Task { await updates.flush() }
                    }
                }
        }
    }
}
