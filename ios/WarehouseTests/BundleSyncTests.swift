import Foundation
import SwiftProtobuf
import Testing

@testable import Warehouse

@Suite("BundleSync")
struct BundleSyncTests {
    private func music(_ count: Int) -> [FileToDownload] {
        (0..<count).map { FileToDownload(type: .music, filename: "m\($0).mp3") }
    }

    private func artwork(_ count: Int) -> [FileToDownload] {
        (0..<count).map { FileToDownload(type: .artwork, filename: "a\($0).jpg") }
    }

    @Test("a pending bundle downloads before anything registers")
    func pendingBundleDownloadsFirst() {
        let state = BundleSync.State(
            pendingFiles: music(3), pendingBundleId: "abc-123", retriesUsed: 0)

        #expect(BundleSync.nextStep(state: state, isOnDisk: { _ in false })
            == .download(bundleId: "abc-123"))
    }

    @Test("music registers before artwork")
    func musicFirst() {
        let state = BundleSync.State(pendingFiles: artwork(2) + music(2))

        let step = BundleSync.nextStep(state: state, isOnDisk: { _ in false })
        #expect(step == .register(type: .music, filenames: ["m0.mp3", "m1.mp3"]))
    }

    @Test("a chunk caps at 50 music files")
    func capsMusicChunk() {
        let state = BundleSync.State(pendingFiles: music(51))

        guard case .register(let type, let filenames) =
            BundleSync.nextStep(state: state, isOnDisk: { _ in false }) else {
            Issue.record("expected a register step")
            return
        }
        #expect(type == .music)
        #expect(filenames.count == 50)
        #expect(filenames.first == "m0.mp3")
        #expect(filenames.last == "m49.mp3")
    }

    @Test("a chunk caps at 1000 artwork files")
    func capsArtworkChunk() {
        let state = BundleSync.State(pendingFiles: artwork(1001))

        guard case .register(let type, let filenames) =
            BundleSync.nextStep(state: state, isOnDisk: { _ in false }) else {
            Issue.record("expected a register step")
            return
        }
        #expect(type == .artwork)
        #expect(filenames.count == 1000)
    }

    @Test("files already on disk aren't re-requested")
    func skipsFilesOnDisk() {
        let state = BundleSync.State(pendingFiles: music(3))

        let step = BundleSync.nextStep(state: state, isOnDisk: { $0.filename != "m1.mp3" })
        #expect(step == .register(type: .music, filenames: ["m1.mp3"]))
    }

    @Test("everything on disk means the sync is finished")
    func finishesWhenAllOnDisk() {
        let state = BundleSync.State(pendingFiles: music(2) + artwork(2))

        #expect(BundleSync.nextStep(state: state, isOnDisk: { _ in true }) == .finished)
        #expect(BundleSync.nextStep(state: BundleSync.State(), isOnDisk: { _ in false }) == .finished)
    }

    @Test("state round-trips through json")
    func stateRoundTrips() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let state = BundleSync.State(
            pendingFiles: music(2) + artwork(1), pendingBundleId: "abc-123", retriesUsed: 1)

        BundleSync.save(state, to: url)
        #expect(BundleSync.loadState(from: url) == state)
    }

    @Test("loading missing or corrupt state returns nil")
    func loadToleratesGarbage() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        #expect(BundleSync.loadState(from: url) == nil)

        try Data("not json".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(BundleSync.loadState(from: url) == nil)
    }

    @Test("a registration request round-trips through the proto")
    func registrationRequestRoundTrips() throws {
        let data = try BundleSync.registrationRequest(type: .music, filenames: ["a.mp3", "b.mp3"])
        let decoded = try BundleRequest(serializedBytes: data)

        #expect(decoded.type == .music)
        #expect(decoded.filenames == ["a.mp3", "b.mp3"])

        let artworkData = try BundleSync.registrationRequest(type: .artwork, filenames: ["c.jpg"])
        #expect(try BundleRequest(serializedBytes: artworkData).type == .artwork)
    }

    @Test("a bundle id parses out of the response")
    func parsesBundleId() throws {
        var response = BundleResponse()
        response.id = "abc-123"

        #expect(try BundleSync.bundleId(fromResponseData: response.serializedData()) == "abc-123")
    }

    @Test("a server error surfaces as a thrown error")
    func serverErrorThrows() throws {
        var response = BundleResponse()
        response.error = "invalid filename"

        #expect(throws: BundleSync.BundleError.server("invalid filename")) {
            _ = try BundleSync.bundleId(fromResponseData: response.serializedData())
        }
    }

    @Test("an empty response is an error too")
    func emptyResponseThrows() throws {
        let response = BundleResponse()

        #expect(throws: BundleSync.BundleError.emptyResponse) {
            _ = try BundleSync.bundleId(fromResponseData: response.serializedData())
        }
    }
}
