import Foundation
import Testing
@testable import Warehouse

@Suite("PlayPayload")
struct PlayPayloadTests {
    @Test("round trips through a dictionary")
    func roundTrip() {
        let payload = PlayPayload(id: "abc", trackId: "t1")
        #expect(PlayPayload(dictionary: payload.encode()) == payload)
    }

    @Test("rejects dictionaries with missing or mistyped fields")
    func rejectsMalformedDictionaries() {
        #expect(PlayPayload(dictionary: [:]) == nil)
        #expect(PlayPayload(dictionary: ["id": "abc"]) == nil)
        #expect(PlayPayload(dictionary: ["trackId": "t1"]) == nil)
        #expect(PlayPayload(dictionary: ["id": 7, "trackId": "t1"]) == nil)
        #expect(PlayPayload(dictionary: ["id": "abc", "trackId": 7]) == nil)
    }

    @Test("generated ids are unique")
    func defaultIdsAreUnique() {
        let first = PlayPayload(trackId: "t1")
        let second = PlayPayload(trackId: "t1")
        #expect(!first.id.isEmpty)
        #expect(first.id != second.id)
    }

    @Test("round trips through json for disk persistence")
    func codableRoundTrip() throws {
        let payloads = [PlayPayload(trackId: "t1"), PlayPayload(trackId: "t2")]
        let data = try JSONEncoder().encode(payloads)
        #expect(try JSONDecoder().decode([PlayPayload].self, from: data) == payloads)
    }
}
