import Foundation
import Testing

@testable import Warehouse

@MainActor
@Suite("SyncActivityLog")
struct SyncActivityLogTests {
    private final class Clock {
        var now = Date(timeIntervalSince1970: 1_000)
    }

    private let music = FileToDownload(type: .music, filename: "abc.mp3")
    private let other = FileToDownload(type: .music, filename: "def.mp3")

    private func makeLog(
        clock: Clock = Clock(),
        capacity: Int = SyncActivityLog.defaultCapacity,
        names: [String: String] = [:]
    ) -> SyncActivityLog {
        SyncActivityLog(
            now: { clock.now },
            capacity: capacity,
            describe: { SyncActivityFormatting.describe($0, index: names) })
    }

    @Test("events are newest first")
    func newestFirst() {
        let log = makeLog()
        log.startedSync(total: 3)
        log.requestedBundle(type: .music, count: 3)
        log.bundleRegistered()

        #expect(log.events.count == 3)
        #expect(log.events[0].kind == .bundleRegistered)
        #expect(log.events[1].kind == .requestedBundle(type: .music, count: 3))
        #expect(log.events[2].kind == .syncStarted(total: 3))
    }

    @Test("the buffer caps at capacity, dropping the oldest")
    func capsBuffer() {
        let log = makeLog(capacity: 3)
        for count in 1...5 {
            log.requestedBundle(type: .music, count: count)
        }

        #expect(log.events.count == 3)
        #expect(log.events[0].kind == .requestedBundle(type: .music, count: 5))
        #expect(log.events[2].kind == .requestedBundle(type: .music, count: 3))
    }

    @Test("a music bundle names each arrival & adds a summary line")
    func namesMusicArrivals() {
        let clock = Clock()
        let log = makeLog(clock: clock, names: ["abc.mp3": "Karma Police"])
        log.extracted([music, other], type: .music)

        #expect(log.events.count == 3)
        #expect(log.events[0].kind == .bundleExtracted(type: .music, count: 2))
        #expect(log.events[1].kind == .fileReceived(name: "def.mp3"))
        #expect(log.events[2].kind == .fileReceived(name: "Karma Police"))
        #expect(log.lastArrivalAt == clock.now)
    }

    @Test("an artwork bundle is one summary line, not one per file")
    func summarizesArtworkArrivals() {
        let clock = Clock()
        let log = makeLog(clock: clock)
        let files = (0..<40).map { FileToDownload(type: .artwork, filename: "art\($0).jpg") }
        log.extracted(files, type: .artwork)

        #expect(log.events.count == 1)
        #expect(log.events[0].kind == .bundleExtracted(type: .artwork, count: 40))
        #expect(log.lastArrivalAt == clock.now)
    }

    @Test("starting & finishing a sync flips isDownloading")
    func tracksDownloading() {
        let log = makeLog()
        log.startedSync(total: 2)
        #expect(log.isDownloading)

        var progress = DownloadProgress(files: [music, other])
        progress.music.completed = 1
        progress.music.failed = 1
        log.finishedSync(progress)

        #expect(!log.isDownloading)
        #expect(log.events[0].kind == .syncFinished(completed: 1, failed: 1))
    }

    @Test("a sync that ran out of space finishes as out of space")
    func finishesOutOfSpace() {
        let log = makeLog()
        log.startedSync(total: 1)
        var progress = DownloadProgress(files: [music])
        progress.outOfSpace = true
        log.finishedSync(progress)

        #expect(!log.isDownloading)
        #expect(log.events[0].kind == .outOfSpace)
    }

    @Test("a failed bundle records its reason")
    func recordsFailureReason() {
        let log = makeLog()
        log.bundleFailed(reason: "couldn't reach the server")

        #expect(log.events[0].kind == .bundleFailed(reason: "couldn't reach the server"))
        #expect(log.events[0].kind.tone == .warning)
    }

    @Test("clearing empties the feed")
    func clears() {
        let log = makeLog()
        log.receivedLibrary()
        log.extracted([music], type: .music)
        log.clear()

        #expect(log.events.isEmpty)
    }

    @Test("status reports the live interval & download state")
    func reportsStatus() {
        let clock = Clock()
        let log = makeLog(clock: clock)
        log.startedSync(total: 1)
        log.extracted([music], type: .music)

        clock.now += 20
        let status = log.status(now: clock.now)

        #expect(status.sinceLastFile == 20)
        #expect(status.isDownloading)
    }
}
