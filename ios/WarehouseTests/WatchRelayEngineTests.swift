import Foundation
import Testing
@testable import Warehouse

@Suite("WatchRelayEngine")
@MainActor
struct WatchRelayEngineTests {
    /// stands in for the phone's file store & wc session, the same way
    /// Transport does for the play report queue
    @MainActor
    private final class Harness {
        var onPhone: Set<FileToDownload> = []

        private(set) var transfers: [FileToDownload] = []
        private(set) var outstanding: Set<FileToDownload> = []
        private(set) var results: [FileResultPayload] = []

        private(set) lazy var engine = WatchRelayEngine(
            config: WatchRelayEngine.Config(),
            isOnPhone: { [unowned self] in onPhone.contains($0) },
            transfer: { [unowned self] file in
                transfers.append(file)
                outstanding.insert(file)
            },
            outstandingTransfers: { [unowned self] in outstanding },
            sendResult: { [unowned self] in results.append($0) })

        func finishTransfer(_ file: FileToDownload, error: Error? = nil) {
            outstanding.remove(file)
            engine.transferDidFinish(file: file, error: error)
        }
    }

    private func file(_ name: String, _ type: LibraryFileType = .music) -> FileToDownload {
        FileToDownload(type: type, filename: name)
    }

    @Test("a file on the phone transfers, then resolves its request")
    func onPhoneFileTransfers() {
        let harness = Harness()
        let file = file("a.mp3")
        harness.onPhone = [file]

        harness.engine.handle(FileRequestPayload(id: "r1", files: [file]))

        #expect(harness.transfers == [file])
        #expect(harness.results.isEmpty)

        harness.finishTransfer(file)
        #expect(harness.results == [FileResultPayload(requestId: "r1", failed: [])])
    }

    @Test("a file the phone doesn't have is reported failed right away")
    func missingFileFailsImmediately() {
        let harness = Harness()
        let file = file("b.mp3")

        harness.engine.handle(FileRequestPayload(id: "r1", files: [file]))

        #expect(harness.transfers.isEmpty)
        #expect(harness.results == [FileResultPayload(requestId: "r1", failed: [file])])
    }

    @Test("a mixed request sends what's on the phone and fails the rest")
    func mixedRequestSendsWhatIsThere() {
        let harness = Harness()
        let here = file("here.mp3")
        let missing = file("missing.mp3")
        harness.onPhone = [here]

        harness.engine.handle(FileRequestPayload(id: "r1", files: [here, missing]))

        #expect(harness.transfers == [here])
        #expect(harness.results.isEmpty)

        harness.finishTransfer(here)
        #expect(harness.results == [FileResultPayload(requestId: "r1", failed: [missing])])
    }

    @Test("a failed file can be re-requested once the phone has it")
    func failedFileRecoversOnLaterRequest() {
        let harness = Harness()
        let file = file("later.mp3")

        harness.engine.handle(FileRequestPayload(id: "r1", files: [file]))
        #expect(harness.results == [FileResultPayload(requestId: "r1", failed: [file])])

        // the phone synced its own library in the meantime
        harness.onPhone = [file]
        harness.engine.handle(FileRequestPayload(id: "r2", files: [file]))

        #expect(harness.transfers == [file])
        harness.finishTransfer(file)
        #expect(harness.results.last == FileResultPayload(requestId: "r2", failed: []))
    }

    @Test("only the configured number of transfers stay queued at once")
    func transferWindowIsRespected() {
        let harness = Harness()
        let files = (0..<10).map { file("\($0).mp3") }
        harness.onPhone = Set(files)

        harness.engine.handle(FileRequestPayload(id: "r1", files: files))

        #expect(harness.transfers.count == 8)

        harness.finishTransfer(files[0])
        #expect(harness.transfers.count == 9)
    }

    @Test("a re-sent request is deduped against work already in flight")
    func nudgeIsDeduped() {
        let harness = Harness()
        let files = [file("a.mp3"), file("b.mp3")]
        harness.onPhone = Set(files)

        harness.engine.handle(FileRequestPayload(id: "r1", files: files))
        // the watch re-sends the same missing list under a new request id
        harness.engine.handle(FileRequestPayload(id: "r2", files: files))

        #expect(harness.transfers == files)

        harness.finishTransfer(files[0])
        harness.finishTransfer(files[1])
        // both requests drain from the same two transfers
        #expect(harness.results == [
            FileResultPayload(requestId: "r1", failed: []),
            FileResultPayload(requestId: "r2", failed: [])
        ])
    }

    @Test("a priority request jumps ahead of queued work")
    func priorityJumpsQueue() {
        let harness = Harness()
        let bulk = (0..<10).map { file("bulk\($0).mp3") }
        let urgent = file("urgent.mp3")
        harness.onPhone = Set(bulk + [urgent])

        harness.engine.handle(FileRequestPayload(id: "r1", files: bulk))
        #expect(harness.transfers.count == 8)

        harness.engine.handle(FileRequestPayload(id: "r2", files: [urgent], priority: true))
        // the transfer window is full; the urgent file goes out as soon as a
        // slot frees up, ahead of the queued bulk files
        harness.finishTransfer(bulk[0])
        #expect(harness.transfers.last == urgent)
        #expect(!harness.transfers.contains(bulk[8]))
    }

    @Test("a failed transfer retries, then reports failed")
    func transferFailuresRetryThenReport() {
        let harness = Harness()
        let file = file("c.mp3")
        harness.onPhone = [file]

        harness.engine.handle(FileRequestPayload(id: "r1", files: [file]))

        for _ in 0...BackgroundDownload.retriesPerFile {
            harness.finishTransfer(file, error: URLError(.networkConnectionLost))
        }

        #expect(harness.transfers.count == BackgroundDownload.retriesPerFile + 1)
        #expect(harness.results == [FileResultPayload(requestId: "r1", failed: [file])])
    }

    @Test("cancelAll drops queued work")
    func cancelAllStopsThePipeline() {
        let harness = Harness()
        let files = (0..<10).map { file("\($0).mp3") }
        harness.onPhone = Set(files)

        harness.engine.handle(FileRequestPayload(id: "r1", files: files))
        #expect(harness.transfers.count == 8)
        harness.engine.cancelAll()
        harness.finishTransfer(files[0])

        // the freed slot isn't refilled and no results are emitted
        #expect(harness.transfers.count == 8)
        #expect(harness.results.isEmpty)
    }

    @Test("an empty request resolves immediately")
    func emptyRequestResolvesImmediately() {
        let harness = Harness()

        harness.engine.handle(FileRequestPayload(id: "r1", files: []))

        #expect(harness.results == [FileResultPayload(requestId: "r1", failed: [])])
    }

    @Test("a leftover transfer from an earlier launch resolves a new request")
    func leftoverTransferResolvesRequest() {
        let harness = Harness()
        let file = file("leftover.mp3")
        // the system still owns this transfer from before a relaunch
        harness.onPhone = [file]
        harness.engine.handle(FileRequestPayload(id: "r1", files: [file]))
        harness.engine.handle(FileRequestPayload(id: "r2", files: [file]))

        // no duplicate transfer was queued, and its completion drains both
        #expect(harness.transfers == [file])
        harness.finishTransfer(file)
        #expect(harness.results.count == 2)
    }
}
