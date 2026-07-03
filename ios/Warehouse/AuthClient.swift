import Foundation
import SwiftProtobuf

struct AuthClient {
    enum Result {
        case token(String)
        case error(String)
        case empty
    }

    // this can be changed for tests
    var session: URLSession = .shared

    /// POST /api/auth with form-encoded credentials
    func logIn(username: String, password: String, baseURL: URL) async throws -> Result {
        var request = URLRequest(url: baseURL.appendingPathComponent("api/auth"))
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        let body = "username=\(Self.formEncode(username))&password=\(Self.formEncode(password))"
        request.httpBody = Data(body.utf8)

        let (data, _) = try await session.data(for: request)
        return try Self.parse(data)
    }

    /// PUT /api/auth with a bearer token to verify and refresh it
    func verify(token: String, baseURL: URL) async throws -> Result {
        var request = URLRequest(url: baseURL.appendingPathComponent("api/auth"))
        request.httpMethod = "PUT"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let (data, _) = try await session.data(for: request)
        return try Self.parse(data)
    }

    private static func parse(_ data: Data) throws -> Result {
        let response = try AuthResponse(serializedBytes: data)
        switch response.response {
        case .token(let token):
            return .token(token)
        case .error(let error):
            return .error(error)
        case .none:
            return .empty
        }
    }

    private static func formEncode(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
    }
}
