import Foundation
import SwiftProtobuf
import Testing
@testable import Warehouse

@Suite("LibraryClient")
struct LibraryClientTests {
    static func ok(_ data: Data, contentType: String = "application/octet-stream") -> (URLRequest) throws -> (HTTPURLResponse, Data) {
        { request in
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil,
                headerFields: ["Content-Type": contentType])!
            return (response, data)
        }
    }

    static func baseURL(_ host: String) -> URL {
        URL(string: "https://\(host)")!
    }

    @Test("fetchVersion parses the update time and sends the bearer token")
    func fetchVersionParsesUpdateTime() async throws {
        let host = "version-ok.test"
        let data = try VersionResponse.with { $0.updateTimeNs = 12345 }.serializedData()
        MockURLProtocol.setHandler(forHost: host, Self.ok(data))

        let client = LibraryClient(session: MockURLProtocol.makeSession())
        let result = try await client.fetchVersion(token: "tok", baseURL: Self.baseURL(host))

        guard case .updateTimeNs(let updateTimeNs) = result else {
            Issue.record("expected .updateTimeNs, got \(result)")
            return
        }
        #expect(updateTimeNs == 12345)

        let request = try #require(MockURLProtocol.requests(forHost: host).first)
        #expect(request.url?.path == "/api/version")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer tok")
    }

    @Test("fetchVersion surfaces a server error message")
    func fetchVersionParsesError() async throws {
        let host = "version-error.test"
        let data = try VersionResponse.with { $0.error = "nope" }.serializedData()
        MockURLProtocol.setHandler(forHost: host, Self.ok(data))

        let client = LibraryClient(session: MockURLProtocol.makeSession())
        let result = try await client.fetchVersion(token: "tok", baseURL: Self.baseURL(host))

        guard case .error(let message) = result else {
            Issue.record("expected .error, got \(result)")
            return
        }
        #expect(message == "nope")
    }

    @Test("fetchLibrary parses the library payload")
    func fetchLibraryParsesLibrary() async throws {
        let host = "library-ok.test"
        var library = Library()
        library.updateTimeNs = 7
        var track = Track()
        track.id = "t1"
        library.tracks = [track]
        let data = try LibraryResponse.with { $0.library = library }.serializedData()
        MockURLProtocol.setHandler(forHost: host, Self.ok(data))

        let client = LibraryClient(session: MockURLProtocol.makeSession())
        let result = try await client.fetchLibrary(token: "tok", baseURL: Self.baseURL(host))

        guard case .library(let parsed) = result else {
            Issue.record("expected .library, got \(result)")
            return
        }
        #expect(parsed.updateTimeNs == 7)
        #expect(parsed.tracks.map(\.id) == ["t1"])
        #expect(MockURLProtocol.requests(forHost: host).first?.url?.path == "/api/library")
    }

    @Test("fetchLibrary with playlist ids posts a LibraryRequest")
    func fetchLibraryPostsPlaylistIds() async throws {
        let host = "library-filtered.test"
        let data = try LibraryResponse.with { $0.library = Library() }.serializedData()
        MockURLProtocol.setHandler(forHost: host, Self.ok(data))

        let client = LibraryClient(session: MockURLProtocol.makeSession())
        let result = try await client.fetchLibrary(
            token: "tok", baseURL: Self.baseURL(host), playlistIds: ["p1", "p2"])

        guard case .library = result else {
            Issue.record("expected .library, got \(result)")
            return
        }
        let request = try #require(MockURLProtocol.requests(forHost: host).first)
        #expect(request.url?.path == "/api/library")
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/octet-stream")
        let body = try #require(SyncStoreTests.body(of: request))
        #expect(try LibraryRequest(serializedBytes: body).playlistIds == ["p1", "p2"])
    }

    @Test("fetchFile returns the file bytes and hits the right path")
    func fetchFileReturnsData() async throws {
        let host = "file-ok.test"
        let bytes = Data("music bytes".utf8)
        MockURLProtocol.setHandler(forHost: host, Self.ok(bytes, contentType: "audio/mpeg"))

        let client = LibraryClient(session: MockURLProtocol.makeSession())
        let data = try await client.fetchFile(.music, filename: "abc.mp3", token: "tok", baseURL: Self.baseURL(host))

        #expect(data == bytes)
        let request = try #require(MockURLProtocol.requests(forHost: host).first)
        #expect(request.url?.path == "/music/abc.mp3")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer tok")
    }

    @Test("fetchFile throws on a non-200 status")
    func fetchFileThrowsOnBadStatus() async throws {
        let host = "file-404.test"
        MockURLProtocol.setHandler(forHost: host) { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!
            return (response, Data())
        }

        let client = LibraryClient(session: MockURLProtocol.makeSession())
        await #expect(throws: LibraryClient.FileError.badStatus(404)) {
            try await client.fetchFile(.artwork, filename: "abc.jpg", token: "tok", baseURL: Self.baseURL(host))
        }
    }

    @Test("fetchFile rejects an html response from an auth redirect")
    func fetchFileRejectsHTML() async throws {
        let host = "file-html.test"
        MockURLProtocol.setHandler(forHost: host, Self.ok(Data("<html></html>".utf8), contentType: "text/html"))

        let client = LibraryClient(session: MockURLProtocol.makeSession())
        await #expect(throws: LibraryClient.FileError.notAFile) {
            try await client.fetchFile(.music, filename: "abc.mp3", token: "tok", baseURL: Self.baseURL(host))
        }
    }
}
