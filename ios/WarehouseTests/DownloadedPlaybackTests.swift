import Foundation
import Testing
@testable import Warehouse

extension PlayerStoreTests {
    @Test("downloaded-only playback skips any number of misses without requesting files")
    @MainActor
    func downloadedOnlyQueue() async throws {
        let (player, store, baseURL) = Self.makeStreamingPlayer(host: "offline-\(UUID().uuidString).example.com")
        try store.write(.music, "6.wav", data: Self.musicBytes)
        try store.write(.music, "7.wav", data: Self.musicBytes)
        player.play(Self.songs(7), token: "token", baseURL: baseURL, downloadedOnly: true)
        try await Self.waitFor { player.hasLoadedTrack }
        #expect(player.song?.id == "6")
        #expect(player.queue.upcoming.map(\.song.id) == ["7"])
        #expect(player.currentItemURL == store.fileURL(.music, "6.wav"))
        #expect(player.nextItemURL == store.fileURL(.music, "7.wav"))
        #expect(player.prefetchingFilename == nil)
        #expect(!player.isStreamingCurrentTrack)
        for index in 1...7 { #expect(!Self.requested(baseURL, "\(index).wav")) }
        player.playNext(Self.song(id: "1"), token: "token", baseURL: baseURL)
        #expect(player.queue.upcoming.map(\.song.id) == ["7"])
        player.playShuffled(Self.songs(7), token: nil, baseURL: nil, downloadedOnly: true)
        #expect(Set(player.queue.snapshot.entries.map(\.songID)) == ["6", "7"])
        #expect(player.repeatMode == .all)
        player.handleTrackEnd()
        player.handleTrackEnd()
        try await Self.waitFor { player.hasLoadedTrack }
        #expect(["6", "7"].contains(player.song?.id ?? ""))
        #expect(!player.isStreamingCurrentTrack)
        player.pause()
    }

    @Test("downloaded-only playback suppresses prefetch demand and missing artwork fetches")
    @MainActor
    func downloadedOnlySuppressesNetwork() async throws {
        let store = FileCacheTests.makeStore()
        try store.write(.music, "1.wav", data: Self.musicBytes)
        var artworkRequests = 0
        var demand: [String] = []
        let player = PlayerStore(
            fileStore: store,
            fetchArtwork: { _ in artworkRequests += 1; return false },
            streams: true, activateSessionForTests: { true })
        player.onPrefetchDemand = { demand = $0 }
        player.play([Self.song(id: "1", artwork: "missing.jpg"), Self.song(id: "2")],
                    token: "token", baseURL: Self.deadBaseURL, downloadedOnly: true)
        try await Self.waitFor { player.hasLoadedTrack }
        #expect(artworkRequests == 0)
        #expect(demand.isEmpty)
        player.pause()
    }

    @Test("watch policy cannot be overridden by playback entry points", arguments: [false, true])
    @MainActor
    func watchPolicyIsPermanent(shuffled: Bool) async throws {
        let host = "watch-policy-\(UUID().uuidString).test"
        let store = FileCacheTests.makeStore()
        try store.write(.music, "6.wav", data: Self.musicBytes)
        try store.write(.music, "7.wav", data: Self.musicBytes)
        MockURLProtocol.setHandler(forHost: host) { request in
            (Self.okResponse(request.url!), Self.musicBytes)
        }
        var client = LibraryClient()
        client.session = MockURLProtocol.makeSession()
        var artworkRequests = 0
        var phoneRequests = 0
        var demand: [String] = []
        let generation = UUID()
        let phoneFiles = WatchFileDownloader(fileStore: store, transport: .init(
            isReachable: { true }, currentToken: { "token" }, currentGeneration: { generation },
            request: { _, _, reply in phoneRequests += 1; reply(.unavailable) }, cancel: { _ in }))
        let player = PlayerStore(
            fileStore: store, client: client, prefetchDownloader: phoneFiles,
            fetchArtwork: { _ in artworkRequests += 1; return false },
            streams: true, musicPolicy: .downloadedOnly, activateSessionForTests: { true })
        defer { player.pause() }
        player.onPrefetchDemand = { demand = $0 }
        player.deepPrefetchDepth = 20
        let songs = Self.songs(5) + [Self.song(id: "6", artwork: "missing.jpg"), Self.song(id: "7")]
        let baseURL = URL(string: "https://\(host)")!
        if shuffled {
            player.playShuffled(songs, token: "token", baseURL: baseURL, downloadedOnly: false)
        } else {
            player.play(songs, token: "token", baseURL: baseURL, downloadedOnly: false)
        }
        #expect(player.downloadedOnly)
        #expect(Set(player.queue.snapshot.entries.map(\.songID)) == ["6", "7"])
        try await Self.waitFor { player.hasLoadedTrack }
        player.playNext(Self.song(id: "1"), token: "token", baseURL: baseURL)
        player.playFromHistory(Self.song(id: "2"))
        player.setRepeatMode(.one)
        player.setShuffled(true)
        player.playSelected(songs, startingAt: 5, token: nil, baseURL: nil, downloadedOnly: false)
        #expect(player.song?.id == "6")
        #expect(player.queue.isShuffled)
        #expect(player.repeatMode == .one)
        player.handleTrackEnd()
        #expect(player.song?.id == "6")
        player.setRepeatMode(.all)
        player.skipToNext()
        try await Self.waitFor { player.currentItemURL == store.fileURL(.music, "7.wav") }
        player.skipToNext()
        #expect(player.song?.id == "6")
        player.pause()
        player.resume()
        player.setForeground(false)
        player.setForeground(true)
        player.setCredentials(token: "refreshed", baseURL: baseURL)
        try await Self.settle()
        #expect(player.currentItemURL?.isFileURL == true)
        #expect(!player.isStreamingCurrentTrack)
        #expect(MockURLProtocol.requests(forHost: host).isEmpty)
        #expect(phoneRequests == 0)
        #expect(artworkRequests == 0)
        #expect(demand.isEmpty)
    }

    @Test("watch restores only downloaded rows and keeps modes and valid playheads", arguments: [false, true])
    @MainActor
    func watchRestoresLocalQueue(currentMissing: Bool) async throws {
        let store = FileCacheTests.makeStore()
        try store.write(.music, "6.wav", data: Self.musicBytes)
        try store.write(.music, "7.wav", data: Self.musicBytes)
        var queue = PlayQueue(songs: Self.songs(7), startingAt: currentMissing ? 0 : 5)
        queue.setShuffled(true)
        let snapshot = PlaybackSnapshot(queue: queue.snapshot, repeatMode: .all, currentTime: 60)
        let player = PlayerStore(fileStore: store, musicPolicy: .downloadedOnly, activateSessionForTests: { true })
        defer { player.pause() }
        let songs = Dictionary(uniqueKeysWithValues: Self.songs(7).map { ($0.id, $0) })
        player.restore(snapshot, songs: songs, token: nil, baseURL: nil)
        #expect(Set(player.queue.snapshot.entries.map(\.songID)) == ["6", "7"])
        #expect(player.queue.isShuffled)
        #expect(player.repeatMode == .all)
        #expect(player.currentTime == (currentMissing ? 0 : 60))
        #expect(!player.hasLoadedTrack)
        let current = try #require(player.song)
        player.resume()
        try await Self.waitFor { player.hasLoadedTrack }
        #expect(player.currentItemURL == store.fileURL(.music, current.musicFilename))
        player.setShuffled(false)
        #expect(Set(player.queue.snapshot.entries.map(\.songID)) == ["6", "7"])
    }

    @Test("an all-missing watch list or restored queue cannot start playback")
    @MainActor
    func watchAllMissing() async throws {
        let store = FileCacheTests.makeStore()
        let player = PlayerStore(fileStore: store, musicPolicy: .downloadedOnly, activateSessionForTests: { true })
        defer { player.pause() }
        let songs = Self.songs(7)
        player.play(songs, token: nil, baseURL: nil)
        #expect(player.song == nil)
        player.playShuffled(songs, token: nil, baseURL: nil)
        #expect(player.song == nil)
        player.playSelected(songs, startingAt: 4, token: nil, baseURL: nil)
        #expect(player.song == nil)
        let snapshot = PlaybackSnapshot(queue: PlayQueue(songs: songs).snapshot, repeatMode: .all, currentTime: 60)
        player.restore(snapshot, songs: Dictionary(uniqueKeysWithValues: songs.map { ($0.id, $0) }), token: nil, baseURL: nil)
        #expect(player.song == nil)
        player.resume()
        try await Self.settle()
        #expect(!player.isPlaying)
        #expect(!player.hasLoadedTrack)
    }

    @Test("files removed after queue creation are skipped without a network fallback")
    @MainActor
    func watchSkipsRemovedFiles() async throws {
        let store = FileCacheTests.makeStore()
        for song in Self.songs(7) { try store.write(.music, song.musicFilename, data: Self.musicBytes) }
        let player = PlayerStore(fileStore: store, musicPolicy: .downloadedOnly, activateSessionForTests: { true })
        defer { player.pause() }
        player.play(Self.songs(7), token: nil, baseURL: nil)
        try await Self.waitFor { player.nextItemURL == store.fileURL(.music, "2.wav") }
        for index in 2...6 { try store.delete(.music, "\(index).wav") }
        player.downloadsChanged()
        player.skipToNext()
        try await Self.waitFor { player.currentItemURL == store.fileURL(.music, "7.wav") }
        #expect(player.song?.id == "7")
        #expect(player.queue.snapshot.entries.map(\.songID) == ["1", "7"])
        player.skipToPrevious()
        #expect(player.song?.id == "1")
    }

}
