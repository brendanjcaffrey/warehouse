import SwiftUI

@main
struct WarehouseApp: App {
    @State private var auth = AuthStore()
    @State private var sync: SyncStore
    @State private var songs: SongsStore
    @State private var playlists: PlaylistsStore
    @State private var player: PlayerStore

    init() {
        let database = LibraryDatabase()
        let fileStore = FileStore(rootURL: FileStore.defaultRootURL())
        _sync = State(initialValue: SyncStore(database: database, fileStore: fileStore))
        _songs = State(initialValue: SongsStore(database: database, fileStore: fileStore))
        _playlists = State(initialValue: PlaylistsStore(database: database))
        _player = State(initialValue: PlayerStore(fileStore: fileStore))
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(auth)
                .environment(sync)
                .environment(songs)
                .environment(playlists)
                .environment(player)
        }
    }
}
