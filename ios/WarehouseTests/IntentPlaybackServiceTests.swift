import Foundation
import Testing
@testable import Warehouse

@Suite("IntentPlaybackService", .serialized)
@MainActor
struct IntentPlaybackServiceTests {
    struct Harness {
        let service: IntentPlaybackService
        let auth: AuthStore
        let player: PlayerStore
    }

    /// a service backed by an in-memory database seeded with the shared
    /// library fixture & an auth store starting from a clean logged out state
    static func makeHarness(host: String) async throws -> Harness {
        let database = LibraryDatabase(inMemory: true)
        try await database.replaceLibrary(with: LibraryDatabaseTests.makeLibrary())
        let fileStore = FileStore(
            rootURL: FileManager.default.temporaryDirectory
                .appending(path: "intent-service-tests-\(UUID().uuidString)"))
        let suiteName = "IntentPlaybackServiceTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let updates = UpdatesStore(
            fileURL: FileManager.default.temporaryDirectory
                .appending(path: "intent-service-tests-\(UUID().uuidString)")
                .appending(path: "updates.json"),
            session: MockURLProtocol.makeSession(),
            defaults: defaults)
        let auth = AuthStore(session: MockURLProtocol.makeSession())
        auth.logOut()
        let songs = SongsStore(database: database, fileStore: fileStore)
        let playlists = PlaylistsStore(database: database)
        var client = LibraryClient()
        client.session = MockURLProtocol.makeSession()
        let player = PlayerStore(fileStore: fileStore, updates: updates, client: client)
        let service = IntentPlaybackService(auth: auth, songs: songs, playlists: playlists, player: player)
        return Harness(service: service, auth: auth, player: player)
    }

    /// logs the harness in against a stubbed auth endpoint so the store holds
    /// a token without touching the network
    static func logIn(_ harness: Harness, host: String) async throws {
        MockURLProtocol.setHandler(forHost: host) { request in
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, try AuthTests.tokenData("intent-token"))
        }
        let error = await harness.auth.logIn(username: "u", password: "p", serverURL: "https://\(host)")
        #expect(error == nil)
    }

    @Test("prepare throws when nobody is logged in")
    func prepareThrowsLoggedOut() async throws {
        let harness = try await Self.makeHarness(host: "prepare-logged-out.test")

        await #expect(throws: IntentError.loggedOut) {
            try await harness.service.prepare()
        }
    }

    @Test("prepare loads songs & playlists from the database")
    func prepareLoadsLibrary() async throws {
        let host = "prepare-loads.test"
        let harness = try await Self.makeHarness(host: host)
        try await Self.logIn(harness, host: host)

        #expect(harness.service.allSongs.isEmpty)
        try await harness.service.prepare()

        #expect(harness.service.allSongs.count == 2)
        #expect(harness.service.allPlaylists.count == 4)
    }

    @Test("play starts the queue using the stored auth")
    func playStartsQueue() async throws {
        let host = "play-starts.test"
        let harness = try await Self.makeHarness(host: host)
        try await Self.logIn(harness, host: host)
        try await harness.service.prepare()

        let songs = harness.service.allSongs
        harness.service.play(songs, startingAt: 1)

        #expect(harness.player.song?.id == songs[1].id)
        #expect(harness.player.queue.count == 2)
        #expect(harness.player.repeatMode == .off)
    }

    @Test("shuffled play queues every song & repeats the queue")
    func playShuffled() async throws {
        let host = "play-shuffled.test"
        let harness = try await Self.makeHarness(host: host)
        try await Self.logIn(harness, host: host)
        try await harness.service.prepare()

        harness.service.play(harness.service.allSongs, shuffled: true)

        #expect(harness.player.queue.count == 2)
        #expect(harness.player.repeatMode == .all)
    }

    @Test("currentSong mirrors the player")
    func currentSong() async throws {
        let host = "current-song.test"
        let harness = try await Self.makeHarness(host: host)
        try await Self.logIn(harness, host: host)
        try await harness.service.prepare()

        #expect(harness.service.currentSong == nil)
        harness.service.play(harness.service.allSongs)
        #expect(harness.service.currentSong?.id == harness.service.allSongs[0].id)
    }
}
