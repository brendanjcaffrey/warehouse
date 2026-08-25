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

    @MainActor
    final class ReceivedCommands {
        var commands = [RemoteCommand]()
    }

    static func makeSession(
        played: PlayedTracks,
        commands: ReceivedCommands
    ) -> PhoneWatchSession {
        PhoneWatchSession(
            payload: { WatchPayload(serverURL: "", token: "", playlistIds: []) },
            onPlay: { played.ids.append($0) },
            onCommand: { commands.commands.append($0) })
    }

    @Test("received plays are forwarded to the callback")
    func forwardsReceivedPlaysToTheCallback() async {
        let played = PlayedTracks()
        let session = Self.makeSession(played: played, commands: ReceivedCommands())

        session.receive(userInfo: PlayPayload(trackId: "t1").encode())

        while played.ids.isEmpty { await Task.yield() }
        #expect(played.ids == ["t1"])
    }

    @Test("user info that isn't a play is ignored")
    func ignoresUserInfoThatIsNotAPlay() async {
        let played = PlayedTracks()
        let session = Self.makeSession(played: played, commands: ReceivedCommands())

        session.receive(userInfo: [:])
        session.receive(userInfo: ["id": 7, "trackId": "t1"])
        // a valid play after the junk proves the junk never reached the
        // callback, without racing the ignored calls
        session.receive(userInfo: PlayPayload(trackId: "t2").encode())

        while played.ids.isEmpty { await Task.yield() }
        #expect(played.ids == ["t2"])
    }

    @Test("commands from the watch are forwarded to the callback")
    func forwardsCommandsToTheCallback() async {
        let commands = ReceivedCommands()
        let session = Self.makeSession(played: PlayedTracks(), commands: commands)

        session.receive(message: WatchRemoteMessage.command(.next).encode())

        while commands.commands.isEmpty { await Task.yield() }
        #expect(commands.commands == [.next])
    }

    @Test("a state request isn't handed to the player")
    func ignoresStateRequests() async {
        let commands = ReceivedCommands()
        let session = Self.makeSession(played: PlayedTracks(), commands: commands)

        session.receive(message: WatchRemoteMessage.command(.requestState).encode())
        // a real command after it proves the request never reached the
        // callback, without racing the ignored call
        session.receive(message: WatchRemoteMessage.command(.playPause).encode())

        while commands.commands.isEmpty { await Task.yield() }
        #expect(commands.commands == [.playPause])
    }

    @Test("messages that aren't commands are ignored")
    func ignoresMessagesThatAreNotCommands() async {
        let commands = ReceivedCommands()
        let session = Self.makeSession(played: PlayedTracks(), commands: commands)

        session.receive(message: [:])
        session.receive(message: WatchRemoteMessage.nowPlaying(nil).encode())
        session.receive(message: WatchRemoteMessage.command(.pause).encode())

        while commands.commands.isEmpty { await Task.yield() }
        #expect(commands.commands == [.pause])
    }
}
