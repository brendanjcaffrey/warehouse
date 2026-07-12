import Foundation
import Testing
@testable import Warehouse

@Suite("WatchPayload")
struct WatchPayloadTests {
    @Test("round trips through a dictionary")
    func roundTrip() {
        let payload = WatchPayload(serverURL: "https://example.com", token: "tok", playlistIds: ["p1", "p2"])
        #expect(WatchPayload(dictionary: payload.encode()) == payload)
    }

    @Test("rejects dictionaries with missing or mistyped fields")
    func rejectsMalformedDictionaries() {
        #expect(WatchPayload(dictionary: [:]) == nil)
        #expect(WatchPayload(dictionary: ["serverURL": "s", "token": "t"]) == nil)
        #expect(WatchPayload(dictionary: ["serverURL": "s", "token": 7, "playlistIds": ["p"]]) == nil)
        #expect(WatchPayload(dictionary: ["serverURL": "s", "token": "t", "playlistIds": "p"]) == nil)
    }

    @Test("a logged out payload round trips and is not configured")
    func loggedOutPayload() {
        let payload = WatchPayload(serverURL: "", token: "", playlistIds: [])
        let decoded = WatchPayload(dictionary: payload.encode())
        #expect(decoded == payload)
        #expect(decoded?.isConfigured == false)
    }

    @Test("isConfigured requires a server, token and at least one playlist")
    func isConfiguredRequiresEverything() {
        #expect(WatchPayload(serverURL: "s", token: "t", playlistIds: ["p"]).isConfigured)
        #expect(!WatchPayload(serverURL: "", token: "t", playlistIds: ["p"]).isConfigured)
        #expect(!WatchPayload(serverURL: "s", token: "", playlistIds: ["p"]).isConfigured)
        #expect(!WatchPayload(serverURL: "s", token: "t", playlistIds: []).isConfigured)
    }
}
