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
}
