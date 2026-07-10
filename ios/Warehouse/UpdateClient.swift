import Foundation
import SwiftProtobuf

/// a change made locally that still needs to be pushed to the server,
/// mirroring the web app's update persister entries
struct PendingUpdate: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable {
        case play
        case track
        /// uploads the artwork file named by params["filename"]; unlike the
        /// other kinds it has no track, so trackId stays empty
        case artworkUpload = "artwork"
    }

    let kind: Kind
    let trackId: String
    /// the filename for artwork uploads; empty for the other kinds
    var params: [String: String] = [:]
    /// the edited fields for track updates; empty for the other kinds
    var trackUpdate = TrackUpdate()

    enum CodingKeys: String, CodingKey {
        case kind = "type"
        case trackId
        case params
        case trackUpdate
    }

    init(
        kind: Kind, trackId: String,
        params: [String: String] = [:], trackUpdate: TrackUpdate = TrackUpdate()
    ) {
        self.kind = kind
        self.trackId = trackId
        self.params = params
        self.trackUpdate = trackUpdate
    }

    // the proto message isn't codable, so it's persisted as its serialized
    // bytes, which json coding stores as base64 & which keeps field presence
    init(from decoder: Swift.Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        kind = try container.decode(Kind.self, forKey: .kind)
        trackId = try container.decode(String.self, forKey: .trackId)
        params = try container.decodeIfPresent([String: String].self, forKey: .params) ?? [:]
        if let data = try container.decodeIfPresent(Data.self, forKey: .trackUpdate) {
            trackUpdate = try TrackUpdate(serializedBytes: data)
        }
    }

    func encode(to encoder: Swift.Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kind, forKey: .kind)
        try container.encode(trackId, forKey: .trackId)
        try container.encode(params, forKey: .params)
        let data = try trackUpdate.serializedData()
        if !data.isEmpty {
            try container.encode(data, forKey: .trackUpdate)
        }
    }
}

struct UpdateClient: Sendable {
    enum UpdateError: Error, Equatable {
        case server(String)
        /// the artwork file to upload is gone from disk, so the update can
        /// never succeed & should be dropped
        case missingFile
    }

    // these can be changed for tests
    var session: URLSession = .shared
    var fileStore = FileStore(rootURL: FileStore.defaultRootURL())

    /// posts the update to the server; throws when the request fails or the
    /// server rejects the update
    func send(_ update: PendingUpdate, token: String, baseURL: URL) async throws {
        let request: URLRequest
        switch update.kind {
        case .play:
            request = Self.playRequest(update, token: token, baseURL: baseURL)
        case .track:
            request = try Self.trackRequest(update, token: token, baseURL: baseURL)
        case .artworkUpload:
            request = try artworkRequest(update, token: token, baseURL: baseURL)
        }

        let (data, _) = try await session.data(for: request)
        let response = try OperationResponse(serializedBytes: data)
        if !response.success {
            throw UpdateError.server(response.error)
        }
    }

    /// POST /api/play/<trackId>; the track id is in the path, so there's no body
    private static func playRequest(_ update: PendingUpdate, token: String, baseURL: URL) -> URLRequest {
        let url = baseURL
            .appendingPathComponent("api")
            .appendingPathComponent("play")
            .appendingPathComponent(update.trackId)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return request
    }

    /// POST /api/track/<trackId> with the edited fields as a protobuf body
    private static func trackRequest(_ update: PendingUpdate, token: String, baseURL: URL) throws -> URLRequest {
        let url = baseURL
            .appendingPathComponent("api")
            .appendingPathComponent("track")
            .appendingPathComponent(update.trackId)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.httpBody = try update.trackUpdate.serializedData()
        return request
    }

    /// POST /api/artwork with the local artwork file as a multipart form,
    /// reading its bytes at send time so retries work offline first
    private func artworkRequest(_ update: PendingUpdate, token: String, baseURL: URL) throws -> URLRequest {
        let filename = update.params["filename"] ?? ""
        guard !filename.isEmpty,
              let data = try? Data(contentsOf: fileStore.fileURL(.artwork, filename)) else {
            throw UpdateError.missingFile
        }

        let url = baseURL
            .appendingPathComponent("api")
            .appendingPathComponent("artwork")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let boundary = "warehouse-\(UUID().uuidString)"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = Self.multipartBody(filename: filename, data: data, boundary: boundary)
        return request
    }

    /// multipart body with the single file field the server expects
    static func multipartBody(filename: String, data: Data, boundary: String) -> Data {
        let mimeType = filename.hasSuffix(".png") ? "image/png" : "image/jpeg"
        var body = Data("--\(boundary)\r\n".utf8)
        body.append(Data("Content-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\r\n".utf8))
        body.append(Data("Content-Type: \(mimeType)\r\n\r\n".utf8))
        body.append(data)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        return body
    }
}
