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
        // a rejected filename must degrade to one failed file, not stop the run
        #expect(!BackgroundDownload.isOutOfSpace(FileStore.FilenameError.invalid("../evil.mp3")))
    }
}
