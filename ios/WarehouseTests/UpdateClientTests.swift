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

    @Test("send posts the update with auth & form headers")
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
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/x-www-form-urlencoded")
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

    @Test("form body sorts & percent encodes params")
    func formBody() {
        let body = UpdateClient.formBody(["b": "2", "a": "hello world&more"])
        #expect(String(data: body, encoding: .utf8) == "a=hello%20world%26more&b=2")
        #expect(UpdateClient.formBody([:]).isEmpty)
    }
}
