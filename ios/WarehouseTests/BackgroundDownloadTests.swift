import Foundation
import Testing
@testable import Warehouse

@Suite("BackgroundDownload helpers")
struct BackgroundDownloadTests {
    @Test("a request url maps back to its file for both types")
    func urlMapsBackToFile() {
        let base = URL(string: "https://example.test")!
        let music = FileToDownload(type: .music, filename: "abc123.mp3")
        let artwork = FileToDownload(type: .artwork, filename: "def456.jpg")

        #expect(BackgroundDownload.file(fromURL: url(base, music)) == music)
        #expect(BackgroundDownload.file(fromURL: url(base, artwork)) == artwork)
    }

    @Test("filenames with dots survive the round trip through the url")
    func filenamesWithDotsSurvive() {
        let base = URL(string: "https://example.test")!
        let file = FileToDownload(type: .music, filename: "a.name.with.dots.m4a")
        #expect(BackgroundDownload.file(fromURL: url(base, file)) == file)
    }

    @Test("urls that aren't a music or artwork file map to nil")
    func nonFileUrlsMapToNil() {
        #expect(BackgroundDownload.file(fromURL: nil) == nil)
        #expect(BackgroundDownload.file(fromURL: URL(string: "https://example.test")) == nil)
        #expect(BackgroundDownload.file(fromURL: URL(string: "https://example.test/bogus/x.mp3")) == nil)
        #expect(BackgroundDownload.file(fromURL: URL(string: "https://example.test/api/version")) == nil)
    }

    /// builds the same url the downloader requests, so the tests exercise the
    /// exact path structure file(fromURL:) has to parse
    private func url(_ base: URL, _ file: FileToDownload) -> URL {
        base.appendingPathComponent(file.type.directory).appendingPathComponent(file.filename)
    }

    @Test("planning enqueues missing files and adopts in-flight ones")
    func planEnqueuesAndAdopts() {
        let onDisk = FileToDownload(type: .music, filename: "done.mp3")
        let inFlight = FileToDownload(type: .music, filename: "running.mp3")
        let missing1 = FileToDownload(type: .music, filename: "new1.mp3")
        let missing2 = FileToDownload(type: .artwork, filename: "new2.jpg")
        let foreign = FileToDownload(type: .music, filename: "deselected.mp3")

        let plan = BackgroundDownload.plan(
            files: [onDisk, inFlight, missing1, missing2],
            inFlight: [inFlight, foreign],
            isOnDisk: { $0 == onDisk })

        #expect(plan.toEnqueue == [missing1, missing2])
        // the transfer from a previous launch is waited on, not restarted;
        // in-flight files we no longer want are left out entirely
        #expect(plan.adopted == [inFlight])
        #expect(plan.outstanding == [inFlight, missing1, missing2])
    }

    @Test("planning skips in-flight files that already landed on disk")
    func planSkipsLandedInFlightFiles() {
        let landed = FileToDownload(type: .music, filename: "landed.mp3")

        let plan = BackgroundDownload.plan(files: [landed], inFlight: [landed], isOnDisk: { _ in true })

        #expect(plan.toEnqueue.isEmpty)
        #expect(plan.adopted.isEmpty)
        #expect(plan.outstanding.isEmpty)
    }

    @Test("a relaunch with everything already in flight only waits")
    func planWithEverythingInFlightOnlyWaits() {
        let files = [
            FileToDownload(type: .music, filename: "a.mp3"),
            FileToDownload(type: .music, filename: "b.mp3")
        ]

        let plan = BackgroundDownload.plan(files: files, inFlight: Set(files), isOnDisk: { _ in false })

        #expect(plan.toEnqueue.isEmpty)
        #expect(plan.outstanding == Set(files))
    }

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

    @Test("only a 200 that isn't an html error page is acceptable")
    func acceptabilityMatchesFetchFile() {
        let url = URL(string: "https://example.test/music/x.mp3")!
        func response(status: Int, contentType: String) -> HTTPURLResponse {
            HTTPURLResponse(url: url, statusCode: status, httpVersion: nil,
                            headerFields: ["Content-Type": contentType])!
        }

        #expect(BackgroundDownload.isAcceptable(response(status: 200, contentType: "application/octet-stream")))
        #expect(!BackgroundDownload.isAcceptable(response(status: 200, contentType: "text/html")))
        #expect(!BackgroundDownload.isAcceptable(response(status: 404, contentType: "application/octet-stream")))
        #expect(!BackgroundDownload.isAcceptable(nil))
    }
}
