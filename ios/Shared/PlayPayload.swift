import Foundation

/// a single track play the watch reports to the phone over watch connectivity
struct PlayPayload: Codable, Equatable, Sendable {
    /// a uuid so a queued play can be matched against transfers already
    /// handed to the system after a relaunch
    let id: String
    let trackId: String
    /// the source of the played queue row, independent of the latest control head.
    let libraryID: String?

    private static let idKey = "id"
    private static let trackIdKey = "trackId"

    init(id: String = UUID().uuidString, trackId: String, libraryID: String? = nil) {
        self.id = id
        self.trackId = trackId
        self.libraryID = libraryID
    }

    init?(dictionary: [String: Any]) {
        guard dictionary["kind"] == nil,
              let id = dictionary[Self.idKey] as? String,
              let trackId = dictionary[Self.trackIdKey] as? String,
              dictionary["libraryID"] == nil || dictionary["libraryID"] is String
        else {
            return nil
        }
        self.init(id: id, trackId: trackId, libraryID: dictionary["libraryID"] as? String)
    }

    func encode() -> [String: Any] {
        var value: [String: Any] = [
            Self.idKey: id,
            Self.trackIdKey: trackId
        ]
        if let libraryID { value["libraryID"] = libraryID }
        return value
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
