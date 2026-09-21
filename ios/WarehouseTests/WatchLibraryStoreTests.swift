import CoreData
import Foundation
import Testing
@testable import Warehouse

@Suite("WatchLibraryStore", .serialized)
@MainActor
struct WatchLibraryStoreTests {
    @MainActor
    struct Env {
        let root: URL
        let defaults: UserDefaults
        let database: LibraryDatabase
        let files: FileStore
        let songs: SongsStore
        let playlists: PlaylistsStore
        let library: WatchLibraryStore

        init() throws {
            root = FileManager.default.temporaryDirectory.appending(path: "watch-startup-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defaults = UserDefaults(suiteName: root.lastPathComponent)!
            database = LibraryDatabase(storeURL: root.appending(path: "library.sqlite"))
            files = FileStore(rootURL: root.appending(path: "files"))
            songs = SongsStore(database: database, fileStore: files)
            playlists = PlaylistsStore(database: database)
            library = WatchLibraryStore(songs: songs, playlists: playlists, defaults: defaults)
        }

        func save(empty: Bool = false) async throws {
            var saved = Library()
            if !empty {
                var track = Track()
                track.id = "local"
                track.name = "Saved song"
                track.musicFilename = "local.wav"
                track.duration = 240
                saved.tracks = [track]
                var playlist = Playlist()
                playlist.id = "p1"
                playlist.name = "Saved playlist"
                playlist.trackIds = [track.id]
                saved.playlists = [playlist]
                try files.write(.music, track.musicFilename, data: PlayerStoreTests.musicBytes)
            }
            saved.updateTimeNs = 43
            try await database.replaceLibrary(with: saved)
            LibraryMetadata(defaults: defaults).update(from: saved)
        }

        func sync(session: URLSession = MockURLProtocol.makeSession()) -> SyncStore {
            SyncStore(database: database, fileStore: files, session: session, defaults: defaults, transfersFiles: false)
        }

        func cleanUp() {
            Self.close(database)
            defaults.removePersistentDomain(forName: root.lastPathComponent)
            try? FileManager.default.removeItem(at: root)
        }

        static func close(_ database: LibraryDatabase) {
            let coordinator = database.container.persistentStoreCoordinator
            for store in coordinator.persistentStores {
                try? coordinator.remove(store)
            }
        }
    }

    private func assertLocalPlayback(songs: SongsStore, files: FileStore) async throws {
        let player = PlayerStore(fileStore: files, streams: true, activateSessionForTests: { true })
        defer { player.pause() }
        // no credentials: this can succeed only from the saved music file
        player.play(songs.songs, token: nil, baseURL: nil)
        try await PlayerStoreTests.waitFor { player.hasLoadedTrack && player.currentTime > 0 }
        #expect(player.status == .ready && player.isPlaying)
        #expect(player.currentItemURL == files.fileURL(.music, "local.wav"))
        #expect(songs.isDownloaded(try #require(songs.songs.first)))
    }

    @Test("saved library and local playback are ready while the version request never replies")
    func suspendedVersionDoesNotGateLibrary() async throws {
        let env = try Env()
        defer { env.cleanUp() }
        try await env.save()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SuspendedLibraryProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let sync = env.sync(session: session)
        let refresh = Task { await sync.sync(token: "tok", baseURL: URL(string: "https://suspended-startup.test")) }
        defer { refresh.cancel() }
        try await PlayerStoreTests.waitFor { SuspendedLibraryProtocol.hasVersionRequest }
        #expect(sync.state == .checkingForUpdates)

        await env.library.load()

        #expect(env.library.presentation(isConfigured: true) == .ready)
        #expect(env.playlists.playlists.map(\.id) == ["p1"])
        #expect(sync.completedSyncs == 0)
        try await assertLocalPlayback(songs: env.songs, files: env.files)
        #expect(sync.completedSyncs == 0)
    }

    @Test("cold startup uses saved songs in airplane mode and after a server error", arguments: [false, true])
    func coldOfflineStartup(serverError: Bool) async throws {
        let env = try Env()
        defer { env.cleanUp() }
        try await env.save()
        let host = "startup-\(serverError).test"
        MockURLProtocol.setHandler(forHost: host) { request in
            if !serverError { throw URLError(.notConnectedToInternet) }
            return (HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!, Data())
        }
        // recreate the database and view stores from the same persisted files
        Env.close(env.database)
        let reopened = LibraryDatabase(storeURL: env.root.appending(path: "library.sqlite"))
        defer { Env.close(reopened) }
        let songs = SongsStore(database: reopened, fileStore: env.files)
        let library = WatchLibraryStore(
            songs: songs, playlists: PlaylistsStore(database: reopened), defaults: env.defaults)
        await library.load()
        #expect(library.presentation(isConfigured: true) == .ready)
        let sync = SyncStore(
            database: reopened, fileStore: env.files, session: MockURLProtocol.makeSession(),
            defaults: env.defaults, transfersFiles: false)
        await sync.sync(token: "tok", baseURL: URL(string: "https://\(host)"))
        await library.load()
        #expect(library.presentation(isConfigured: true) == .ready)
        if serverError {
            guard case .error = sync.state else { Issue.record("expected server error"); return }
        } else {
            #expect(sync.state == .offline)
        }
        try await assertLocalPlayback(songs: songs, files: env.files)
    }

    @Test("first install needs setup then sync, and a failed sync does not imply an empty library")
    func firstInstall() async throws {
        let env = try Env()
        defer { env.cleanUp() }
        #expect(env.library.presentation(isConfigured: false) == .setup)
        #expect(env.library.presentation(isConfigured: true) == .loading)
        await env.library.load()
        #expect(env.library.presentation(isConfigured: true) == .needsSync)
        let host = "startup-first.test"
        MockURLProtocol.setHandler(forHost: host) { _ in throw URLError(.notConnectedToInternet) }
        await env.sync().sync(token: "tok", baseURL: URL(string: "https://\(host)"))
        await env.library.load()
        #expect(env.library.presentation(isConfigured: true) == .needsSync)
    }

    @Test("an empty successful sync remains empty after relaunch and selection watermark invalidation")
    func emptyLibrary() async throws {
        let env = try Env()
        defer { env.cleanUp() }
        let host = "startup-empty.test"
        var empty = Library()
        empty.updateTimeNs = 0
        try SyncStoreTests.installHandler(host: host, library: empty)
        await env.sync().sync(token: "tok", baseURL: URL(string: "https://\(host)"))
        let metadata = LibraryMetadata(defaults: env.defaults)
        #expect(metadata.hasSavedLibrary)
        metadata.updateTimeNs = 0
        let reopened = WatchLibraryStore(songs: env.songs, playlists: env.playlists, defaults: env.defaults)
        await reopened.load()
        #expect(reopened.presentation(isConfigured: true) == .empty)
        metadata.clear()
        #expect(!metadata.hasSavedLibrary)
    }

    @Test("previous versions recognize saved empty libraries from their watermark")
    func legacyEmptyLibrary() async throws {
        let env = try Env()
        defer { env.cleanUp() }
        LibraryMetadata(defaults: env.defaults).updateTimeNs = 43
        LibraryMetadata(defaults: env.defaults).updateTimeNs = 0
        await env.library.load()
        #expect(env.library.presentation(isConfigured: true) == .empty)
    }

    @Test("sign-out hides saved music while token refresh and connection errors preserve readiness")
    func signOut() async throws {
        let env = try Env()
        defer { env.cleanUp() }
        try await env.save()
        await env.library.load()
        let settings = WatchSettingsStore(defaults: env.defaults, readToken: { nil }, writeToken: { _ in })
        settings.apply(WatchPayload(serverURL: "example.com", token: "tok", playlistIds: ["p1"]))
        #expect(env.library.presentation(isConfigured: settings.isConfigured) == .ready)
        settings.apply(WatchPayload(serverURL: "example.com", token: "refreshed", playlistIds: ["p1"]))
        #expect(env.library.presentation(isConfigured: settings.isConfigured) == .ready)
        settings.apply(WatchPayload(serverURL: "example.com", token: "", playlistIds: ["p1"]))
        #expect(env.library.presentation(isConfigured: settings.isConfigured) == .setup)
        #expect(env.files.exists(.music, "local.wav"))
    }

    @Test("an unreadable local database reports a failure instead of crashing or pretending to be empty")
    func databaseFailure() async throws {
        let env = try Env()
        defer { env.cleanUp() }
        let invalid = env.root.appending(path: "invalid.sqlite")
        try Data("not a sqlite database".utf8).write(to: invalid)
        let database = LibraryDatabase(storeURL: invalid)
        let library = WatchLibraryStore(
            songs: SongsStore(database: database, fileStore: env.files),
            playlists: PlaylistsStore(database: database), defaults: env.defaults)
        await library.load()
        guard case .failed(let message) = library.presentation(isConfigured: true) else {
            Issue.record("expected local database failure")
            return
        }
        #expect(!message.isEmpty)
        #expect(library.presentation(isConfigured: false) == .setup)
    }
}

/// accepts a request without replying; cancellation ends the test's remote refresh
private final class SuspendedLibraryProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var versionRequested = false

    static var hasVersionRequest: Bool {
        lock.lock()
        defer { lock.unlock() }
        return versionRequested
    }

    override static func canInit(with request: URLRequest) -> Bool { true }
    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock()
        Self.versionRequested = request.url?.path == "/api/version"
        Self.lock.unlock()
    }
    override func stopLoading() {}
}
