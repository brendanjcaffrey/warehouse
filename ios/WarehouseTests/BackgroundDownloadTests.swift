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
