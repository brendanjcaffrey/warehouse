import Foundation
import SwiftProtobuf
import Testing
@testable import Warehouse

@Suite("RelayLibraryProvider")
struct RelayLibraryProviderTests {
    private static let anyURL = URL(string: "https://unused.test")!

    private static func makeProvider(
        reachable: Bool = true,
        reply: @escaping @Sendable ([String: Any]) async throws -> [String: Any] = { _ in [:] },
        library: @escaping @Sendable (TimeInterval) async throws -> Data = { _ in Data() }
    ) -> RelayLibraryProvider {
        RelayLibraryProvider(isReachable: { reachable }, sendWithReply: reply, awaitLibrary: library)
    }

    private static func expectOffline(_ body: () async throws -> Void) async {
        do {
            try await body()
            Issue.record("expected an offline error")
        } catch let error as URLError {
            #expect(error.code == .notConnectedToInternet)
        } catch {
            Issue.record("unexpected error \(error)")
        }
    }

    @Test("an unreachable phone reads as offline")
    func unreachablePhoneIsOffline() async {
        let provider = Self.makeProvider(reachable: false)

        await Self.expectOffline {
            _ = try await provider.fetchVersion(token: "t", baseURL: Self.anyURL)
        }
        await Self.expectOffline {
            _ = try await provider.fetchLibrary(token: "t", baseURL: Self.anyURL)
        }
    }

    @Test("a failed send reads as offline")
    func failedSendIsOffline() async {
        let provider = Self.makeProvider(reply: { _ in throw URLError(.timedOut) })

        await Self.expectOffline {
            _ = try await provider.fetchVersion(token: "t", baseURL: Self.anyURL)
        }
    }

    @Test("version replies map onto the client's result cases")
    func versionRepliesMap() async throws {
        let versioned = Self.makeProvider(reply: { _ in VersionReply.updateTimeNs(55).encode() })
        if case .updateTimeNs(let updateTimeNs) = try await versioned.fetchVersion(token: "t", baseURL: Self.anyURL) {
            #expect(updateTimeNs == 55)
        } else {
            Issue.record("expected an updateTimeNs result")
        }

        let errored = Self.makeProvider(reply: { _ in VersionReply.error("boom").encode() })
        if case .error(let message) = try await errored.fetchVersion(token: "t", baseURL: Self.anyURL) {
            #expect(message == "boom")
        } else {
            Issue.record("expected an error result")
        }

        let offline = Self.makeProvider(reply: { _ in VersionReply.offline.encode() })
        await Self.expectOffline {
            _ = try await offline.fetchVersion(token: "t", baseURL: Self.anyURL)
        }
    }

    @Test("an accepted library request parses the arriving proto")
    func libraryArrivalIsParsed() async throws {
        var library = Library()
        library.updateTimeNs = 88
        let data = try library.serializedData()
        let provider = Self.makeProvider(
            reply: { _ in RelayRequest.acceptedReply() },
            library: { _ in data })

        if case .library(let parsed) = try await provider.fetchLibrary(token: "t", baseURL: Self.anyURL) {
            #expect(parsed.updateTimeNs == 88)
        } else {
            Issue.record("expected a library result")
        }
    }

    @Test("a phone-side library failure surfaces as a server error")
    func libraryFailureSurfaces() async throws {
        let provider = Self.makeProvider(
            reply: { _ in RelayRequest.acceptedReply() },
            library: { _ in throw RelayLibraryError.server("db locked") })

        if case .error(let message) = try await provider.fetchLibrary(token: "t", baseURL: Self.anyURL) {
            #expect(message == "db locked")
        } else {
            Issue.record("expected an error result")
        }
    }

    @Test("a library that never arrives times out")
    func libraryTimeoutThrows() async {
        let provider = Self.makeProvider(
            reply: { _ in RelayRequest.acceptedReply() },
            library: { _ in throw RelayLibraryError.timeout })

        do {
            _ = try await provider.fetchLibrary(token: "t", baseURL: Self.anyURL)
            Issue.record("expected a timeout error")
        } catch let error as URLError {
            #expect(error.code == .timedOut)
        } catch {
            Issue.record("unexpected error \(error)")
        }
    }

    @Test("a rejected library request reads as offline")
    func rejectedLibraryRequestIsOffline() async {
        let provider = Self.makeProvider(reply: { _ in [:] })

        await Self.expectOffline {
            _ = try await provider.fetchLibrary(token: "t", baseURL: Self.anyURL)
        }
    }
}
