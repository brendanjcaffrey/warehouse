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
        log.requested(count: 3, reason: .initial)
        log.received(music)

        #expect(log.events.count == 3)
        #expect(log.events[0].kind == .fileReceived(name: "abc.mp3"))
        #expect(log.events[1].kind == .requestedFiles(count: 3))
        #expect(log.events[2].kind == .syncStarted(total: 3))
    }

    @Test("the buffer caps at capacity, dropping the oldest")
    func capsBuffer() {
        let log = makeLog(capacity: 3)
        for count in 1...5 {
            log.requested(count: count, reason: .initial)
        }

        #expect(log.events.count == 3)
        #expect(log.events[0].kind == .requestedFiles(count: 5))
        #expect(log.events[2].kind == .requestedFiles(count: 3))
    }

    @Test("an arrival is named through describe & marks the last activity")
    func namesArrivals() {
        let clock = Clock()
        let log = makeLog(clock: clock, names: ["abc.mp3": "Karma Police"])
        log.received(music)

        #expect(log.events[0].kind == .fileReceived(name: "Karma Police"))
        #expect(log.lastArrivalAt == clock.now)
    }

    @Test("an unknown filename falls back to the filename itself")
    func fallsBackToFilename() {
        let log = makeLog(names: ["zzz.mp3": "Something Else"])
        log.received(music)

        #expect(log.events[0].kind == .fileReceived(name: "abc.mp3"))
    }

    @Test("reachability is recorded only when it changes")
    func recordsReachabilityTransitionsOnly() {
        let log = makeLog()
        log.phoneReachabilityChanged(to: true)
        log.phoneReachabilityChanged(to: true)
        log.phoneReachabilityChanged(to: false)

        #expect(log.isPhoneReachable == false)
        #expect(log.events.count == 2)
        #expect(log.events[0].kind == .phoneReachable(false))
        #expect(log.events[1].kind == .phoneReachable(true))
    }

    @Test("a request stamps the time & names the reason")
    func recordsRequestReasons() {
        let clock = Clock()
        let log = makeLog(clock: clock)
        log.requested(count: 2, reason: .nudge)
        #expect(log.events[0].kind == .nudgedPhone(count: 2))
        #expect(log.lastRequestAt == clock.now)

        log.requested(count: 1, reason: .background)
        #expect(log.events[0].kind == .backgroundNudge(count: 1))
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

    @Test("a batch of failures is one line, not one per file")
    func batchesFailures() {
        let log = makeLog()
        log.failed([music, other, FileToDownload(type: .artwork, filename: "art.jpg")])

        #expect(log.events.count == 1)
        #expect(log.events[0].kind == .filesFailed(count: 3))
    }

    @Test("a batch of one names the file & an empty batch records nothing")
    func batchOfOne() {
        let log = makeLog(names: ["abc.mp3": "Karma Police"])
        log.failed([])
        #expect(log.events.isEmpty)

        log.failed([music])
        #expect(log.events.count == 1)
        #expect(log.events[0].kind == .fileFailed(name: "Karma Police"))
    }

    @Test("clearing empties the feed but keeps the connection state")
    func clears() {
        let log = makeLog()
        log.phoneReachabilityChanged(to: true)
        log.received(music)
        log.clear()

        #expect(log.events.isEmpty)
        #expect(log.isPhoneReachable)
    }

    @Test("status reports reachability & both live intervals")
    func reportsStatus() {
        let clock = Clock()
        let log = makeLog(clock: clock)
        log.phoneReachabilityChanged(to: true)
        log.startedSync(total: 1)
        log.requested(count: 1, reason: .initial)
        log.received(music)

        clock.now += 20
        let status = log.status(now: clock.now)

        #expect(status.isPhoneReachable)
        #expect(status.sinceLastFile == 20)
        #expect(status.untilNextNudge == RelayTiming.nudgeInterval - 20)
    }
}
