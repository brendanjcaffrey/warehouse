import Foundation
import Testing
@testable import Warehouse

@Suite("BackgroundDownload helpers")
struct BackgroundDownloadTests {
    @Test("out of space errors are recognized, including when nested")
    func outOfSpaceErrorsAreRecognized() {
        let nested = NSError(domain: NSURLErrorDomain, code: NSURLErrorUnknown, userInfo: [
            NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC))
        ])

        #expect(BackgroundDownload.isOutOfSpace(POSIXError(.ENOSPC)))
        #expect(BackgroundDownload.isOutOfSpace(CocoaError(.fileWriteOutOfSpace)))
        #expect(BackgroundDownload.isOutOfSpace(URLError(.cannotWriteToFile)))
        #expect(BackgroundDownload.isOutOfSpace(nested))

        #expect(!BackgroundDownload.isOutOfSpace(nil))
        #expect(!BackgroundDownload.isOutOfSpace(URLError(.notConnectedToInternet)))
        #expect(!BackgroundDownload.isOutOfSpace(URLError(.cancelled)))
        #expect(!BackgroundDownload.isOutOfSpace(CocoaError(.fileWriteNoPermission)))
    }

    @Test("failed downloads retry until their budget runs out")
    func failuresRetryWithinBudget() {
        #expect(BackgroundDownload.shouldRetry(error: URLError(.timedOut), isOnDisk: false, retriesUsed: 0))
        // a task can finish without error yet leave nothing on disk, e.g. a 404
        #expect(BackgroundDownload.shouldRetry(error: nil, isOnDisk: false, retriesUsed: 1))
        #expect(!BackgroundDownload.shouldRetry(
            error: URLError(.timedOut), isOnDisk: false, retriesUsed: BackgroundDownload.retriesPerFile))
    }

    @Test("retries are skipped when they can't help")
    func pointlessRetriesAreSkipped() {
        // the file made it after all
        #expect(!BackgroundDownload.shouldRetry(error: nil, isOnDisk: true, retriesUsed: 0))
        // the transfer was deliberately cancelled
        #expect(!BackgroundDownload.shouldRetry(error: URLError(.cancelled), isOnDisk: false, retriesUsed: 0))
        // the device is out of storage
        #expect(!BackgroundDownload.shouldRetry(error: POSIXError(.ENOSPC), isOnDisk: false, retriesUsed: 0))
        #expect(!BackgroundDownload.shouldRetry(
            error: CocoaError(.fileWriteOutOfSpace), isOnDisk: false, retriesUsed: 0))
    }
}
