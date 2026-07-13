import Foundation
import Testing
@testable import Warehouse

@Suite("PhoneWatchSession")
@MainActor
struct PhoneWatchSessionTests {
    @MainActor
    final class Received {
        var ids = [String]()
        var fileRequests = [FileRequestPayload]()
        var cancels = 0
        var messageReplies = [[String: Any]]()
    }

    static func makeSession(received: Received) -> PhoneWatchSession {
        let session = PhoneWatchSession(
            payload: { WatchPayload(serverURL: "", token: "", playlistIds: []) },
            onPlay: { received.ids.append($0) })
        session.onFileRequest = { received.fileRequests.append($0) }
        session.onCancelFileRequests = { received.cancels += 1 }
        session.onVersionRequest = { .updateTimeNs(77) }
        return session
    }

    @Test("received plays are forwarded to the callback")
    func forwardsReceivedPlaysToTheCallback() async {
        let received = Received()
        let session = Self.makeSession(received: received)

        session.receive(userInfo: PlayPayload(trackId: "t1").encode())

        while received.ids.isEmpty { await Task.yield() }
        #expect(received.ids == ["t1"])
    }

    @Test("user info that isn't a play is ignored")
    func ignoresUserInfoThatIsNotAPlay() async {
        let received = Received()
        let session = Self.makeSession(received: received)

        session.receive(userInfo: [:])
        session.receive(userInfo: ["id": 7, "trackId": "t1"])
        // a valid play after the junk proves the junk never reached the
        // callback, without racing the ignored calls
        session.receive(userInfo: PlayPayload(trackId: "t2").encode())

        while received.ids.isEmpty { await Task.yield() }
        #expect(received.ids == ["t2"])
    }

    @Test("file requests and cancels route to their callbacks")
    func routesFileRequestsAndCancels() async {
        let received = Received()
        let session = Self.makeSession(received: received)
        let request = FileRequestPayload(files: [FileToDownload(type: .music, filename: "a.mp3")])

        session.receive(userInfo: request.encode())
        session.receive(userInfo: RelayRequest.encode(RelayRequest.cancelFileRequests))
        // a play afterwards proves the earlier user infos routed elsewhere
        session.receive(userInfo: PlayPayload(trackId: "t3").encode())

        while received.ids.isEmpty { await Task.yield() }
        #expect(received.fileRequests == [request])
        #expect(received.cancels == 1)
        #expect(received.ids == ["t3"])
    }

    @Test("a version request replies through the injected handler")
    func versionRequestsReply() async {
        let received = Received()
        let session = Self.makeSession(received: received)

        session.receive(message: RelayRequest.encode(RelayRequest.version)) { reply in
            Task { @MainActor in received.messageReplies.append(reply) }
        }

        while received.messageReplies.isEmpty { await Task.yield() }
        #expect(received.messageReplies.count == 1)
        #expect(VersionReply(dictionary: received.messageReplies[0]) == .updateTimeNs(77))
    }

    @Test("a library request is accepted immediately")
    func libraryRequestsAreAccepted() async {
        let received = Received()
        let session = Self.makeSession(received: received)

        session.receive(message: RelayRequest.encode(RelayRequest.library)) { reply in
            Task { @MainActor in received.messageReplies.append(reply) }
        }

        while received.messageReplies.isEmpty { await Task.yield() }
        #expect(RelayRequest.isAccepted(received.messageReplies[0]))
    }

    @Test("an unknown message still gets an empty reply")
    func unknownMessagesGetEmptyReplies() async {
        let received = Received()
        let session = Self.makeSession(received: received)

        session.receive(message: ["type": "mystery"]) { reply in
            Task { @MainActor in received.messageReplies.append(reply) }
        }

        while received.messageReplies.isEmpty { await Task.yield() }
        #expect(received.messageReplies[0].isEmpty)
    }
}
