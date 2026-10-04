import Foundation

/// the watch's production composition has no server sync or network acquisition service.
@MainActor
final class WatchLibraryServices {
    let songs: SongsStore
    let playlists: PlaylistsStore
    let library: WatchLibraryStore
    let receiver: WatchLibraryReceiver
    private(set) var content: WatchContentReceiver?
    let player: PlayerStore
    let artwork: WatchArtworkFetcher
    let fileCache: FileCache
    private let migration: OfflineLibrary
    var requestLibrary: () -> Void = {}
    var onContentChanged: () -> Void = {}
    var availableBytes: () -> Int64? = { FileStore.deviceStorage()?.availableBytes }
    var now: () -> Date = { Date() }
    private let contentDirectory: URL
    private let sendReceipt: (WatchContentReceipt) -> Void
    private let contentState: WatchDeliveryState

    init(
        database: LibraryDatabase, fileStore: FileStore, defaults: UserDefaults = .standard,
        metadataDirectory: URL = WatchLibraryReceiver.defaultDirectory(),
        contentDirectory: URL = WatchContentReceiver.defaultDirectory(),
        client: LibraryClient = LibraryClient(),
        sendReceipt: @escaping (WatchContentReceipt) -> Void = { _ in },
        onTrackPlayed: @escaping @MainActor (PlayPayload) -> Void = { _ in },
        onPlaybackRequested: @escaping @MainActor () -> Void = {},
        contentState: WatchDeliveryState = .init()
    ) {
        // discard old watch credentials without changing saved library metadata or files.
        for key in ["serverURL", "deepPrefetchDepth", "fileGeneration"] { defaults.removeObject(forKey: key) }
        self.contentDirectory = contentDirectory
        self.contentState = contentState
        self.sendReceipt = sendReceipt
        fileCache = FileCache(fileStore: fileStore)
        migration = OfflineLibrary(fileCache: fileCache)
        songs = SongsStore(database: database, fileStore: fileStore)
        playlists = PlaylistsStore(database: database)
        receiver = WatchLibraryReceiver(database: database, directory: metadataDirectory)
        library = WatchLibraryStore(songs: songs, playlists: playlists, defaults: defaults, receiver: receiver)
        player = PlayerStore(fileStore: fileStore, client: client, fileCache: fileCache,
                             onTrackPlayed: onTrackPlayed, onPlaybackRequested: onPlaybackRequested, musicPolicy: .downloadedOnly)
        artwork = WatchArtworkFetcher(fileStore: fileStore)
        receiver.onChanged = { [weak self] in
            guard let self else { return }
            restoreContent()
            try? content?.reconcile(head: receiver.head, snapshot: receiver.snapshot)
            migration.retireForPhoneSelection()
            await library.load()
        }
        fileCache.onMusicChanged = { [weak self] in
            self?.songs.refreshDownloads()
            self?.player.downloadsChanged()
        }
        restoreContent()
    }

    private func restoreContent(repairsDamage: Bool = false) {
        guard content == nil else { return }
        do {
            var state = contentState
            state.repairsDamage = repairsDamage
            content = try WatchContentReceiver(fileCache: fileCache, directory: contentDirectory,
                                                availableBytes: { [weak self] in self?.availableBytes() }, send: sendReceipt,
                                                now: { [weak self] in self?.now() ?? Date() }, state: state)
            library.content = content
            library.deliveryStartupError = nil
            if content?.recoveredState == true { library.deliveryRecovered = true }
            onContentChanged()
        } catch {
            library.deliveryStartupError = error.localizedDescription
        }
    }

    func launch() async {
        await receiver.waitForImport()
        restoreContent()
        try? content?.reconcile(head: receiver.head, snapshot: receiver.snapshot)
        migration.retireForPhoneSelection()
        // do not evict old downloads until phone intent is safely persisted.
        if fileCache.hasDurableWatchSelection { fileCache.evict() }
        await library.load()
    }

    func refresh() async {
        restoreContent(repairsDamage: true)
        receiver.resume()
        await launch()
        content?.resume()
        requestLibrary()
    }
}
