import Foundation
import Testing
@testable import Warehouse

@Suite("playback restore")
@MainActor
struct PlaybackRestoreTests {
    static func songs(_ count: Int) -> [Song] {
        PlayerStoreTests.songs(count)
    }

    static func library(_ songs: [Song]) -> [String: Song] {
        Dictionary(songs.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    /// a player holding a queue, as one looks when the app is put away: the
    /// tracks aren't on disk & there's no server, so nothing plays
    static func makeQueued(_ songs: [Song], startingAt index: Int = 0) -> PlayerStore {
        let player = PlayerStoreTests.makePlayer()
        player.play(songs, startingAt: index, token: nil, baseURL: nil)
        return player
    }

    @Test("a player with nothing playing has nothing to save")
    func emptyPlayerHasNoSnapshot() {
        #expect(PlayerStoreTests.makePlayer().snapshot == nil)
    }

    @Test("a snapshot puts the queue, position & modes back")
    func restoresTheQueue() throws {
        let songs = Self.songs(4)
        let player = Self.makeQueued(songs, startingAt: 1)
        player.setRepeatMode(.all)
        let saved = try #require(player.snapshot)
        // nothing ever loaded here, so the playhead goes in by hand
        let snapshot = PlaybackSnapshot(
            queue: saved.queue, repeatMode: saved.repeatMode, currentTime: 30)

        let restored = PlayerStoreTests.makePlayer()
        restored.restore(snapshot, songs: Self.library(songs), token: nil, baseURL: nil)

        #expect(restored.song?.id == "2")
        #expect(restored.queue.upcoming.map(\.song.id) == ["3", "4"])
        #expect(restored.repeatMode == .all)
        #expect(restored.currentTime == 30)
        // put back paused, with nothing loaded & nothing fetched
        #expect(!restored.isPlaying)
        #expect(restored.status == .ready)
        #expect(!restored.hasLoadedTrack)
    }

    @Test("a queue whose tracks have left the library isn't restored")
    func restoreWithoutTheTracks() throws {
        let snapshot = try #require(Self.makeQueued(Self.songs(2)).snapshot)

        let restored = PlayerStoreTests.makePlayer()
        restored.restore(snapshot, songs: [:], token: nil, baseURL: nil)

        #expect(restored.song == nil)
        #expect(restored.snapshot == nil)
    }

    @Test("a restore is ignored once something is queued")
    func restoreDoesNotStompPlayback() throws {
        let songs = Self.songs(4)
        let snapshot = try #require(Self.makeQueued(songs, startingAt: 1).snapshot)

        // a siri intent or a tap can beat the restore to it, & that queue wins
        let player = Self.makeQueued([songs[3]])
        player.restore(snapshot, songs: Self.library(songs), token: nil, baseURL: nil)

        #expect(player.song?.id == "4")
        #expect(player.queue.count == 1)
    }

    @Test("a restored playhead doesn't follow the queue on to another track")
    func newQueueStartsAtTheTop() async throws {
        let songs = Self.songs(2)
        let snapshot = try #require(Self.makeQueued(songs).snapshot)
        let restored = PlaybackSnapshot(
            queue: snapshot.queue, repeatMode: .off, currentTime: 20)

        let (player, fileStore, baseURL) = PlayerStoreTests.makePlayerWithServer(
            host: "restore-new-queue.test")
        player.restore(restored, songs: Self.library(songs), token: "t", baseURL: baseURL)
        #expect(player.currentTime == 20)

        try fileStore.write(.music, "2.wav", data: PlayerStoreTests.musicBytes)
        player.play([songs[1]], token: "t", baseURL: baseURL)
        try await PlayerStoreTests.waitFor { player.status == .ready }
        #expect(player.song?.id == "2")
        #expect(player.currentTime < 1)
    }

    @Test("playing a restored queue picks the track up where it was left")
    func resumesAtTheSavedPosition() async throws {
        let songs = Self.songs(1)
        let snapshot = try #require(Self.makeQueued(songs).snapshot)
        let restored = PlaybackSnapshot(
            queue: snapshot.queue, repeatMode: .off, currentTime: 12)

        let (player, fileStore, baseURL) = PlayerStoreTests.makePlayerWithServer(
            host: "restore-resume.test")
        try fileStore.write(.music, "1.wav", data: PlayerStoreTests.musicBytes)
        player.restore(restored, songs: Self.library(songs), token: "t", baseURL: baseURL)

        player.resume()
        try await PlayerStoreTests.waitFor { player.hasLoadedTrack && player.currentTime > 11 }
        #expect(player.isPlaying)
        #expect(player.currentTime >= 12)
    }

    @Test("scrubbing before playing moves where a restored track starts")
    func scrubBeforeResuming() async throws {
        let songs = Self.songs(1)
        let snapshot = try #require(Self.makeQueued(songs).snapshot)
        let restored = PlaybackSnapshot(
            queue: snapshot.queue, repeatMode: .off, currentTime: 20)

        let (player, fileStore, baseURL) = PlayerStoreTests.makePlayerWithServer(
            host: "restore-scrub.test")
        try fileStore.write(.music, "1.wav", data: PlayerStoreTests.musicBytes)
        player.restore(restored, songs: Self.library(songs), token: "t", baseURL: baseURL)

        player.seek(to: 5)
        player.resume()
        try await PlayerStoreTests.waitFor { player.hasLoadedTrack && player.currentTime > 4 }
        #expect(player.currentTime >= 5)
        #expect(player.currentTime < 10)
    }

    @Test("a saved position past the end of the track starts it over")
    func positionOutsideTheTrack() async throws {
        let songs = Self.songs(1)
        let snapshot = try #require(Self.makeQueued(songs).snapshot)
        // where the queue was left stopped at the end of its last track
        let restored = PlaybackSnapshot(
            queue: snapshot.queue, repeatMode: .off, currentTime: songs[0].duration)

        let (player, fileStore, baseURL) = PlayerStoreTests.makePlayerWithServer(
            host: "restore-past-end.test")
        try fileStore.write(.music, "1.wav", data: PlayerStoreTests.musicBytes)
        player.restore(restored, songs: Self.library(songs), token: "t", baseURL: baseURL)

        player.resume()
        try await PlayerStoreTests.waitFor { player.status == .ready && player.hasLoadedTrack }
        #expect(player.currentTime < 5)
    }
}
