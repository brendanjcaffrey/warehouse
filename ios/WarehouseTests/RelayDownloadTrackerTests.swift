import Foundation
import Testing
@testable import Warehouse

@Suite("RelayDownloadTracker")
@MainActor
struct RelayDownloadTrackerTests {
    private let music1 = FileToDownload(type: .music, filename: "m1.mp3")
    private let music2 = FileToDownload(type: .music, filename: "m2.mp3")
    private let artwork = FileToDownload(type: .artwork, filename: "a1.jpg")

    private var all: [FileToDownload] { [music1, music2, artwork] }

    @Test("arrivals shrink the missing list until the download completes")
    func arrivalsShrinkMissing() {
        let tracker = RelayDownloadTracker(files: all, isOnDisk: { _ in false })
        #expect(tracker.missing == all)
        #expect(!tracker.isComplete)

        tracker.fileArrived(music1)
        #expect(tracker.missing == [music2, artwork])

        tracker.fileArrived(music2)
        tracker.fileArrived(artwork)
        #expect(tracker.missing.isEmpty)
        #expect(tracker.isComplete)

        let progress = tracker.progress()
        #expect(progress.completed == 3)
        #expect(progress.failed == 0)
        #expect(progress.fraction == 1.0)
    }

    @Test("files already on disk count as arrived from the start")
    func onDiskFilesStartArrived() {
        let tracker = RelayDownloadTracker(files: all, isOnDisk: { $0 == music1 })

        #expect(tracker.missing == [music2, artwork])
        #expect(tracker.progress().completed == 1)
    }

    @Test("phone-reported failures resolve files, but an arrival wins")
    func failuresResolveButArrivalsWin() {
        let tracker = RelayDownloadTracker(files: all, isOnDisk: { _ in false })

        tracker.filesFailed([music1, music2])
        #expect(tracker.missing == [artwork])
        #expect(tracker.progress().failed == 2)

        // the file turned up after the failure report; trust the disk
        tracker.fileArrived(music1)
        #expect(tracker.progress().completed == 1)
        #expect(tracker.progress().failed == 1)

        tracker.fileArrived(artwork)
        #expect(tracker.isComplete)

        // an arrival first also shields against a later failure report
        tracker.filesFailed([artwork])
        #expect(tracker.progress().completed == 2)
    }

    @Test("running out of space completes with the remainder failed")
    func outOfSpaceCompletesWithFailures() {
        let tracker = RelayDownloadTracker(files: all, isOnDisk: { _ in false })
        tracker.fileArrived(music1)

        tracker.markOutOfSpace()

        #expect(tracker.isComplete)
        let progress = tracker.progress()
        #expect(progress.outOfSpace)
        #expect(progress.completed == 1)
        #expect(progress.failed == 2)
    }

    @Test("files that were never asked for are ignored")
    func unknownFilesAreIgnored() {
        let tracker = RelayDownloadTracker(files: [music1], isOnDisk: { _ in false })
        let stranger = FileToDownload(type: .music, filename: "stranger.mp3")

        tracker.fileArrived(stranger)
        tracker.filesFailed([stranger])

        #expect(tracker.missing == [music1])
        #expect(tracker.progress().total == 1)
        #expect(tracker.progress().finished == 0)
    }
}
