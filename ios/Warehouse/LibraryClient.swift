import Foundation
import SwiftProtobuf

struct LibraryClient: Sendable {
    enum VersionResult {
        case updateTimeNs(Int64)
        case error(String)
        case empty
    }

    enum LibraryResult {
        case library(Library)
        case error(String)
        case empty
    }

    enum FileError: Error, Equatable {
        case badStatus(Int)
        case notAFile
    }

    // this can be changed for tests
    var session: URLSession = .shared

    /// GET /api/version to check for new library data
    func fetchVersion(token: String, baseURL: URL) async throws -> VersionResult {
        let data = try await get(path: "api/version", token: token, baseURL: baseURL)
        let response = try VersionResponse(serializedBytes: data)
        switch response.response {
        case .updateTimeNs(let updateTimeNs):
            return .updateTimeNs(updateTimeNs)
        case .error(let error):
            return .error(error)
        case .none:
            return .empty
        }
    }

    /// GET /api/library to fetch the entire library
    func fetchLibrary(token: String, baseURL: URL) async throws -> LibraryResult {
        let data = try await get(path: "api/library", token: token, baseURL: baseURL)
        let response = try LibraryResponse(serializedBytes: data)
        switch response.response {
        case .library(let library):
            return .library(library)
        case .error(let error):
            return .error(error)
        case .none:
            return .empty
        }
    }

    /// GET /music/<filename> or /artwork/<filename>
    func fetchFile(_ type: LibraryFileType, filename: String, token: String, baseURL: URL) async throws -> Data {
        let url = baseURL.appendingPathComponent(type.directory).appendingPathComponent(filename)
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse {
            guard http.statusCode == 200 else {
                throw FileError.badStatus(http.statusCode)
            }
            // the server redirects to the web app on auth failures, don't save that as a file
            if http.mimeType == "text/html" {
                throw FileError.notAFile
            }
        }
        return data
    }

    private func get(path: String, token: String, baseURL: URL) async throws -> Data {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, _) = try await session.data(for: request)
        return data
    }
}
