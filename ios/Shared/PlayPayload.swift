import Foundation

/// a single track play the watch reports to the phone over watch connectivity
struct PlayPayload: Codable, Equatable {
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
        guard let id = dictionary[Self.idKey] as? String,
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
