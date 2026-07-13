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

    static func handler(returning data: Data, status: Int = 200) -> (URLRequest) throws -> (HTTPURLResponse, Data) {
        { request in
            let response = HTTPURLResponse(
                url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
            return (response, data)
        }
    }

    /// a token shaped like the server's, valid for a year
    static func validToken(_ username: String = "brendan") -> String {
        JWTTests.make(exp: Date.now.addingTimeInterval(365 * 24 * 60 * 60), payload: ["username": username])
    }

    static func expiredToken() -> String {
        JWTTests.make(exp: Date.now.addingTimeInterval(-60), payload: ["username": "brendan"])
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

        @Test("a non-200 status throws rather than parsing the body")
        func nonOKStatusThrows() async throws {
            MockURLProtocol.reset()
            // a gateway error page must not be read as the server rejecting the token
            MockURLProtocol.requestHandler = AuthTests.handler(
                returning: Data("<html>502 bad gateway</html>".utf8), status: 502)

            let client = AuthClient(session: MockURLProtocol.makeSession())
            await #expect(throws: URLError.self) {
                _ = try await client.verify(token: "tok", baseURL: AuthTests.baseURL)
            }
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

        @Test("a successful login stores the token and authenticates")
        func logInSuccessStoresToken() async throws {
            let store = Self.makeStore()
            MockURLProtocol.requestHandler = AuthTests.handler(returning: try AuthTests.tokenData("tok"))

            let error = await store.logIn(username: "u", password: "p", serverURL: "https://warehouse.example.com")

            #expect(error == nil)
            #expect(store.token == "tok")
            #expect(store.phase == .authenticated)
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

        /// logs in with a stub token so the store has a session to refresh
        static func makeSignedInStore() async throws -> AuthStore {
            let store = Self.makeStore()
            MockURLProtocol.requestHandler = AuthTests.handler(returning: try AuthTests.tokenData("tok"))
            _ = await store.logIn(username: "u", password: "p", serverURL: "https://warehouse.example.com")
            return store
        }

        /// seeds the keychain & server url the way a returning user's device would be,
        /// then builds the store the way a cold launch does
        static func makeRelaunchedStore(token: String) -> AuthStore {
            _ = Self.makeStore()  // clear whatever the host keychain is holding
            UserDefaults.standard.set("https://warehouse.example.com", forKey: "serverURL")
            Keychain.setToken(token)
            MockURLProtocol.reset()
            return AuthStore(session: MockURLProtocol.makeSession())
        }

        @Test("a stored token opens the app without waiting on the network")
        func storedTokenAuthenticatesWithoutARequest() async {
            let store = Self.makeRelaunchedStore(token: AuthTests.validToken())

            // this is the whole point of the refactor: authenticated before any i/o
            #expect(store.phase == .authenticated)
            #expect(MockURLProtocol.requests.isEmpty)

            store.logOut()
        }

        @Test("an expired stored token drops to the login form without a request")
        func expiredStoredTokenIsDiscarded() async {
            let store = Self.makeRelaunchedStore(token: AuthTests.expiredToken())

            #expect(store.phase == .unauthenticated)
            #expect(store.token == nil)
            #expect(MockURLProtocol.requests.isEmpty)
            // the dead token is cleared from the keychain too
            #expect(Keychain.readToken() == nil)
        }

        @Test("a stored token with no server url drops to the login form")
        func storedTokenWithoutServerURLIsDiscarded() async {
            let store = Self.makeStore()
            store.serverURL = ""
            UserDefaults.standard.removeObject(forKey: "serverURL")
            Keychain.setToken(AuthTests.validToken())
            MockURLProtocol.reset()

            // the keychain survives an app reinstall but user defaults doesn't, so a
            // token can outlive its server url. only the login form can set that back
            let reinstalled = AuthStore(session: MockURLProtocol.makeSession())

            #expect(reinstalled.phase == .unauthenticated)
            #expect(MockURLProtocol.requests.isEmpty)
            #expect(Keychain.readToken() == nil)
        }

        @Test("refresh replaces the token with the refreshed one")
        func refreshReplacesToken() async throws {
            let store = try await Self.makeSignedInStore()

            MockURLProtocol.requestHandler = AuthTests.handler(returning: try AuthTests.tokenData("second"))
            await store.refresh()

            #expect(store.token == "second")
            #expect(store.phase == .authenticated)
        }

        @Test("refresh logs out when the server rejects the token")
        func refreshLogsOutOnError() async throws {
            let store = try await Self.makeSignedInStore()

            MockURLProtocol.requestHandler = AuthTests.handler(returning: try AuthTests.errorData("not authenticated"))
            await store.refresh()

            // an explicit rejection is the only thing that ends a session
            #expect(store.token == nil)
            #expect(store.phase == .unauthenticated)
        }

        @Test("refresh keeps the session alive through any network failure", arguments: [
            URLError.Code.notConnectedToInternet,  // airplane mode
            .timedOut,                             // the vpn is off & the host black-holes us
            .secureConnectionFailed,               // captive portal meddling with tls
            .badServerResponse
        ])
        func refreshSurvivesNetworkFailure(code: URLError.Code) async throws {
            let store = try await Self.makeSignedInStore()

            MockURLProtocol.requestHandler = { _ in throw URLError(code) }
            await store.refresh()

            #expect(store.token == "tok")
            #expect(store.phase == .authenticated)
        }

        @Test("refresh keeps the session when the server returns a non-200")
        func refreshSurvivesBadStatus() async throws {
            let store = try await Self.makeSignedInStore()

            // a 502 html error page is not the server rejecting the token
            MockURLProtocol.requestHandler = AuthTests.handler(
                returning: Data("<html>502 bad gateway</html>".utf8), status: 502)
            await store.refresh()

            #expect(store.token == "tok")
            #expect(store.phase == .authenticated)
        }

        @Test("refresh keeps the session on an unreadable response")
        func refreshSurvivesEmptyResponse() async throws {
            let store = try await Self.makeSignedInStore()

            MockURLProtocol.requestHandler = AuthTests.handler(returning: try AuthTests.emptyData())
            await store.refresh()

            #expect(store.token == "tok")
            #expect(store.phase == .authenticated)
        }

        @Test("refresh with no token makes no request")
        func refreshWithoutTokenIsNoOp() async {
            let store = Self.makeStore()
            MockURLProtocol.reset()

            await store.refresh()

            #expect(MockURLProtocol.requests.isEmpty)
        }
    }
}
