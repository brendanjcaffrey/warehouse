import Foundation
import Testing
@testable import Warehouse

@Suite("DownloadProgress")
struct DownloadProgressTests {
    private let files = [
        FileToDownload(type: .music, filename: "m1.mp3"),
        FileToDownload(type: .music, filename: "m2.mp3"),
        FileToDownload(type: .artwork, filename: "a1.jpg")
    ]

    @Test("totals start split by type and the aggregates sum both")
    func totalsSplitByType() {
        let progress = DownloadProgress(files: files)

        #expect(progress.music.total == 2)
        #expect(progress.artwork.total == 1)
        #expect(progress.total == 3)
        #expect(progress.completed == 0)
        #expect(progress.failed == 0)
    }

    @Test("per-type counts roll up into the aggregates and fraction")
    func countsRollUp() {
        var progress = DownloadProgress(files: files)
        progress[.music].completed += 1
        progress[.music].failed += 1
        progress[.artwork].completed += 1

        #expect(progress.music.finished == 2)
        #expect(progress.artwork.finished == 1)
        #expect(progress.completed == 2)
        #expect(progress.failed == 1)
        #expect(progress.finished == 3)
        #expect(progress.fraction == 1.0)
    }

    @Test("an empty progress reports a zero fraction")
    func emptyProgressHasZeroFraction() {
        #expect(DownloadProgress().fraction == 0)
        #expect(DownloadProgress(files: []).total == 0)
    }
}
