import Foundation
import Testing
@testable import Warehouse

extension PlayerStoreTests {
    @Test("a track that isn't on disk is streamed from the server")
    @MainActor
    func uncachedTrackStreams() async throws {
        let host = "player-\(UUID().uuidString).example.com"
        let (player, fileStore, baseURL) = Self.makeStreamingPlayer(
            host: host, baseURL: Self.silentBaseURL())

        player.play([Self.song(id: "1")], token: "tok", baseURL: baseURL)
        try await Self.waitFor { player.hasLoadedTrack }

        // the player was pointed at the server, & nothing was downloaded to
        // play it: the whole point is that no transfer runs in this process
        #expect(player.isStreamingCurrentTrack)
        #expect(player.currentItemURL == baseURL.appending(path: "music/1.wav"))
        #expect(!fileStore.exists(.music, "1.wav"))
        #expect(!Self.requested(baseURL, "1.wav"))
    }

    @Test("a cached track still plays off disk rather than streaming")
    @MainActor
    func cachedTrackPlaysFromDisk() async throws {
        let host = "player-\(UUID().uuidString).example.com"
        let (player, fileStore, baseURL) = Self.makeStreamingPlayer(host: host)
        try fileStore.prepare()
        try Self.musicBytes.write(to: fileStore.fileURL(.music, "1.wav"))

        player.play([Self.song(id: "1")], token: "tok", baseURL: baseURL)
        // status is already .ready for a file on disk, so it says nothing
        // about the item having been handed over yet
        try await Self.waitFor { player.hasLoadedTrack }

        #expect(!player.isStreamingCurrentTrack)
        #expect(player.currentItemURL == fileStore.fileURL(.music, "1.wav"))
        #expect(player.status == .ready)
    }

    @Test("a stream that can't reach the server falls through to a cached track")
    @MainActor
    func failedStreamFallsThroughToCache() async throws {
        let host = "player-\(UUID().uuidString).example.com"
        let (player, fileStore, _) = Self.makeStreamingPlayer(host: host)
        try fileStore.prepare()
        // only the third track is on disk; the first two have nowhere to
        // stream from & have to be skipped to reach it
        try Self.musicBytes.write(to: fileStore.fileURL(.music, "3.wav"))

        player.play(Self.songs(3), token: "tok", baseURL: Self.deadBaseURL)
        // the file on disk makes status .ready synchronously, before the item
        // is handed over, so waiting on that would catch the previous track's
        // stream still being the loaded one. the url is not enough on its own
        // either: 3.wav is sitting in the slot behind the failing stream, and
        // the player steps onto a failed item's successor by itself, so only
        // the store dropping the stream says the track has actually started
        try await Self.waitFor {
            player.currentItemURL == fileStore.fileURL(.music, "3.wav") && !player.isStreamingCurrentTrack
        }

        #expect(player.song?.id == "3")
        #expect(player.isPlaying)
        #expect(!player.isStreamingCurrentTrack)
        // a stream failing says nothing about the disk, so the one cached
        // track is still here to be played
        #expect(fileStore.exists(.music, "3.wav"))
    }

    @Test("a queue with nothing to stream & nothing cached gives up")
    @MainActor
    func failedStreamsGiveUp() async throws {
        let host = "player-\(UUID().uuidString).example.com"
        let (player, _, _) = Self.makeStreamingPlayer(host: host)

        player.play(Self.songs(6), token: "tok", baseURL: Self.deadBaseURL)
        try await Self.waitFor { player.status == .unavailable }

        #expect(player.status == .unavailable)
        #expect(!player.isPlaying)
        #expect(!player.hasLoadedTrack)
    }

    @Test("prefetch doesn't run while the app is in the background")
    @MainActor
    func noPrefetchInTheBackground() async throws {
        let host = "player-\(UUID().uuidString).example.com"
        let (player, fileStore, baseURL) = Self.makeStreamingPlayer(host: host)
        try fileStore.prepare()
        // the playing track comes off disk so the test is about the prefetch
        // & not about a stream that has no real server to reach
        try Self.musicBytes.write(to: fileStore.fileURL(.music, "1.wav"))

        player.setForeground(false)
        player.play(Self.songs(2), token: "tok", baseURL: baseURL)
        try await Self.waitFor { player.hasLoadedTrack }
        try await Self.settle()

        // out of sight this would be a download competing with the stream that
        // is actually making sound, for a track that can stream itself
        #expect(player.song?.id == "1")
        #expect(!Self.requested(host, "2.wav"))
        #expect(!fileStore.exists(.music, "2.wav"))
    }

    @Test("coming back to the foreground re-arms the prefetch")
    @MainActor
    func foregroundReArmsThePrefetch() async throws {
        let host = "player-\(UUID().uuidString).example.com"
        let (player, fileStore, baseURL) = Self.makeStreamingPlayer(host: host)
        try fileStore.prepare()
        try Self.musicBytes.write(to: fileStore.fileURL(.music, "1.wav"))

        player.setForeground(false)
        player.play(Self.songs(2), token: "tok", baseURL: baseURL)
        try await Self.waitFor { player.hasLoadedTrack }
        try await Self.settle()
        #expect(!fileStore.exists(.music, "2.wav"))

        player.setForeground(true)
        try await Self.waitFor { fileStore.exists(.music, "2.wav") }

        // back on screen the link isn't being shared with a stream the user is
        // listening to, so the cache fills for the next dead zone
        #expect(fileStore.exists(.music, "2.wav"))
    }

    @Test("the foreground re-arm does nothing when the player is stopped")
    @MainActor
    func foregroundReArmDoesNothingWhenStopped() async throws {
        let host = "player-\(UUID().uuidString).example.com"
        let (player, _, _) = Self.makeStreamingPlayer(host: host)

        player.setForeground(false)
        player.setForeground(true)
        try await Self.settle()

        #expect(MockURLProtocol.requests(forHost: host).isEmpty)
    }

    @Test("a stream is asked to buffer further ahead once it's ready")
    @MainActor
    func readyStreamBuffersAhead() async throws {
        let host = "player-\(UUID().uuidString).example.com"
        let baseURL = try Self.localStreamBaseURL(containing: "1.wav")
        let (player, _, _) = Self.makeStreamingPlayer(host: host, baseURL: baseURL)

        player.play([Self.song(id: "1")], token: "tok", baseURL: baseURL)
        // a stream sits at .fetching until the item is playable, so this is
        // the item having reached .readyToPlay
        try await Self.waitFor { player.status == .ready }

        #expect(player.isStreamingCurrentTrack)
        // a watch that loses the link mid-track keeps playing out of the
        // buffer instead of stopping at once
        #expect(player.forwardBufferDuration == 60)
    }

    @Test("a stream isn't asked to buffer ahead while it's still filling")
    @MainActor
    func fillingStreamDoesNotBufferAhead() async throws {
        let host = "player-\(UUID().uuidString).example.com"
        let (player, _, baseURL) = Self.makeStreamingPlayer(
            host: host, baseURL: Self.silentBaseURL())

        player.play([Self.song(id: "1")], token: "tok", baseURL: baseURL)
        try await Self.waitFor { player.hasLoadedTrack }

        // asking for a minute of slack during the first fill would be
        // competing with the sound the user is waiting on, so the daemon is
        // left to pick until the item can play
        #expect(player.status == .fetching)
        #expect(player.forwardBufferDuration == 0)
    }

    @Test("a track played off disk isn't asked to buffer ahead")
    @MainActor
    func diskTrackDoesNotBufferAhead() async throws {
        let host = "player-\(UUID().uuidString).example.com"
        let (player, fileStore, baseURL) = Self.makeStreamingPlayer(host: host)
        try fileStore.prepare()
        try Self.musicBytes.write(to: fileStore.fileURL(.music, "1.wav"))

        player.play([Self.song(id: "1")], token: "tok", baseURL: baseURL)
        // status is already .ready for a file on disk, so it says nothing
        // about the item having been handed over yet
        try await Self.waitFor { player.hasLoadedTrack }
        try await Self.settle()

        // there is no link to buffer against, & a target here just has the
        // decoder reading further ahead for nothing
        #expect(!player.isStreamingCurrentTrack)
        #expect(player.currentItemURL == fileStore.fileURL(.music, "1.wav"))
        #expect(player.forwardBufferDuration == 0)
    }
}
