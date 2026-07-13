import Foundation
import SwiftProtobuf
import Testing

@testable import Warehouse

@MainActor
@Suite("WatchLibrarySender")
struct WatchLibrarySenderTests {
    @MainActor
    private final class Harness {
        var credentials: WatchLibrarySender.Credentials? = WatchLibrarySender.Credentials(
            token: "tok", baseURL: URL(string: "https://example.com")!)
        var playlistIds = ["p1"]
        var result: LibraryClient.LibraryResult = .library(LibraryFilterTests.makeLibrary())
        var fetchError: Error?

        /// what the phone handed to the transfer queue
        var spooled: [Library] = []
        var transferred: [FileTransferMetadata] = []
        var errors: [String] = []

        func sender() -> WatchLibrarySender {
            WatchLibrarySender(
                credentials: { self.credentials },
                playlistIds: { self.playlistIds },
                fetchLibrary: { _, _ in
                    if let fetchError = self.fetchError { throw fetchError }
                    return self.result
                },
                spool: { library in
                    self.spooled.append(library)
                    return URL(fileURLWithPath: "/tmp/library-\(self.spooled.count).pb")
                },
                transfer: { _, metadata in self.transferred.append(metadata) },
                sendError: { self.errors.append($0) })
        }
    }

    @Test("the library is trimmed to the selected playlists before it goes over the wire")
    func trimsToSelectedPlaylists() async {
        let harness = Harness()
        harness.playlistIds = ["p1"]

        await harness.sender().send()

        #expect(harness.spooled.count == 1)
        let sent = harness.spooled[0]
        #expect(sent.playlists.map(\.id) == ["p1"])
        #expect(sent.tracks.map(\.id) == ["t1", "t2"])
        #expect(harness.errors.isEmpty)
    }

    @Test("the transfer is tagged with the library's update time")
    func transfersWithUpdateTime() async {
        let harness = Harness()

        await harness.sender().send()

        #expect(harness.transferred == [.library(updateTimeNs: 43)])
    }

    @Test("nothing is trimmed away when every playlist is selected")
    func keepsEverythingSelected() async {
        let harness = Harness()
        harness.playlistIds = ["p1", "p2"]

        await harness.sender().send()

        #expect(harness.spooled[0].playlists.map(\.id) == ["p1", "p2"])
        #expect(harness.spooled[0].tracks.map(\.id) == ["t1", "t2", "t3"])
    }

    @Test("a watch with no playlists selected is sent an empty library, not the whole one")
    func emptySelectionSendsEmptyLibrary() async {
        let harness = Harness()
        harness.playlistIds = []

        await harness.sender().send()

        #expect(harness.spooled[0].playlists.isEmpty)
        #expect(harness.spooled[0].tracks.isEmpty)
    }

    @Test("a logged-out phone reports back instead of transferring")
    func loggedOutReportsError() async {
        let harness = Harness()
        harness.credentials = nil

        await harness.sender().send()

        #expect(harness.errors == ["The phone isn't logged in."])
        #expect(harness.spooled.isEmpty)
        #expect(harness.transferred.isEmpty)
    }

    @Test("a server error is relayed back to the watch")
    func serverErrorIsRelayed() async {
        let harness = Harness()
        harness.result = .error("nope")

        await harness.sender().send()

        #expect(harness.errors == ["nope"])
        #expect(harness.transferred.isEmpty)
    }

    @Test("an empty response is relayed back to the watch")
    func emptyResponseIsRelayed() async {
        let harness = Harness()
        harness.result = .empty

        await harness.sender().send()

        #expect(harness.errors == ["The server returned an empty response."])
        #expect(harness.transferred.isEmpty)
    }

    @Test("a failed fetch is relayed back rather than leaving the watch waiting")
    func fetchFailureIsRelayed() async {
        let harness = Harness()
        harness.fetchError = URLError(.notConnectedToInternet)

        await harness.sender().send()

        #expect(harness.errors.count == 1)
        #expect(harness.transferred.isEmpty)
    }
}
