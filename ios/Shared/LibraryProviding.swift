import Foundation

/// how a sync gets its version & library data: straight from the server on
/// the phone, or relayed through the phone on the watch
protocol LibraryProviding: Sendable {
    func fetchVersion(token: String, baseURL: URL) async throws -> LibraryClient.VersionResult
    func fetchLibrary(token: String, baseURL: URL) async throws -> LibraryClient.LibraryResult
}

extension LibraryClient: LibraryProviding {}
