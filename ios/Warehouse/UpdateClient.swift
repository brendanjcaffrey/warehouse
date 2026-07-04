import Foundation
import SwiftProtobuf

/// a change made locally that still needs to be pushed to the server,
/// mirroring the web app's update persister entries; only plays for now,
/// ratings & track edits come later
struct PendingUpdate: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable {
        case play
    }

    let kind: Kind
    let trackId: String
    /// form fields for updates that carry data (ratings & edits)
    var params: [String: String] = [:]

    enum CodingKeys: String, CodingKey {
        case kind = "type"
        case trackId
        case params
    }
}

struct UpdateClient: Sendable {
    enum UpdateError: Error, Equatable {
        case server(String)
    }

    // this can be changed for tests
    var session: URLSession = .shared

    /// POST /api/<kind>/<trackId> with the params form encoded; throws when
    /// the request fails or the server rejects the update
    func send(_ update: PendingUpdate, token: String, baseURL: URL) async throws {
        let url = baseURL
            .appendingPathComponent("api")
            .appendingPathComponent(update.kind.rawValue)
            .appendingPathComponent(update.trackId)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Self.formBody(update.params)

        let (data, _) = try await session.data(for: request)
        let response = try OperationResponse(serializedBytes: data)
        if !response.success {
            throw UpdateError.server(response.error)
        }
    }

    /// form encodes params sorted by key so the output is deterministic
    static func formBody(_ params: [String: String]) -> Data {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        let pairs = params.sorted { $0.key < $1.key }.map { key, value in
            let encodedKey = key.addingPercentEncoding(withAllowedCharacters: allowed) ?? key
            let encodedValue = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
            return "\(encodedKey)=\(encodedValue)"
        }
        return Data(pairs.joined(separator: "&").utf8)
    }
}
