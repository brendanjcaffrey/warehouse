import Foundation

/// a single track play the watch reports to the phone over watch connectivity
struct PlayPayload: Codable, Equatable, Sendable {
    /// a uuid so a queued play can be matched against transfers already
    /// handed to the system after a relaunch
    let id: String
    let trackId: String

    private static let idKey = "id"
    private static let trackIdKey = "trackId"

    init(id: String = UUID().uuidString, trackId: String) {
        self.id = id
        self.trackId = trackId
    }

    init?(dictionary: [String: Any]) {
        guard dictionary["kind"] == nil,
              let id = dictionary[Self.idKey] as? String,
              let trackId = dictionary[Self.trackIdKey] as? String
        else {
            return nil
        }
        self.init(id: id, trackId: trackId)
    }

    func encode() -> [String: Any] {
        [
            Self.idKey: id,
            Self.trackIdKey: trackId
        ]
    }
}

/// confirms that the phone atomically saved the event and its pending update.
struct PlayReceipt: Sendable {
    let play: PlayPayload

    init(_ play: PlayPayload) { self.play = play }

    init?(dictionary: [String: Any]) {
        guard dictionary["kind"] as? String == "watchPlayReceipt",
              let value = dictionary["play"] as? [String: Any],
              let play = PlayPayload(dictionary: value) else { return nil }
        self.play = play
    }

    func encode() -> [String: Any] {
        ["kind": "watchPlayReceipt", "play": play.encode()]
    }
}
