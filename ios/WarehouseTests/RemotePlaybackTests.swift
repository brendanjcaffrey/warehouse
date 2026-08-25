import Foundation
import Testing
@testable import Warehouse

@Suite("RemotePlayback")
@MainActor
struct RemotePlaybackTests {
    @Test("the payload describes what the player is playing")
    func payloadFromPlayer() {
        let player = PlayerStoreTests.makePlayer()
        #expect(RemotePlaybackPayload(player: player) == nil)

        player.play(
            [PlayerStoreTests.song(id: "t1", name: "Believe", artist: "Cher", artwork: "a.jpg")],
            token: nil, baseURL: nil)
        player.cycleRepeatMode()

        let payload = RemotePlaybackPayload(player: player)
        #expect(payload?.trackId == "t1")
        #expect(payload?.name == "Believe")
        #expect(payload?.artistName == "Cher")
        #expect(payload?.artworkFilename == "a.jpg")
        #expect(payload?.isShuffled == false)
        #expect(payload?.repeatMode == .all)
    }

    @Test("commands from the watch drive the phone's player")
    func commandsDriveThePlayer() {
        let player = PlayerStoreTests.makePlayer()
        player.play(PlayerStoreTests.songs(3), token: nil, baseURL: nil)

        player.apply(.toggleShuffle)
        #expect(player.queue.isShuffled)
        player.apply(.toggleShuffle)
        #expect(!player.queue.isShuffled)

        player.apply(.cycleRepeat)
        #expect(player.repeatMode == .all)

        player.apply(.next)
        #expect(player.song?.id == "2")
        player.apply(.previous)
        #expect(player.song?.id == "1")
    }

    @Test("a state request leaves the player alone")
    func requestStateChangesNothing() {
        let player = PlayerStoreTests.makePlayer()
        player.play(PlayerStoreTests.songs(2), token: nil, baseURL: nil)

        player.apply(.requestState)

        #expect(player.song?.id == "1")
        #expect(player.repeatMode == .off)
    }
}
