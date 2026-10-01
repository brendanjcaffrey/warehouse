import SwiftUI
import WatchKit
import WatchConnectivity

@main
struct WarehouseWatchApp: App {
    @WKApplicationDelegateAdaptor(WatchBackgroundDelegate.self) private var backgroundDelegate
    @Environment(\.scenePhase) private var scenePhase
    @State private var settings: WatchSettingsStore
    @State private var sync: SyncStore
    @State private var songs: SongsStore
    @State private var playlists: PlaylistsStore
    @State private var library: WatchLibraryStore
    @State private var receiver: WatchLibraryReceiver
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
        let receiver = WatchLibraryReceiver(database: database)
        let phone = WatchPhoneSession(settings: settings, library: receiver)
        _receiver = State(initialValue: receiver)
        WatchBackgroundDelegate.phone = phone
        let credentials: @MainActor @Sendable () -> (token: String, baseURL: URL)? = {
            guard receiver.allowsLegacySync, let token = settings.token, let baseURL = settings.baseURL() else { return nil }
            return (token: token, baseURL: baseURL)
        }
        // selected offline music is retained; the rest is a bounded cache.
        // every eviction sees both offline selections and the player's in-use files.
        let fileCache = FileCache(fileStore: fileStore)
        let content = try? WatchContentReceiver(fileCache: fileCache, send: { receipt in
            guard phone.canSend, let info = try? receipt.encode() else { return }
            let alreadyQueued = WCSession.default.outstandingUserInfoTransfers.contains {
                WatchContentReceipt(dictionary: $0.userInfo) == receipt
            }
            if !alreadyQueued { WCSession.default.transferUserInfo(info) }
        })
        phone.content = content
        // preparation and browsing keep their legacy transport during migration.
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
        let library = WatchLibraryStore(songs: songs, playlists: playlists, receiver: receiver)
        _library = State(initialValue: library)
        receiver.onChanged = {
            try? content?.reconcile(head: receiver.head, snapshot: receiver.snapshot)
            offline.retireForPhoneSelection()
            if !receiver.allowsLegacySync {
                syncStore.requestWatchSync(token: nil, baseURL: nil, playlistIds: [], generation: settings.configurationChanges + 1)
                offline.setCredentials(token: nil, baseURL: nil)
            } else {
                offline.setCredentials(token: settings.token, baseURL: settings.baseURL())
            }
            await library.load()
            guard songs.errorMessage == nil, playlists.errorMessage == nil else { return }
            offline.reconcile(playlists: playlists.playlists, songs: songs.songs)
            try? content?.reconcile(head: receiver.head, snapshot: receiver.snapshot)
        }
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
            onTrackPlayed: { plays.add(trackId: $0) },
            musicPolicy: .downloadedOnly)
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
        Task { @MainActor in
            await receiver.waitForImport()
            try? content?.reconcile(head: receiver.head, snapshot: receiver.snapshot)
            if receiver.allowsLegacySync || fileCache.hasDurableWatchSelection { fileCache.evict() }
        }
    }

    var body: some Scene {
        WindowGroup {
            WatchRootView()
                .environment(settings)
                .environment(sync)
                .environment(songs)
                .environment(playlists)
                .environment(library)
                .environment(receiver)
                .environment(player)
                .environment(remote)
                .environment(offline)
                .environment(\.artworkFetcher, artwork)
                .environment(\.diagnosticSender, phone)
                .onChange(of: settings.configurationChanges, initial: true) {
                    offline.setCredentials(token: receiver.allowsLegacySync ? settings.token : nil,
                                           baseURL: receiver.allowsLegacySync ? settings.baseURL() : nil)
                }
                .onChange(of: scenePhase, initial: true) {
                    offline.setForeground(scenePhase == .active)
                    // pushes only reach a watch that was listening at the
                    // time, so coming to the front is when to ask
                    if scenePhase == .active {
                        receiver.resume()
                        phone.requestLibrary()
                        remote.requestState()
                    }
                }
        }
    }
}

@MainActor
final class WatchBackgroundDelegate: NSObject, WKApplicationDelegate {
    static var phone: WatchPhoneSession?

    func handle(_ backgroundTasks: Set<WKRefreshBackgroundTask>) {
        for task in backgroundTasks {
            guard let connectivity = task as? WKWatchConnectivityRefreshBackgroundTask, let phone = Self.phone else {
                task.setTaskCompletedWithSnapshot(false)
                continue
            }
            phone.library.resume()
            phone.content?.resume()
            phone.updateBackgroundLifetime()
            phone.lifetime.hold { connectivity.setTaskCompletedWithSnapshot(false) }
        }
    }
}
