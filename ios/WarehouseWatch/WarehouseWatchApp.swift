import SwiftUI

@main
struct WarehouseWatchApp: App {
    @State private var settings: WatchSettingsStore
    @State private var sync: SyncStore
    @State private var songs: SongsStore
    @State private var playlists: PlaylistsStore

    private let phone: WatchPhoneSession

    init() {
        let database = LibraryDatabase()
        let fileStore = FileStore(rootURL: FileStore.defaultRootURL())
        let settings = WatchSettingsStore()
        let syncStore = SyncStore(database: database, fileStore: fileStore)
        // only the selected playlists & their tracks are kept and downloaded
        syncStore.libraryFilter = { LibraryFilter.filter($0, playlistIds: Set(settings.playlistIds)) }
        _settings = State(initialValue: settings)
        _sync = State(initialValue: syncStore)
        _songs = State(initialValue: SongsStore(database: database, fileStore: fileStore))
        _playlists = State(initialValue: PlaylistsStore(database: database))
        phone = WatchPhoneSession(settings: settings)
    }

    var body: some Scene {
        WindowGroup {
            WatchRootView()
                .environment(settings)
                .environment(sync)
                .environment(songs)
                .environment(playlists)
                .task {
                    phone.activate()
                }
        }
    }
}
