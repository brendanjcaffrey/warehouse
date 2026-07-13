import Foundation
import Testing
@testable import Warehouse

@Suite("Relay payloads")
struct RelayPayloadsTests {
    @Test("a path key round-trips for both file types")
    func pathKeyRoundTrips() {
        let music = FileToDownload(type: .music, filename: "abc123.mp3")
        let artwork = FileToDownload(type: .artwork, filename: "def456.jpg")

        #expect(music.pathKey == "music/abc123.mp3")
        #expect(FileToDownload(pathKey: music.pathKey) == music)
        #expect(FileToDownload(pathKey: artwork.pathKey) == artwork)
    }

    @Test("filenames with dots survive the path key round trip")
    func pathKeyKeepsDots() {
        let file = FileToDownload(type: .music, filename: "a.name.with.dots.m4a")
        #expect(FileToDownload(pathKey: file.pathKey) == file)
    }

    @Test("invalid path keys map to nil")
    func invalidPathKeysRejected() {
        #expect(FileToDownload(pathKey: "") == nil)
        #expect(FileToDownload(pathKey: "music") == nil)
        #expect(FileToDownload(pathKey: "music/") == nil)
        #expect(FileToDownload(pathKey: "bogus/x.mp3") == nil)
    }

    @Test("bare requests encode their type and match it back")
    func bareRequestsMatch() {
        let dictionary = RelayRequest.encode(RelayRequest.version)

        #expect(RelayRequest.matches(dictionary, RelayRequest.version))
        #expect(!RelayRequest.matches(dictionary, RelayRequest.library))
        #expect(!RelayRequest.matches([:], RelayRequest.version))
    }

    @Test("version replies round-trip all three shapes")
    func versionReplyRoundTrips() {
        for reply in [VersionReply.updateTimeNs(1_234), .error("boom"), .offline] {
            #expect(VersionReply(dictionary: reply.encode()) == reply)
        }
        #expect(VersionReply(dictionary: [:]) == nil)
        #expect(VersionReply(dictionary: ["offline": false]) == nil)
    }

    @Test("file requests round-trip and drop junk path keys")
    func fileRequestRoundTrips() {
        let files = [
            FileToDownload(type: .music, filename: "a.mp3"),
            FileToDownload(type: .artwork, filename: "b.jpg")
        ]
        let request = FileRequestPayload(files: files, priority: true)

        let decoded = FileRequestPayload(dictionary: request.encode())
        #expect(decoded == request)

        var withJunk = request.encode()
        withJunk["files"] = ["music/a.mp3", "nope", "artwork/"]
        #expect(FileRequestPayload(dictionary: withJunk)?.files == [files[0]])
    }

    @Test("file requests cap how many files they carry")
    func fileRequestCapsFiles() {
        let files = (0..<(FileRequestPayload.maxFiles + 50)).map {
            FileToDownload(type: .music, filename: "\($0).mp3")
        }

        let request = FileRequestPayload(files: files)

        #expect(request.files.count == FileRequestPayload.maxFiles)
        #expect(request.files == Array(files.prefix(FileRequestPayload.maxFiles)))
    }

    @Test("file requests reject dictionaries of the wrong shape")
    func fileRequestRejectsJunk() {
        #expect(FileRequestPayload(dictionary: [:]) == nil)
        #expect(FileRequestPayload(dictionary: ["type": "fileRequest"]) == nil)
        #expect(FileRequestPayload(dictionary: ["type": "fileResult", "id": "x", "files": [], "priority": false]) == nil)
    }

    @Test("file results round-trip")
    func fileResultRoundTrips() {
        let result = FileResultPayload(
            requestId: "req1", failed: [FileToDownload(type: .music, filename: "x.mp3")])

        #expect(FileResultPayload(dictionary: result.encode()) == result)
        #expect(FileResultPayload(dictionary: [:]) == nil)
    }

    @Test("library results round-trip")
    func libraryResultRoundTrips() {
        let result = LibraryResultPayload(error: "server said no")

        #expect(LibraryResultPayload(dictionary: result.encode()) == result)
        #expect(LibraryResultPayload(dictionary: ["type": "libraryResult"]) == nil)
    }

    @Test("transfer metadata round-trips both kinds")
    func transferMetadataRoundTrips() {
        let library = FileTransferMetadata.library(updateTimeNs: 42)
        let file = FileTransferMetadata.file(FileToDownload(type: .artwork, filename: "c.jpg"))

        #expect(FileTransferMetadata(dictionary: library.encode()) == library)
        #expect(FileTransferMetadata(dictionary: file.encode()) == file)
    }

    @Test("transfer metadata rejects junk")
    func transferMetadataRejectsJunk() {
        #expect(FileTransferMetadata(dictionary: nil) == nil)
        #expect(FileTransferMetadata(dictionary: [:]) == nil)
        #expect(FileTransferMetadata(dictionary: ["kind": "library"]) == nil)
        #expect(FileTransferMetadata(dictionary: ["kind": "file", "fileType": "music", "filename": ""]) == nil)
        #expect(FileTransferMetadata(dictionary: ["kind": "file", "fileType": "bogus", "filename": "a"]) == nil)
    }
}
