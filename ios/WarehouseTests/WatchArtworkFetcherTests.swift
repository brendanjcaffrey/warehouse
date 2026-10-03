import Foundation
import Testing
@testable import Warehouse

@Suite("watch local artwork")
@MainActor
struct WatchArtworkFetcherTests {
    @Test("missing artwork stays a placeholder and delivered artwork is read locally")
    func localArtwork() throws {
        let files = FileStore(rootURL: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString))
        defer { try? FileManager.default.removeItem(at: files.rootURL) }
        let artwork = WatchArtworkFetcher(fileStore: files)
        #expect(artwork.artworkURL(nil) == nil)
        #expect(artwork.artworkURL("cover.jpg") == nil)
        try files.write(.artwork, "cover.jpg", data: Data("delivered".utf8))
        #expect(artwork.artworkURL("cover.jpg") == files.fileURL(.artwork, "cover.jpg"))
    }
}
