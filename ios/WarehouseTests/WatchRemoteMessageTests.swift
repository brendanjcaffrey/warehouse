import Foundation
import Testing
@testable import Warehouse

@Suite("WatchRemoteMessage")
struct WatchRemoteMessageTests {
    static func payload(isPlaying: Bool = true) -> RemotePlaybackPayload {
        RemotePlaybackPayload(
            trackId: "t1", name: "Song", artistName: "Artist", artworkFilename: "a.jpg",
            isPlaying: isPlaying, isShuffled: true, repeatMode: .one)
    }

    @Test("a now playing message round trips through a dictionary")
    func nowPlayingRoundTrip() {
        let message = WatchRemoteMessage.nowPlaying(Self.payload())
        #expect(WatchRemoteMessage(dictionary: message.encode()) == message)
    }

    @Test("a track with no artwork round trips")
    func noArtworkRoundTrip() {
        let message = WatchRemoteMessage.nowPlaying(
            RemotePlaybackPayload(
                trackId: "t1", name: "Song", artistName: "Artist", artworkFilename: nil,
                isPlaying: false))
        #expect(WatchRemoteMessage(dictionary: message.encode()) == message)
    }

    @Test("nothing playing round trips as an empty now playing message")
    func nothingPlayingRoundTrip() {
        let message = WatchRemoteMessage.nowPlaying(nil)
        #expect(WatchRemoteMessage(dictionary: message.encode()) == message)
    }

    @Test("every command round trips")
    func commandRoundTrip() {
        for command in RemoteCommand.allCases {
            let message = WatchRemoteMessage.command(command)
            #expect(WatchRemoteMessage(dictionary: message.encode()) == message)
        }
    }

    @Test("rejects dictionaries that aren't remote messages")
    func rejectsMalformedDictionaries() {
        #expect(WatchRemoteMessage(dictionary: [:]) == nil)
        #expect(WatchRemoteMessage(dictionary: PlayPayload(trackId: "t1").encode()) == nil)
        #expect(WatchRemoteMessage(dictionary: ["remoteKind": "command"]) == nil)
        #expect(WatchRemoteMessage(dictionary: ["remoteKind": "command", "command": "explode"]) == nil)
        #expect(WatchRemoteMessage(dictionary: ["remoteKind": "nowPlaying", "song": ["name": "Song"]]) == nil)
    }

    @Test("a payload from a phone without the mode fields reads as off")
    func missingModesDecodeAsOff() {
        let payload = RemotePlaybackPayload(dictionary: [
            "trackId": "t1", "name": "Song", "artistName": "Artist", "isPlaying": true
        ])
        #expect(payload?.isShuffled == false)
        #expect(payload?.repeatMode == .off)
        #expect(payload?.artworkFilename == nil)
    }
}
