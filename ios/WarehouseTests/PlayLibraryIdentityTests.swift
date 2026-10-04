import Foundation
import Testing
@testable import Warehouse

@Suite("play library identity", .serialized)
@MainActor
struct PlayLibraryIdentityTests {
    @Test("same-account token refresh preserves retries already waiting for transport recovery")
    func refreshPreservesRetry() async throws {
        let env = UpdatesStoreTests.makeEnv(host: "play-library-refresh-retry.test", retryInterval: 0.02)
        defer { try? FileManager.default.removeItem(at: env.fileURL.deletingLastPathComponent()) }
        MockURLProtocol.setHandler(forHost: env.host) { _ in throw URLError(.notConnectedToInternet) }
        env.store.configure(token: UpdatesStoreTests.token(), baseURL: env.baseURL)
        await env.store.addPlay(trackId: "t1", libraryID: env.identity)
        #expect(env.store.pending.count == 1)
        try UpdatesStoreTests.installHandler(host: env.host)
        env.store.configure(token: UpdatesStoreTests.token("refreshed"), baseURL: env.baseURL)
        try await PlayerStoreTests.waitFor { env.store.pending.isEmpty }
        let request = try #require(MockURLProtocol.requests(forHost: env.host).first)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer \(UpdatesStoreTests.token("refreshed"))")
    }

    @Test("phone sync persists matching song ownership and export policy through token refresh")
    func phoneSyncIdentity() async throws {
        let env = SyncStoreTests.makeEnv(host: "play-library-sync.test")
        try SyncStoreTests.installHandler(host: env.host)
        let token = UpdatesStoreTests.token()
        let identity = try #require(LibraryIdentity.make(token: token, baseURL: env.baseURL))
        await env.store.sync(token: token, baseURL: env.baseURL)
        #expect(env.metadata.libraryID == identity)
        #expect(try await env.database.allSongs().allSatisfy { $0.libraryID == identity })
        #expect(try await env.database.songs(ids: ["t1"])["t1"]?.libraryID == identity)
        try SyncStoreTests.installHandler(host: env.host)
        await env.store.sync(token: UpdatesStoreTests.token("refreshed"), baseURL: env.baseURL)
        #expect(env.metadata.libraryID == identity)
        #expect(!MockURLProtocol.requests(forHost: env.host).contains { $0.url?.path == "/api/library" })
    }

    @Test("a library that disables changes consumes only reports with matching ownership")
    func matchingPolicy() async throws {
        let env = UpdatesStoreTests.makeEnv(host: "play-library-policy.test", trackUserChanges: false)
        defer { try? FileManager.default.removeItem(at: env.fileURL.deletingLastPathComponent()) }
        try UpdatesStoreTests.installHandler(host: env.host)
        try env.store.recordWatchPlay(PlayPayload(trackId: "old", libraryID: "another-library"))
        try env.store.recordWatchPlay(PlayPayload(trackId: "unknown"))
        let current = PlayPayload(trackId: "current", libraryID: env.identity)
        try env.store.recordWatchPlay(current)
        env.store.configure(token: UpdatesStoreTests.token(), baseURL: env.baseURL)
        await env.store.flush()
        #expect(env.store.pending.map(\.trackId) == ["old", "unknown"])
        #expect(MockURLProtocol.requests(forHost: env.host).isEmpty)
        let relaunched = UpdatesStoreTests.relaunch(env)
        try relaunched.recordWatchPlay(current)
        #expect(relaunched.pending.map(\.trackId) == ["old", "unknown"])
    }

    @Test("cached advancement and repeat report the identity of each finished row")
    func cachedQueueReports() async throws {
        let files = FileCacheTests.makeStore()
        var first = PlayerStoreTests.song(id: "1")
        first.libraryID = "a"
        var second = PlayerStoreTests.song(id: "2")
        second.libraryID = "b"
        for song in [first, second] { try files.write(.music, song.musicFilename, data: PlayerStoreTests.musicBytes) }
        var reports = [PlayPayload]()
        let player = PlayerStore(fileStore: files, onTrackPlayed: { reports.append($0) },
                                 musicPolicy: .downloadedOnly, activateSessionForTests: { true })
        defer { player.pause() }
        player.play([first, second], token: nil, baseURL: nil)
        try await PlayerStoreTests.waitFor { player.nextItemURL != nil }
        player.handleTrackEnd()
        #expect(player.advancedOntoEnqueuedItem)
        #expect(reports.map(\.libraryID) == ["a"])
        player.setRepeatMode(.one)
        player.handleTrackEnd()
        #expect(reports.map(\.libraryID) == ["a", "b"])
        #expect(reports[0].id != reports[1].id)
    }

    @Test("old watch reports survive account changes, sign-out and cold receipts until their account returns")
    func accountRetention() async throws {
        let env = UpdatesStoreTests.makeEnv(host: "play-library-accounts.test")
        defer { try? FileManager.default.removeItem(at: env.fileURL.deletingLastPathComponent()) }
        let old = PlayPayload(trackId: "shared", libraryID: env.identity)
        let otherToken = UpdatesStoreTests.token(username: "other")
        let otherID = try #require(LibraryIdentity.make(token: otherToken, baseURL: env.baseURL))
        let metadata = LibraryMetadata(defaults: env.defaults)
        metadata.libraryID = otherID
        metadata.trackUserChanges = false
        try UpdatesStoreTests.installHandler(host: env.host)
        env.store.configure(token: otherToken, baseURL: env.baseURL)
        try env.store.recordWatchPlay(old)
        await env.store.flush()
        #expect(env.store.pending.count == 1)
        #expect(MockURLProtocol.requests(forHost: env.host).isEmpty)
        env.store.configure(token: nil, baseURL: env.baseURL)
        await env.store.flush()

        let relaunched = UpdatesStoreTests.relaunch(env)
        var receipts = [PlayPayload]()
        let session = PhoneWatchSession(onPlay: { try relaunched.recordWatchPlay($0) },
                                       acknowledgePlay: { receipts.append($0) })
        session.receive(userInfo: old.encode())
        try await PlayerStoreTests.waitFor { receipts == [old] }
        #expect(relaunched.pending.count == 1)
        relaunched.configure(token: otherToken, baseURL: env.baseURL)
        await relaunched.flush()
        #expect(MockURLProtocol.requests(forHost: env.host).isEmpty)
        metadata.libraryID = env.identity
        metadata.trackUserChanges = true
        relaunched.configure(token: UpdatesStoreTests.token("refreshed"), baseURL: env.baseURL)
        await relaunched.flush()
        #expect(relaunched.pending.isEmpty)
        let request = try #require(MockURLProtocol.requests(forHost: env.host).first)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer \(UpdatesStoreTests.token("refreshed"))")
        let completed = UpdatesStoreTests.relaunch(env)
        try completed.recordWatchPlay(old)
        #expect(completed.pending.isEmpty)
        #expect(throws: (any Error).self) {
            try completed.recordWatchPlay(PlayPayload(id: old.id, trackId: old.trackId, libraryID: otherID))
        }
    }

    @Test("legacy phone updates and watch ownership stay unassigned through migration")
    func legacyRetention() async throws {
        let env = UpdatesStoreTests.makeEnv(host: "play-library-legacy.test")
        defer { try? FileManager.default.removeItem(at: env.fileURL.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: env.fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let legacy = #"{"pending":[{"type":"play","trackId":"shared","params":{}}],"watchPlays":{"old":"shared"}}"#
        try Data(legacy.utf8).write(to: env.fileURL)
        let store = UpdatesStoreTests.relaunch(env)
        store.configure(token: UpdatesStoreTests.token(), baseURL: env.baseURL)
        try UpdatesStoreTests.installHandler(host: env.host)
        try store.recordWatchPlay(PlayPayload(id: "old", trackId: "shared"))
        try store.recordWatchPlay(PlayPayload(id: "unknown", trackId: "shared"))
        await store.flush()
        #expect(store.pending.count == 2)
        #expect(store.pending.allSatisfy { $0.libraryID == nil })
        #expect(MockURLProtocol.requests(forHost: env.host).isEmpty)
        #expect(UpdatesStoreTests.relaunch(env).pending == store.pending)
    }

    @Test("same-account refresh drains eligible reports without waiting behind old libraries")
    func mixedLibraries() async throws {
        let env = UpdatesStoreTests.makeEnv(host: "play-library-mixed.test")
        defer { try? FileManager.default.removeItem(at: env.fileURL.deletingLastPathComponent()) }
        try env.store.recordWatchPlay(PlayPayload(trackId: "shared", libraryID: "old-library"))
        try env.store.recordWatchPlay(PlayPayload(trackId: "shared", libraryID: env.identity))
        try env.store.recordWatchPlay(PlayPayload(trackId: "next", libraryID: env.identity))
        env.store.configure(token: UpdatesStoreTests.token("new"), baseURL: env.baseURL)
        try UpdatesStoreTests.installHandler(host: env.host)
        await env.store.flush()
        #expect(env.store.pending.map(\.libraryID) == ["old-library"])
        #expect(MockURLProtocol.requests(forHost: env.host).map { $0.url?.path } == ["/api/play/shared", "/api/play/next"])
    }

    @Test("a credential change during a failed request cannot send another library's update")
    func switchDuringFlush() async throws {
        let env = UpdatesStoreTests.makeEnv(host: "play-library-inflight.test")
        defer { try? FileManager.default.removeItem(at: env.fileURL.deletingLastPathComponent()) }
        try env.store.recordWatchPlay(PlayPayload(trackId: "first", libraryID: env.identity))
        try env.store.recordWatchPlay(PlayPayload(trackId: "second", libraryID: env.identity))
        let otherToken = UpdatesStoreTests.token(username: "other")
        let otherID = try #require(LibraryIdentity.make(token: otherToken, baseURL: env.baseURL))
        let switched = DispatchSemaphore(value: 0)
        MockURLProtocol.setHandler(forHost: env.host) { _ in
            Task { @MainActor in
                env.store.configure(token: otherToken, baseURL: env.baseURL)
                LibraryMetadata(defaults: env.defaults).libraryID = otherID
                switched.signal()
            }
            _ = switched.wait(timeout: .now() + 5)
            throw URLError(.notConnectedToInternet)
        }
        env.store.configure(token: UpdatesStoreTests.token(), baseURL: env.baseURL)
        await env.store.flush()
        #expect(env.store.pending.count == 2)
        #expect(MockURLProtocol.requests(forHost: env.host).count == 1)
    }

    @Test("retained watch songs and active queue rows use committed metadata identity through replacement")
    func retainedWatchPlayback() async throws {
        let env = try WatchLibraryDeliveryTests.Env()
        defer { env.cleanUp() }
        let origin = URL(string: "https://play-library-pipeline.test")!
        let identity = try #require(LibraryIdentity.make(token: UpdatesStoreTests.token(), baseURL: origin))
        try await env.phone.replaceLibrary(with: WatchLibraryDeliveryTests.library(count: 2), sourceIdentity: identity)
        let publisher = try env.publisher()
        publisher.publish(identity: identity, playlistIDs: ["p2"])
        await publisher.waitForPublication()
        let files = FileStore(rootURL: env.root.appending(path: "files"))
        try files.write(.music, "m0.mp3", data: PlayerStoreTests.musicBytes)
        let defaults = UserDefaults(suiteName: env.root.lastPathComponent)!
        defer { defaults.removePersistentDomain(forName: env.root.lastPathComponent) }
        let transport = PlayReportQueueTests.Transport()
        transport.activated = false
        let playsURL = env.root.appending(path: "plays.json")
        let plays = PlayReportQueueTests.makeQueue(fileURL: playsURL, transport: transport)
        let services = WatchLibraryServices(database: env.watch, fileStore: files, defaults: defaults,
                                           metadataDirectory: env.inbox, contentDirectory: env.root.appending(path: "content"),
                                           onTrackPlayed: { plays.add($0) })
        defer { services.player.pause() }
        try env.stage(0)
        services.receiver.expect(publisher.head)
        await services.receiver.waitForImport()
        #expect(services.songs.songs.allSatisfy { $0.libraryID == identity })
        services.player.play(services.songs.songs, token: nil, baseURL: nil)
        try await PlayerStoreTests.waitFor { services.player.hasLoadedTrack }

        // new control authority preserves the previously committed browsable library.
        publisher.publish(identity: "other-library", playlistIDs: ["p2"])
        await publisher.waitForPublication()
        services.receiver.expect(publisher.head)
        await services.receiver.waitForImport()
        await services.refresh()
        #expect(services.songs.songs.first?.libraryID == identity)
        services.player.handleTrackEnd()
        services.player.play(services.songs.songs, token: nil, baseURL: nil)
        try await PlayerStoreTests.waitFor { services.player.hasLoadedTrack }

        // commit a replacement while the old row and its file remain protected.
        try await env.phone.replaceLibrary(with: WatchLibraryDeliveryTests.library(count: 2), sourceIdentity: "other-library")
        publisher.publish(identity: "other-library", playlistIDs: ["p2"])
        await publisher.waitForPublication()
        try env.stage(1)
        services.receiver.expect(publisher.head)
        await services.receiver.waitForImport()
        #expect(services.songs.songs.first?.libraryID == "other-library")
        #expect(services.player.song?.libraryID == identity)
        #expect(services.fileCache.isInUse(.music, "m0.mp3"))
        services.player.trackUpdated(try #require(services.songs.songs.first))
        services.player.handleTrackEnd()
        #expect(plays.pending.count == 2)
        #expect(plays.pending.allSatisfy { $0.libraryID == identity })
        let recreated = PlayReportQueueTests.makeQueue(fileURL: playsURL, transport: transport)
        #expect(recreated.pending == plays.pending)
        recreated.acknowledge(PlayPayload(id: plays.pending[0].id, trackId: plays.pending[0].trackId, libraryID: "other-library"))
        #expect(recreated.pending.count == 2)
    }

    @Test("restored rows and inserted history cannot relabel colliding track ids")
    func queueIdentity() throws {
        var old = PlayerStoreTests.song()
        old.libraryID = "a"
        var replacement = old
        replacement.libraryID = "b"
        let queue = PlayQueue(songs: [old])
        let snapshot = try JSONDecoder().decode(PlayQueueSnapshot.self, from: JSONEncoder().encode(queue.snapshot))
        #expect(PlayQueue(snapshot: snapshot, songs: [old.id: replacement]) == nil)
        var restored = try #require(PlayQueue(snapshot: snapshot, songs: [old.id: old]))
        restored.updateSong(replacement)
        #expect(restored.current?.song.libraryID == "a")
        restored.playNext(replacement)
        restored.advance()
        #expect(restored.current?.song.libraryID == "b")
        #expect(restored.history.first?.song.libraryID == "a")
    }
}
