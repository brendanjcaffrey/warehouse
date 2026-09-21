import Foundation
import Testing
@testable import Warehouse

@Suite("offline library")
@MainActor
struct OfflineLibraryTests {
    @MainActor
    final class Downloader: SingleFileDownloading {
        let store: FileStore
        var calls: [String] = []
        var suspended = false
        var result: FileDownloadResult = .downloaded
        var bytes = 10

        init(_ store: FileStore) { self.store = store }

        @MainActor
        func download(_ type: LibraryFileType, filename: String, token: String, baseURL: URL) async -> Bool {
            await downloadResult(type, filename: filename, token: token, baseURL: baseURL, onPhase: { _ in }) == .downloaded
        }

        @MainActor
        func downloadResult(
            _ type: LibraryFileType, filename: String, token: String, baseURL: URL,
            onPhase: @escaping @MainActor @Sendable (FileDownloadPhase) -> Void
        ) async -> FileDownloadResult {
            calls.append(filename)
            onPhase(.waitingForPhone)
            while suspended, !Task.isCancelled { await Task.yield() }
            guard !Task.isCancelled else { return .failed }
            onPhase(.downloading)
            if result == .downloaded { try? store.write(type, filename, data: Data(count: bytes)) }
            return result
        }
    }

    @MainActor
    final class Fixture {
        let files = FileStore(rootURL: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString))
        lazy var cache = FileCache(fileStore: files, budget: { _ in FileCacheBudget(music: 100, artwork: 100) })
        lazy var downloader = Downloader(files)
        lazy var offline = makeLibrary()

        func makeLibrary() -> OfflineLibrary {
            OfflineLibrary(fileCache: cache, downloader: downloader, availableBytes: { 1_000_000_000 })
        }

        func activate(_ library: OfflineLibrary? = nil) {
            let library = library ?? offline
            library.setCredentials(token: "token", baseURL: URL(string: "https://example.com")!)
            library.setForeground(true)
        }
    }

    static func playlist(_ ids: [String], id: String = "p") -> PlaylistItem {
        PlaylistItem(id: id, name: id, parentId: "", isLibrary: false, isFolder: false, trackIds: ids)
    }

    @Test("preparation downloads the first and only track without playback")
    func singleTrack() async throws {
        let env = Fixture()
        env.activate()
        env.offline.prepare(Self.playlist(["1"]), songs: PlayerStoreTests.songs(1))
        try await PlayerStoreTests.waitFor { env.offline.progress("p").state == .ready }
        #expect(env.downloader.calls == ["1.wav"])
        #expect(env.offline.progress("p").completed == 1)
    }

    @Test("foreground return and recreation resume intent and reconcile files")
    func resumeAndReconcile() async throws {
        let env = Fixture()
        env.offline.prepare(Self.playlist(["1", "2"]), songs: PlayerStoreTests.songs(2))
        #expect(env.downloader.calls.isEmpty)
        try env.files.write(.music, "1.wav", data: Data(count: 10))
        let reopened = env.makeLibrary()
        #expect(reopened.progress("p").completed == 1)
        env.activate(reopened)
        try await PlayerStoreTests.waitFor { reopened.progress("p").state == .ready }
        #expect(env.downloader.calls == ["2.wav"])
        reopened.reconcile(playlists: [Self.playlist(["2", "3"])], songs: PlayerStoreTests.songs(3))
        try await PlayerStoreTests.waitFor { reopened.progress("p").state == .ready }
        #expect(env.downloader.calls == ["2.wav", "3.wav"])
    }

    @Test("paused selections survive eviction and removal respects shared membership")
    func retention() throws {
        let env = Fixture()
        let songs = PlayerStoreTests.songs(2)
        env.offline.prepare(Self.playlist(["1"]), songs: songs)
        env.offline.prepare(Self.playlist(["1"], id: "other"), songs: songs)
        env.offline.pause("p")
        try env.files.write(.music, "1.wav", data: Data(count: 60))
        env.cache.recordUse(.music, "1.wav")
        try env.files.write(.music, "2.wav", data: Data(count: 60))
        env.cache.recordUse(.music, "2.wav")
        env.cache.evict()
        #expect(env.files.exists(.music, "1.wav"))
        env.offline.remove("p")
        #expect(env.files.exists(.music, "1.wav"))
        env.offline.remove("other")
        #expect(!env.files.exists(.music, "1.wav"))
    }

    @Test("relaunch restores retention before eviction and completed playlists play without credentials")
    func offlineRelaunch() async throws {
        let env = Fixture()
        let songs = PlayerStoreTests.songs(2)
        env.offline.prepare(Self.playlist(["1", "2"]), songs: songs)
        for song in songs { try env.files.write(.music, song.musicFilename, data: PlayerStoreTests.musicBytes) }
        let cache = FileCache(fileStore: env.files, budget: { _ in FileCacheBudget(music: 1, artwork: 1) })
        let reopened = OfflineLibrary(fileCache: cache, downloader: env.downloader)
        cache.evict()
        #expect(reopened.progress("p").state == .ready)
        let player = PlayerStore(fileStore: env.files, fileCache: cache, streams: true, activateSessionForTests: { true })
        player.onPrefetchDemand = { reopened.setPlaybackDemand($0) }
        player.playShuffled(songs, token: nil, baseURL: nil, downloadedOnly: true)
        try await PlayerStoreTests.waitFor { player.hasLoadedTrack }
        #expect(!player.isStreamingCurrentTrack)
        #expect(env.downloader.calls.isEmpty)
        #expect(player.repeatMode == .all)
        player.pause()
    }

    @Test("a failed opportunistic fetch retries on renewed demand without a tight retry loop")
    func retryDemand() async throws {
        let env = Fixture()
        env.downloader.result = .failed
        env.activate()
        env.offline.setPlaybackDemand(["1.wav"])
        try await PlayerStoreTests.waitFor { env.downloader.calls.count == 1 }
        for _ in 0..<10 { await Task.yield() }
        env.offline.setPlaybackDemand(["1.wav"])
        #expect(env.downloader.calls.count == 1)
        env.downloader.result = .downloaded
        env.offline.setPlaybackDemand([])
        env.offline.setPlaybackDemand(["1.wav"])
        try await PlayerStoreTests.waitFor { env.files.exists(.music, "1.wav") }
        #expect(env.downloader.calls.count == 2)
    }

    @Test("queue demand changes do not cancel preparation; pause and cancel do")
    func cancellation() async throws {
        let env = Fixture()
        env.downloader.suspended = true
        env.activate()
        env.offline.prepare(Self.playlist(["1", "2"]), songs: PlayerStoreTests.songs(2))
        try await PlayerStoreTests.waitFor { env.offline.progress("p").state == .waitingForPhone }
        env.offline.setPlaybackDemand(["2.wav"])
        env.offline.setPlaybackDemand([])
        #expect(env.offline.progress("p").state == .waitingForPhone)
        env.offline.pause("p")
        #expect(env.offline.progress("p").state == .paused)
        env.downloader.suspended = false
        env.offline.prepare(Self.playlist(["1", "2"]), songs: PlayerStoreTests.songs(2))
        try await PlayerStoreTests.waitFor { env.offline.progress("p").state == .ready }
        env.offline.cancel("p")
        #expect(!env.offline.isSelected("p"))
        #expect(env.files.exists(.music, "1.wav"))
    }

    @Test("leaving the foreground cancels transport, preserves intent and resumes on return")
    func foregroundLifecycle() async throws {
        let env = Fixture()
        env.downloader.suspended = true
        env.activate()
        env.offline.prepare(Self.playlist(["1"]), songs: PlayerStoreTests.songs(1))
        try await PlayerStoreTests.waitFor { env.downloader.calls.count == 1 }
        env.offline.setForeground(false)
        env.downloader.suspended = false
        for _ in 0..<10 { await Task.yield() }
        #expect(!env.files.exists(.music, "1.wav"))
        #expect(env.offline.progress("p").state == .paused)
        env.offline.setForeground(true)
        try await PlayerStoreTests.waitFor { env.offline.progress("p").state == .ready }
        #expect(env.downloader.calls == ["1.wav", "1.wav"])
    }

    @Test("pause persists across recreation and resume retries a failed file")
    func persistedPauseAndRetry() async throws {
        let env = Fixture()
        env.offline.prepare(Self.playlist(["1"]), songs: PlayerStoreTests.songs(1))
        env.offline.pause("p")
        let reopened = env.makeLibrary()
        env.activate(reopened)
        #expect(reopened.progress("p").state == .paused)
        #expect(env.downloader.calls.isEmpty)
        env.downloader.result = .failed
        reopened.resume("p")
        try await PlayerStoreTests.waitFor { reopened.progress("p").state == .failed }
        env.downloader.result = .downloaded
        reopened.resume("p")
        try await PlayerStoreTests.waitFor { reopened.progress("p").state == .ready }
        #expect(env.downloader.calls == ["1.wav", "1.wav"])
    }

    @Test("low or unknown free space reports storage full before starting transport")
    func noCapacity() {
        for capacity: Int64? in [0, nil] {
            let env = Fixture()
            let offline = OfflineLibrary(fileCache: env.cache, downloader: env.downloader, availableBytes: { capacity })
            env.activate(offline)
            offline.prepare(Self.playlist(["1"]), songs: PlayerStoreTests.songs(1))
            #expect(offline.progress("p").state == .storageFull)
            #expect(env.downloader.calls.isEmpty)
        }
    }

    @Test("preparation reclaims a full opportunistic cache without deleting selected music")
    func reclaimCache() async throws {
        let env = Fixture()
        try env.files.write(.music, "old.wav", data: Data(count: 100))
        env.activate()
        env.offline.prepare(Self.playlist(["1", "2"]), songs: PlayerStoreTests.songs(2))
        try await PlayerStoreTests.waitFor { env.offline.progress("p").state == .ready }
        #expect(!env.files.exists(.music, "old.wav"))
        #expect(env.files.list(.music) == ["1.wav", "2.wav"])
    }

    @Test("deep cache filling stops at its budget instead of evicting and refetching its own files")
    func boundedDeepFilling() async throws {
        let env = Fixture()
        env.downloader.bytes = 30
        env.cache.setInUse(.music, ["1.wav"])
        env.activate()
        env.offline.setPlaybackDemand((1...10).map { "\($0).wav" })
        try await PlayerStoreTests.waitFor { env.files.exists(.music, "4.wav") }
        for _ in 0..<100 { await Task.yield() }
        env.offline.setForeground(false)
        #expect(env.downloader.calls == ["1.wav", "2.wav", "3.wav", "4.wav"])
    }

    @Test("explicit preparation takes precedence over deep opportunistic demand")
    func preparationPriority() async throws {
        let env = Fixture()
        env.offline.setPlaybackDemand(["urgent.wav", "deep.wav"])
        env.offline.prepare(Self.playlist(["1", "2"]), songs: PlayerStoreTests.songs(2))
        env.activate()
        try await PlayerStoreTests.waitFor { env.downloader.calls.count == 4 }
        #expect(env.downloader.calls == ["urgent.wav", "1.wav", "2.wav", "deep.wav"])
    }

    @Test("removing an oversized selection unblocks other preparation")
    func removeStorageBlocker() async throws {
        let env = Fixture()
        env.downloader.bytes = 120
        env.activate()
        env.offline.prepare(Self.playlist(["1"]), songs: PlayerStoreTests.songs(1))
        try await PlayerStoreTests.waitFor { env.offline.progress("p").state == .storageFull }
        env.offline.prepare(Self.playlist(["2"], id: "other"), songs: PlayerStoreTests.songs(2))
        #expect(env.offline.progress("other").state == .storageFull)
        env.downloader.bytes = 10
        env.offline.remove("p")
        try await PlayerStoreTests.waitFor { env.offline.progress("other").state == .ready }
    }

    @Test("a failed manifest write keeps the last durable selection protected")
    func persistenceFailure() throws {
        let env = Fixture()
        env.offline.prepare(Self.playlist(["1"]), songs: PlayerStoreTests.songs(1))
        try env.files.write(.music, "1.wav", data: Data(count: 60))
        let manifest = env.files.rootURL.appending(path: "offline-playlists.json")
        try FileManager.default.removeItem(at: manifest)
        try FileManager.default.createDirectory(at: manifest, withIntermediateDirectories: false)
        env.offline.remove("p")
        #expect(env.offline.isSelected("p"))
        #expect(env.offline.errorMessage != nil)
        try env.files.write(.music, "2.wav", data: Data(count: 60))
        env.cache.recordUse(.music, "2.wav")
        env.cache.evict()
        #expect(env.files.exists(.music, "1.wav"))
    }

    @Test("offline artwork uses cached files and never starts transport")
    func offlineArtwork() async throws {
        let env = Fixture()
        let artwork = WatchArtworkFetcher(fileCache: env.cache, downloader: env.downloader,
                                          credentials: { ("token", URL(string: "https://example.com")!) })
        #expect(await artwork.artworkURL("missing.jpg", allowNetwork: false) == nil)
        try env.files.write(.artwork, "local.jpg", data: Data(count: 10))
        #expect(await artwork.artworkURL("local.jpg", allowNetwork: false) == env.files.fileURL(.artwork, "local.jpg"))
        #expect(env.downloader.calls.isEmpty)
    }

    @Test("the server adapter preserves storage failures for preparation")
    func serverStorageFailure() async {
        let host = "storage-\(UUID().uuidString).example.com"
        MockURLProtocol.setHandler(forHost: host) { _ in throw URLError(.cannotWriteToFile) }
        var client = LibraryClient()
        client.session = MockURLProtocol.makeSession()
        let env = Fixture()
        let downloader = FileDownloader(client: client, fileStore: env.files)
        let result = await downloader.downloadResult(.music, filename: "1.wav", token: "token",
                                                     baseURL: URL(string: "https://\(host)")!, onPhase: { _ in })
        #expect(result == .outOfSpace)
        #expect(env.files.list(.music).isEmpty)
    }

    @Test("partial metadata, failed transfers and oversized selections never claim ready")
    func incomplete() async throws {
        let env = Fixture()
        env.activate()
        env.offline.prepare(Self.playlist(["1", "missing"]), songs: PlayerStoreTests.songs(1))
        try await PlayerStoreTests.waitFor { env.offline.progress("p").completed == 1 }
        #expect(env.offline.progress("p").total == 2)
        #expect(env.offline.progress("p").state != .ready)
        env.downloader.result = .outOfSpace
        env.offline.prepare(Self.playlist(["1", "2"]), songs: PlayerStoreTests.songs(2))
        try await PlayerStoreTests.waitFor { env.offline.progress("p").state == .storageFull }
        #expect(env.files.exists(.music, "1.wav"))
        env.downloader.result = .downloaded
        env.downloader.bytes = 120
        env.offline.prepare(Self.playlist(["1", "2"]), songs: PlayerStoreTests.songs(2))
        try await PlayerStoreTests.waitFor { env.offline.progress("p").state == .storageFull }
        #expect(env.offline.progress("p").completed == 1)
    }
}
