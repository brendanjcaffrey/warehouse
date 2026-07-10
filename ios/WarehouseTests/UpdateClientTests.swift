import Foundation
import SwiftProtobuf
import Testing
@testable import Warehouse

@Suite("UpdateClient")
struct UpdateClientTests {
    static func ok(_ data: Data) -> (URLRequest) throws -> (HTTPURLResponse, Data) {
        { request in
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil,
                headerFields: ["Content-Type": "application/octet-stream"])!
            return (response, data)
        }
    }

    static func baseURL(_ host: String) -> URL {
        URL(string: "https://\(host)")!
    }

    @Test("a play posts to the track's path with no body")
    func sendPostsUpdate() async throws {
        let host = "update-ok.test"
        let data = try OperationResponse.with { $0.success = true }.serializedData()
        MockURLProtocol.setHandler(forHost: host, Self.ok(data))

        let client = UpdateClient(session: MockURLProtocol.makeSession())
        let update = PendingUpdate(kind: .play, trackId: "t1")
        try await client.send(update, token: "tok", baseURL: Self.baseURL(host))

        let request = try #require(MockURLProtocol.requests(forHost: host).first)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.path == "/api/play/t1")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer tok")
        #expect((request.httpBody ?? Data()).isEmpty)
    }

    @Test("send throws when the server rejects the update")
    func sendThrowsOnRejection() async throws {
        let host = "update-rejected.test"
        let data = try OperationResponse.with {
            $0.success = false
            $0.error = "no such track"
        }.serializedData()
        MockURLProtocol.setHandler(forHost: host, Self.ok(data))

        let client = UpdateClient(session: MockURLProtocol.makeSession())
        let update = PendingUpdate(kind: .play, trackId: "t1")
        await #expect(throws: UpdateClient.UpdateError.server("no such track")) {
            try await client.send(update, token: "tok", baseURL: Self.baseURL(host))
        }
    }

    @Test("send passes transport errors through")
    func sendPassesTransportErrors() async throws {
        let host = "update-offline.test"
        MockURLProtocol.setHandler(forHost: host) { _ in
            throw URLError(.notConnectedToInternet)
        }

        let client = UpdateClient(session: MockURLProtocol.makeSession())
        let update = PendingUpdate(kind: .play, trackId: "t1")
        await #expect(throws: Error.self) {
            try await client.send(update, token: "tok", baseURL: Self.baseURL(host))
        }
    }

    static func makeFileStore(host: String) -> FileStore {
        FileStore(rootURL: FileManager.default.temporaryDirectory
            .appending(path: "update-client-tests-\(host)-\(UUID().uuidString)"))
    }

    @Test("a track update posts its fields as a protobuf body")
    func sendsTrackUpdate() async throws {
        let host = "update-track.test"
        let data = try OperationResponse.with { $0.success = true }.serializedData()
        MockURLProtocol.setHandler(forHost: host, Self.ok(data))

        let client = UpdateClient(session: MockURLProtocol.makeSession())
        let update = PendingUpdate(
            kind: .track, trackId: "t1",
            trackUpdate: .with {
                $0.name = "Strong Enough"
                $0.albumArtist = "Various Artists"
            })
        try await client.send(update, token: "tok", baseURL: Self.baseURL(host))

        let request = try #require(MockURLProtocol.requests(forHost: host).first)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.path == "/api/track/t1")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/octet-stream")
        let message = try TrackUpdate(serializedBytes: request.httpBody ?? Data())
        #expect(message.name == "Strong Enough")
        #expect(message.albumArtist == "Various Artists")
        #expect(!message.hasAlbum)
    }

    @Test("an artwork upload posts the local file as a multipart form")
    func sendsArtworkUpload() async throws {
        let host = "update-artwork.test"
        let data = try OperationResponse.with { $0.success = true }.serializedData()
        MockURLProtocol.setHandler(forHost: host, Self.ok(data))

        let fileStore = Self.makeFileStore(host: host)
        let payload = Data([0xff, 0xd8, 0x01, 0x02])
        try fileStore.write(.artwork, "abc123.jpg", data: payload)

        let client = UpdateClient(session: MockURLProtocol.makeSession(), fileStore: fileStore)
        let update = PendingUpdate(kind: .artworkUpload, trackId: "", params: ["filename": "abc123.jpg"])
        try await client.send(update, token: "tok", baseURL: Self.baseURL(host))

        let request = try #require(MockURLProtocol.requests(forHost: host).first)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.path == "/api/artwork")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer tok")

        let contentType = try #require(request.value(forHTTPHeaderField: "Content-Type"))
        let boundary = try #require(contentType.wholeMatch(of: #/multipart/form-data; boundary=(.+)/#)?.1)
        let body = try #require(request.httpBody)
        #expect(body == UpdateClient.multipartBody(
            filename: "abc123.jpg", data: payload, boundary: String(boundary)))
    }

    @Test("an artwork upload with no local file reports it missing")
    func artworkUploadMissingFile() async throws {
        let host = "update-artwork-missing.test"
        let data = try OperationResponse.with { $0.success = true }.serializedData()
        MockURLProtocol.setHandler(forHost: host, Self.ok(data))

        let fileStore = Self.makeFileStore(host: host)
        let client = UpdateClient(session: MockURLProtocol.makeSession(), fileStore: fileStore)
        let update = PendingUpdate(kind: .artworkUpload, trackId: "", params: ["filename": "gone.jpg"])
        await #expect(throws: UpdateClient.UpdateError.missingFile) {
            try await client.send(update, token: "tok", baseURL: Self.baseURL(host))
        }
        #expect(MockURLProtocol.requests(forHost: host).isEmpty)
    }

    @Test("the multipart body has the file field & mime type the server expects")
    func multipartBody() {
        let body = UpdateClient.multipartBody(
            filename: "abc123.jpg", data: Data("img".utf8), boundary: "warehouse-b")
        let expected = "--warehouse-b\r\n"
            + "Content-Disposition: form-data; name=\"file\"; filename=\"abc123.jpg\"\r\n"
            + "Content-Type: image/jpeg\r\n\r\n"
            + "img\r\n--warehouse-b--\r\n"
        #expect(String(data: body, encoding: .utf8) == expected)

        let png = UpdateClient.multipartBody(
            filename: "abc123.png", data: Data(), boundary: "warehouse-b")
        #expect(String(data: png, encoding: .utf8)?.contains("Content-Type: image/png") == true)
    }
}
