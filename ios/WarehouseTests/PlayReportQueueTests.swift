import Foundation
import Testing
@testable import Warehouse

@Suite("PlayReportQueue")
@MainActor
struct PlayReportQueueTests {
    /// stands in for the watch connectivity session: an activation flag, the
    /// transfers the system already holds & a recorder of hand-offs
    @MainActor
    final class Transport {
        var activated = true
        var outstanding = Set<String>()
        var sent = [PlayPayload]()
    }

    static func tempFileURL() -> URL {
        FileManager.default.temporaryDirectory
            .appending(path: "play-queue-tests-\(UUID().uuidString)")
            .appending(path: "plays.json")
    }

    static func makeQueue(fileURL: URL, transport: Transport) -> PlayReportQueue {
        PlayReportQueue(
            fileURL: fileURL,
            canSend: { transport.activated },
            outstandingIds: { transport.outstanding },
            send: { transport.sent.append($0) })
    }

    static func plays(onDiskAt fileURL: URL) -> [PlayPayload] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        return (try? JSONDecoder().decode([PlayPayload].self, from: data)) ?? []
    }

    @Test("a play is handed off right away once the session is up")
    func sendsAPlayImmediatelyWhenActivated() {
        let fileURL = Self.tempFileURL()
        let transport = Transport()
        let queue = Self.makeQueue(fileURL: fileURL, transport: transport)

        queue.add(trackId: "t1")

        #expect(transport.sent.map(\.trackId) == ["t1"])
        #expect(queue.pending.isEmpty)
        #expect(Self.plays(onDiskAt: fileURL).isEmpty)
    }

    @Test("plays are held on disk until the session activates")
    func holdsPlaysUntilActivation() {
        let fileURL = Self.tempFileURL()
        let transport = Transport()
        transport.activated = false
        let queue = Self.makeQueue(fileURL: fileURL, transport: transport)

        queue.add(trackId: "t1")

        #expect(transport.sent.isEmpty)
        #expect(queue.pending.map(\.trackId) == ["t1"])
        #expect(Self.plays(onDiskAt: fileURL).map(\.trackId) == ["t1"])
    }

    @Test("held plays drain in order on activation")
    func drainsHeldPlaysInOrderOnActivation() {
        let fileURL = Self.tempFileURL()
        let transport = Transport()
        transport.activated = false
        let queue = Self.makeQueue(fileURL: fileURL, transport: transport)
        queue.add(trackId: "t1")
        queue.add(trackId: "t2")
        queue.add(trackId: "t3")

        transport.activated = true
        queue.drain()

        #expect(transport.sent.map(\.trackId) == ["t1", "t2", "t3"])
        #expect(queue.pending.isEmpty)
        #expect(Self.plays(onDiskAt: fileURL).isEmpty)
    }

    @Test("pending plays survive a relaunch")
    func pendingPlaysSurviveRelaunch() {
        let fileURL = Self.tempFileURL()
        let transport = Transport()
        transport.activated = false
        let queue = Self.makeQueue(fileURL: fileURL, transport: transport)
        queue.add(trackId: "t1")
        queue.add(trackId: "t2")

        let relaunchTransport = Transport()
        let relaunched = Self.makeQueue(fileURL: fileURL, transport: relaunchTransport)
        #expect(relaunched.pending == queue.pending)

        relaunched.drain()
        #expect(relaunchTransport.sent.map(\.trackId) == ["t1", "t2"])
    }

    @Test("plays the system already took are not sent twice")
    func skipsPlaysAlreadyHandedToTheSystem() {
        let fileURL = Self.tempFileURL()
        let transport = Transport()
        transport.activated = false
        let queue = Self.makeQueue(fileURL: fileURL, transport: transport)
        queue.add(trackId: "t1")
        queue.add(trackId: "t2")
        let handedOffId = queue.pending[0].id

        let relaunchTransport = Transport()
        relaunchTransport.outstanding = [handedOffId]
        let relaunched = Self.makeQueue(fileURL: fileURL, transport: relaunchTransport)
        relaunched.drain()

        #expect(relaunchTransport.sent.map(\.trackId) == ["t2"])
        #expect(relaunched.pending.isEmpty)
    }

    @Test("a missing or corrupt file loads as an empty queue")
    func loadToleratesAMissingOrCorruptFile() throws {
        let missing = Self.makeQueue(fileURL: Self.tempFileURL(), transport: Transport())
        #expect(missing.pending.isEmpty)

        let fileURL = Self.tempFileURL()
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: fileURL)
        let corrupt = Self.makeQueue(fileURL: fileURL, transport: Transport())
        #expect(corrupt.pending.isEmpty)
    }
}
