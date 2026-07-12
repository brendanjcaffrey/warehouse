import Foundation
import Testing
@testable import Warehouse

@Suite("PhoneWatchSession")
@MainActor
struct PhoneWatchSessionTests {
    @MainActor
    final class PlayedTracks {
        var ids = [String]()
    }

    static func makeSession(played: PlayedTracks) -> PhoneWatchSession {
        PhoneWatchSession(
            payload: { WatchPayload(serverURL: "", token: "", playlistIds: []) },
            onPlay: { played.ids.append($0) })
    }

    @Test("received plays are forwarded to the callback")
    func forwardsReceivedPlaysToTheCallback() async {
        let played = PlayedTracks()
        let session = Self.makeSession(played: played)

        session.receive(userInfo: PlayPayload(trackId: "t1").encode())

        while played.ids.isEmpty { await Task.yield() }
        #expect(played.ids == ["t1"])
    }

    @Test("user info that isn't a play is ignored")
    func ignoresUserInfoThatIsNotAPlay() async {
        let played = PlayedTracks()
        let session = Self.makeSession(played: played)

        session.receive(userInfo: [:])
        session.receive(userInfo: ["id": 7, "trackId": "t1"])
        // a valid play after the junk proves the junk never reached the
        // callback, without racing the ignored calls
        session.receive(userInfo: PlayPayload(trackId: "t2").encode())

        while played.ids.isEmpty { await Task.yield() }
        #expect(played.ids == ["t2"])
    }
}
