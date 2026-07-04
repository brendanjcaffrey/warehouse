import Foundation
import SwiftProtobuf
import Testing
@testable import Warehouse

@Suite("UpdatesStore")
@MainActor
struct UpdatesStoreTests {
    struct Env {
        let store: UpdatesStore
        let fileURL: URL
        let defaults: UserDefaults
        let baseURL: URL
        let host: String
    }

    /// tracks whether the first request already failed, shared with the
    /// mock handler which runs off the main actor
    final class FailOnce: @unchecked Sendable {
        private let lock = NSLock()
        private var failed = false

        func shouldFail() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            if failed { return false }
            failed = true
            return true
        }
    }

    static func makeEnv(
        host: String,
        synced: Bool = true,
        trackUserChanges: Bool = true,
        retryInterval: TimeInterval = 30
    ) -> Env {
        let suiteName = "UpdatesStoreTests-\(host)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)

        let metadata = LibraryMetadata(defaults: defaults)
        if synced {
            metadata.updateTimeNs = 42
            metadata.trackUserChanges = trackUserChanges
        }

        let fileURL = FileManager.default.temporaryDirectory
            .appending(path: "updates-tests-\(host)-\(UUID().uuidString)")
            .appending(path: "updates.json")
        let store = UpdatesStore(
            fileURL: fileURL,
            session: MockURLProtocol.makeSession(),
            defaults: defaults,
            retryInterval: retryInterval)
        return Env(
            store: store, fileURL: fileURL, defaults: defaults,
            baseURL: URL(string: "https://\(host)")!, host: host)
    }

    /// a second store on the same file & defaults, as if the app relaunched
    static func relaunch(_ env: Env) -> UpdatesStore {
        UpdatesStore(
            fileURL: env.fileURL,
            session: MockURLProtocol.makeSession(),
            defaults: env.defaults)
    }

    static func installHandler(host: String, success: Bool = true, failingPaths: Set<String> = []) throws {
        let body = try OperationResponse.with {
            $0.success = success
            if !success { $0.error = "rejected" }
        }.serializedData()

        MockURLProtocol.setHandler(forHost: host) { request in
            if failingPaths.contains(request.url?.path ?? "") {
                throw URLError(.notConnectedToInternet)
            }
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil,
                headerFields: ["Content-Type": "application/octet-stream"])!
            return (response, body)
        }
    }

    static func persisted(at fileURL: URL) -> [PendingUpdate] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        return (try? JSONDecoder().decode([PendingUpdate].self, from: data)) ?? []
    }

    @Test("a play posts to the server right away & leaves nothing queued")
    func playSendsImmediately() async throws {
        let env = Self.makeEnv(host: "updates-play.test")
        try Self.installHandler(host: env.host)
        env.store.configure(token: "tok", baseURL: env.baseURL)

        await env.store.addPlay(trackId: "t1")

        #expect(env.store.pending.isEmpty)
        #expect(Self.persisted(at: env.fileURL).isEmpty)
        let request = try #require(MockURLProtocol.requests(forHost: env.host).first)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.path == "/api/play/t1")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer tok")
    }

    @Test("a failed play stays queued, survives a relaunch & sends later")
    func failureQueuesAndRecovers() async throws {
        let env = Self.makeEnv(host: "updates-fail.test")
        MockURLProtocol.setHandler(forHost: env.host) { _ in
            throw URLError(.notConnectedToInternet)
        }
        env.store.configure(token: "tok", baseURL: env.baseURL)

        await env.store.addPlay(trackId: "t1")
        #expect(env.store.pending == [PendingUpdate(kind: .play, trackId: "t1")])
        #expect(Self.persisted(at: env.fileURL) == [PendingUpdate(kind: .play, trackId: "t1")])

        let relaunched = Self.relaunch(env)
        #expect(relaunched.pending == [PendingUpdate(kind: .play, trackId: "t1")])

        try Self.installHandler(host: env.host)
        relaunched.configure(token: "tok", baseURL: env.baseURL)
        await relaunched.flush()
        #expect(relaunched.pending.isEmpty)
        #expect(Self.persisted(at: env.fileURL).isEmpty)
    }

    @Test("a server rejection keeps the update queued")
    func rejectionQueues() async throws {
        let env = Self.makeEnv(host: "updates-rejected.test")
        try Self.installHandler(host: env.host, success: false)
        env.store.configure(token: "tok", baseURL: env.baseURL)

        await env.store.addPlay(trackId: "t1")

        #expect(env.store.pending == [PendingUpdate(kind: .play, trackId: "t1")])
        #expect(Self.persisted(at: env.fileURL) == [PendingUpdate(kind: .play, trackId: "t1")])
    }

    @Test("plays queue without sending when logged out")
    func noTokenQueues() async throws {
        let env = Self.makeEnv(host: "updates-notoken.test")
        try Self.installHandler(host: env.host)

        await env.store.addPlay(trackId: "t1")

        #expect(env.store.pending == [PendingUpdate(kind: .play, trackId: "t1")])
        #expect(MockURLProtocol.requests(forHost: env.host).isEmpty)
    }

    @Test("plays queue before the first sync since track user changes is unknown")
    func unsyncedQueues() async throws {
        let env = Self.makeEnv(host: "updates-unsynced.test", synced: false)
        try Self.installHandler(host: env.host)
        env.store.configure(token: "tok", baseURL: env.baseURL)

        await env.store.addPlay(trackId: "t1")

        #expect(env.store.pending == [PendingUpdate(kind: .play, trackId: "t1")])
        #expect(MockURLProtocol.requests(forHost: env.host).isEmpty)
    }

    @Test("plays are dropped when the server doesn't track user changes")
    func untrackedDrops() async throws {
        let env = Self.makeEnv(host: "updates-untracked.test", trackUserChanges: false)
        try Self.installHandler(host: env.host)
        env.store.configure(token: "tok", baseURL: env.baseURL)

        await env.store.addPlay(trackId: "t1")

        #expect(env.store.pending.isEmpty)
        #expect(MockURLProtocol.requests(forHost: env.host).isEmpty)
    }

    @Test("one failing update doesn't block the rest & order is kept")
    func failureDoesNotBlock() async throws {
        let env = Self.makeEnv(host: "updates-partial.test")
        try Self.installHandler(host: env.host, failingPaths: ["/api/play/t1"])

        // queue both before configuring so the flush sees them together
        await env.store.addPlay(trackId: "t1")
        await env.store.addPlay(trackId: "t2")
        env.store.configure(token: "tok", baseURL: env.baseURL)
        await env.store.flush()

        #expect(env.store.pending == [PendingUpdate(kind: .play, trackId: "t1")])
        let paths = MockURLProtocol.requests(forHost: env.host).map { $0.url?.path ?? "" }
        #expect(paths == ["/api/play/t1", "/api/play/t2"])
    }

    @Test("the retry timer resends a failed update")
    func retryTimerResends() async throws {
        let env = Self.makeEnv(host: "updates-retry.test", retryInterval: 0.05)
        let failOnce = FailOnce()
        let body = try OperationResponse.with { $0.success = true }.serializedData()
        MockURLProtocol.setHandler(forHost: env.host) { request in
            if failOnce.shouldFail() {
                throw URLError(.notConnectedToInternet)
            }
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil,
                headerFields: ["Content-Type": "application/octet-stream"])!
            return (response, body)
        }
        env.store.configure(token: "tok", baseURL: env.baseURL)

        await env.store.addPlay(trackId: "t1")
        #expect(env.store.pending.count == 1)

        for _ in 0..<100 where !env.store.pending.isEmpty {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(env.store.pending.isEmpty)
        #expect(Self.persisted(at: env.fileURL).isEmpty)
    }

    @Test("a corrupt updates file loads as empty")
    func corruptFileLoadsEmpty() throws {
        let env = Self.makeEnv(host: "updates-corrupt.test")
        try FileManager.default.createDirectory(
            at: env.fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: env.fileURL)

        let relaunched = Self.relaunch(env)
        #expect(relaunched.pending.isEmpty)
    }
}
