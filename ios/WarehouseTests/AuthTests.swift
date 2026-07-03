import Foundation
import Testing
import SwiftProtobuf
@testable import Warehouse

@Suite(.serialized)
struct AuthTests {
    static func responseData(_ configure: (inout AuthResponse) -> Void) throws -> Data {
        var response = AuthResponse()
        configure(&response)
        return try response.serializedData()
    }

    static func tokenData(_ token: String) throws -> Data {
        try responseData { $0.token = token }
    }

    static func errorData(_ message: String) throws -> Data {
        try responseData { $0.error = message }
    }

    static func emptyData() throws -> Data {
        try responseData { _ in }
    }

    static func handler(returning data: Data) -> (URLRequest) throws -> (HTTPURLResponse, Data) {
        { request in
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, data)
        }
    }

    static let baseURL = URL(string: "https://warehouse.example.com")!

    @Suite("AuthClient")
    struct AuthClientTests {

        @Test("logIn returns the token from a token response")
        func logInReturnsToken() async throws {
            MockURLProtocol.reset()
            MockURLProtocol.requestHandler = AuthTests.handler(returning: try AuthTests.tokenData("abc123"))

            let client = AuthClient(session: MockURLProtocol.makeSession())
            let result = try await client.logIn(username: "u", password: "p", baseURL: AuthTests.baseURL)

            guard case .token(let token) = result else {
                Issue.record("expected .token, got \(result)")
                return
            }
            #expect(token == "abc123")
        }

        @Test("logIn surfaces a server error message")
        func logInReturnsError() async throws {
            MockURLProtocol.reset()
            MockURLProtocol.requestHandler = AuthTests.handler(returning: try AuthTests.errorData("bad creds"))

            let client = AuthClient(session: MockURLProtocol.makeSession())
            let result = try await client.logIn(username: "u", password: "p", baseURL: AuthTests.baseURL)

            guard case .error(let message) = result else {
                Issue.record("expected .error, got \(result)")
                return
            }
            #expect(message == "bad creds")
        }

        @Test("logIn maps an empty response to .empty")
        func logInReturnsEmpty() async throws {
            MockURLProtocol.reset()
            MockURLProtocol.requestHandler = AuthTests.handler(returning: try AuthTests.emptyData())

            let client = AuthClient(session: MockURLProtocol.makeSession())
            let result = try await client.logIn(username: "u", password: "p", baseURL: AuthTests.baseURL)

            guard case .empty = result else {
                Issue.record("expected .empty, got \(result)")
                return
            }
        }

        @Test("logIn POSTs form-encoded credentials to /api/auth")
        func logInSendsFormEncodedBody() async throws {
            MockURLProtocol.reset()
            MockURLProtocol.requestHandler = AuthTests.handler(returning: try AuthTests.tokenData("t"))

            let client = AuthClient(session: MockURLProtocol.makeSession())
            _ = try await client.logIn(username: "a b&c", password: "p@ss/word", baseURL: AuthTests.baseURL)

            let request = try #require(MockURLProtocol.requests.last)
            #expect(request.url?.absoluteString == "https://warehouse.example.com/api/auth")
            #expect(request.httpMethod == "POST")
            #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/x-www-form-urlencoded")

            let body = try #require(request.httpBody.flatMap { String(data: $0, encoding: .utf8) })
            // reserved characters must be percent-encoded
            #expect(body == "username=a%20b%26c&password=p%40ss%2Fword")
        }

        @Test("verify PUTs a bearer token and returns the refreshed token")
        func verifySendsBearerToken() async throws {
            MockURLProtocol.reset()
            MockURLProtocol.requestHandler = AuthTests.handler(returning: try AuthTests.tokenData("refreshed"))

            let client = AuthClient(session: MockURLProtocol.makeSession())
            let result = try await client.verify(token: "old-token", baseURL: AuthTests.baseURL)

            let request = try #require(MockURLProtocol.requests.last)
            #expect(request.httpMethod == "PUT")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer old-token")

            guard case .token(let token) = result else {
                Issue.record("expected .token, got \(result)")
                return
            }
            #expect(token == "refreshed")
        }

        @Test("network failures propagate to the caller")
        func logInPropagatesTransportError() async {
            MockURLProtocol.reset()
            MockURLProtocol.requestHandler = { _ in throw URLError(.notConnectedToInternet) }

            let client = AuthClient(session: MockURLProtocol.makeSession())
            await #expect(throws: URLError.self) {
                _ = try await client.logIn(username: "u", password: "p", baseURL: AuthTests.baseURL)
            }
        }
    }

    @Suite("AuthStore")
    @MainActor
    struct AuthStoreTests {

        /// A store wired to the stub session, starting from a clean auth state.
        static func makeStore() -> AuthStore {
            MockURLProtocol.reset()
            let store = AuthStore(session: MockURLProtocol.makeSession())
            store.logOut()  // clear any token left in the host keychain by a prior test
            return store
        }

        @Test("an empty server URL is rejected before any request")
        func logInRejectsEmptyServerURL() async {
            let store = Self.makeStore()
            let error = await store.logIn(username: "u", password: "p", serverURL: "   ")

            #expect(error == "Please enter a valid server URL.")
            #expect(MockURLProtocol.requests.isEmpty)
            #expect(store.phase == .unauthenticated)
        }

        @Test("a bare host gets an https scheme")
        func logInNormalizesBareHost() async throws {
            let store = Self.makeStore()
            MockURLProtocol.requestHandler = AuthTests.handler(returning: try AuthTests.tokenData("t"))

            _ = await store.logIn(username: "u", password: "p", serverURL: "warehouse.example.com")

            let request = try #require(MockURLProtocol.requests.last)
            #expect(request.url?.absoluteString == "https://warehouse.example.com/api/auth")
        }

        @Test("a successful login stores the token and moves to verifying")
        func logInSuccessStoresToken() async throws {
            let store = Self.makeStore()
            MockURLProtocol.requestHandler = AuthTests.handler(returning: try AuthTests.tokenData("tok"))

            let error = await store.logIn(username: "u", password: "p", serverURL: "https://warehouse.example.com")

            #expect(error == nil)
            #expect(store.token == "tok")
            #expect(store.phase == .verifying)
        }

        @Test("a server error is returned and no token is stored")
        func logInErrorIsReturned() async throws {
            let store = Self.makeStore()
            MockURLProtocol.requestHandler = AuthTests.handler(returning: try AuthTests.errorData("nope"))

            let error = await store.logIn(username: "u", password: "p", serverURL: "https://warehouse.example.com")

            #expect(error == "nope")
            #expect(store.token == nil)
            #expect(store.phase == .unauthenticated)
        }

        @Test("an empty response yields a generic error")
        func logInEmptyYieldsGenericError() async throws {
            let store = Self.makeStore()
            MockURLProtocol.requestHandler = AuthTests.handler(returning: try AuthTests.emptyData())

            let error = await store.logIn(username: "u", password: "p", serverURL: "https://warehouse.example.com")

            #expect(error == "An error occurred while trying to authenticate. Please try again.")
            #expect(store.token == nil)
        }

        @Test("a network failure during login yields a generic error")
        func logInTransportFailureYieldsGenericError() async {
            let store = Self.makeStore()
            MockURLProtocol.requestHandler = { _ in throw URLError(.timedOut) }

            let error = await store.logIn(username: "u", password: "p", serverURL: "https://warehouse.example.com")

            #expect(error == "An error occurred while trying to authenticate. Please try again.")
            #expect(store.token == nil)
        }

        @Test("verify refreshes the token and marks the store verified")
        func verifyRefreshesToken() async throws {
            let store = Self.makeStore()
            MockURLProtocol.requestHandler = AuthTests.handler(returning: try AuthTests.tokenData("first"))
            _ = await store.logIn(username: "u", password: "p", serverURL: "https://warehouse.example.com")

            MockURLProtocol.requestHandler = AuthTests.handler(returning: try AuthTests.tokenData("second"))
            await store.verify()

            #expect(store.token == "second")
            #expect(store.phase == .authenticated)
        }

        @Test("verify logs out when the server rejects the token")
        func verifyLogsOutOnError() async throws {
            let store = Self.makeStore()
            MockURLProtocol.requestHandler = AuthTests.handler(returning: try AuthTests.tokenData("tok"))
            _ = await store.logIn(username: "u", password: "p", serverURL: "https://warehouse.example.com")

            MockURLProtocol.requestHandler = AuthTests.handler(returning: try AuthTests.errorData("expired"))
            await store.verify()

            #expect(store.token == nil)
            #expect(store.phase == .unauthenticated)
        }

        @Test("verify stays authenticated while offline")
        func verifyStaysAuthenticatedOffline() async throws {
            let store = Self.makeStore()
            MockURLProtocol.requestHandler = AuthTests.handler(returning: try AuthTests.tokenData("tok"))
            _ = await store.logIn(username: "u", password: "p", serverURL: "https://warehouse.example.com")

            MockURLProtocol.requestHandler = { _ in throw URLError(.notConnectedToInternet) }
            await store.verify()

            // Offline verification keeps the user signed in rather than logging out.
            #expect(store.token == "tok")
            #expect(store.phase == .authenticated)
            #expect(store.verifyError == nil)
        }

        @Test("verify reports an error on an unexpected transport failure")
        func verifyReportsUnexpectedError() async throws {
            let store = Self.makeStore()
            MockURLProtocol.requestHandler = AuthTests.handler(returning: try AuthTests.tokenData("tok"))
            _ = await store.logIn(username: "u", password: "p", serverURL: "https://warehouse.example.com")

            MockURLProtocol.requestHandler = { _ in throw URLError(.badServerResponse) }
            await store.verify()

            // a non-offline error surfaces a message but keeps the token so the user can retry
            #expect(store.verifyError == "An error occurred while trying to verify authentication.")
            #expect(store.token == "tok")
        }

        @Test("verify with no token makes no request")
        func verifyWithoutTokenIsNoOp() async {
            let store = Self.makeStore()
            MockURLProtocol.reset()

            await store.verify()

            #expect(MockURLProtocol.requests.isEmpty)
        }
    }
}
