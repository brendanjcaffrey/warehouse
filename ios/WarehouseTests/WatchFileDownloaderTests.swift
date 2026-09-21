import Foundation
import Testing
@testable import Warehouse

@Suite("phone-backed watch downloads")
@MainActor
struct WatchFileDownloaderTests {
    @MainActor
    final class Fallback: SingleFileDownloading {
        var calls = [String]()
        let store: FileStore

        init(store: FileStore) { self.store = store }

        @MainActor
        func download(_ type: LibraryFileType, filename: String, token: String, baseURL: URL) async -> Bool {
            calls.append(filename)
            try? store.write(type, filename, data: Data("server".utf8))
            return true
        }
    }

    @MainActor
    final class Fixture {
        let store = FileStore(rootURL: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString))
        var requests = [WatchFileTransfer]()
        var cancelled = [UUID]()
        var replies = [UUID: @MainActor (Bool) -> Void]()
        let timeout: Duration
        init(timeout: Duration = .seconds(5)) { self.timeout = timeout }
        var reachable = true
        var token = "token"
        lazy var fallback = Fallback(store: store)
        lazy var downloader = WatchFileDownloader(
            fileStore: store, fallback: fallback, timeout: timeout,
            transport: .init(isReachable: { [unowned self] in self.reachable }, currentToken: { [unowned self] in self.token },
            request: { [unowned self] transfer, _, reply in
                self.requests.append(transfer)
                self.replies[transfer.id] = reply
            }, cancel: { [unowned self] in self.cancelled.append($0) }))

        func fetch(_ filename: String = "song.m4a", type: LibraryFileType = .music) -> Task<Bool, Never> {
            Task { await downloader.download(type, filename: filename, token: "token", baseURL: URL(string: "https://example.com")!) }
        }

        func deliver(_ transfer: WatchFileTransfer, bytes: String = "phone") throws {
            let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
            try Data(bytes.utf8).write(to: url)
            downloader.receive(transfer, from: url)
            #expect(!FileManager.default.fileExists(atPath: url.path))
        }
    }

    @Test("cached files need neither the phone nor http")
    func cached() async throws {
        let env = Fixture()
        try env.store.write(.music, "song.m4a", data: Data("cached".utf8))
        #expect(await env.fetch().value)
        #expect(env.requests.isEmpty)
        #expect(env.fallback.calls.isEmpty)
    }

    @Test("preparation reports the phone wait and the server fallback separately")
    func preparationPhases() async throws {
        let env = Fixture()
        var phases: [FileDownloadPhase] = []
        let task = Task {
            await env.downloader.downloadResult(.music, filename: "song.m4a", token: "token",
                                                baseURL: URL(string: "https://example.com")!) { phases.append($0) }
        }
        try await PlayerStoreTests.waitFor { !env.requests.isEmpty }
        #expect(phases == [.waitingForPhone])
        let request = try #require(env.requests.first)
        env.replies[request.id]?(false)
        #expect(await task.value == .downloaded)
        #expect(phases == [.waitingForPhone, .downloading])
    }

    @Test("the watch bounds outstanding requests")
    func bounded() async throws {
        let env = Fixture()
        var tasks = [Task<Bool, Never>]()
        for index in 0..<PhoneFileProvider.maximumTransfers {
            tasks.append(env.fetch("\(index).m4a"))
        }
        try await PlayerStoreTests.waitFor { env.requests.count == PhoneFileProvider.maximumTransfers }
        #expect(await env.fetch("overflow.m4a").value)
        #expect(env.requests.count == PhoneFileProvider.maximumTransfers)
        #expect(env.fallback.calls == ["overflow.m4a"])
        for task in tasks { task.cancel() }
        for task in tasks { #expect(await task.value == false) }
    }

    @Test("artwork fetched from the phone participates in the existing artwork cache")
    func artwork() async throws {
        let env = Fixture()
        let cache = FileCache(fileStore: env.store)
        let fetcher = WatchArtworkFetcher(fileCache: cache, downloader: env.downloader, credentials: {
            (token: "token", baseURL: URL(string: "https://example.com")!)
        })
        let task = Task { await fetcher.artworkURL("cover.jpg") }
        try await PlayerStoreTests.waitFor { !env.requests.isEmpty }
        #expect(env.requests[0].type == .artwork)
        try env.deliver(env.requests[0])
        #expect(await task.value == env.store.fileURL(.artwork, "cover.jpg"))
        #expect(env.fallback.calls.isEmpty)
    }

    @Test("phone hits fill the store without an http download", arguments: LibraryFileType.allCases)
    func phoneHit(type: LibraryFileType) async throws {
        let env = Fixture()
        let task = env.fetch(type: type)
        try await PlayerStoreTests.waitFor { !env.requests.isEmpty }
        let transfer = try #require(env.requests.first)
        env.replies[transfer.id]?(true)
        try env.deliver(transfer)
        #expect(await task.value)
        #expect(env.fallback.calls.isEmpty)
        #expect(try Data(contentsOf: env.store.fileURL(type, "song.m4a")) == Data("phone".utf8))
    }

    @Test("unreachable phones immediately fall back to http")
    func unreachable() async {
        let env = Fixture()
        env.reachable = false
        #expect(await env.fetch().value)
        #expect(env.requests.isEmpty)
        #expect(env.fallback.calls == ["song.m4a"])
    }

    @Test("a miss or transport error falls back to http")
    func declined() async throws {
        let env = Fixture()
        let task = env.fetch()
        try await PlayerStoreTests.waitFor { !env.requests.isEmpty }
        env.replies[env.requests[0].id]?(false)
        #expect(await task.value)
        #expect(env.fallback.calls == ["song.m4a"])
    }

    @Test("a failed file transfer falls back without waiting for the deadline")
    func transferFailure() async throws {
        let env = Fixture()
        let task = env.fetch()
        try await PlayerStoreTests.waitFor { !env.requests.isEmpty }
        env.replies[env.requests[0].id]?(true)
        env.downloader.failed(env.requests[0])
        #expect(await task.value)
        #expect(env.fallback.calls == ["song.m4a"])
    }

    @Test("timeout falls back and late files cannot overwrite the result")
    func timeout() async throws {
        let env = Fixture(timeout: .milliseconds(20))
        #expect(await env.fetch().value)
        let transfer = try #require(env.requests.first)
        #expect(env.cancelled == [transfer.id])
        try env.deliver(transfer)
        #expect(try Data(contentsOf: env.store.fileURL(.music, "song.m4a")) == Data("server".utf8))
    }

    @Test("cancellation stops the phone transfer without starting http")
    func cancellation() async throws {
        let env = Fixture()
        let task = env.fetch()
        try await PlayerStoreTests.waitFor { !env.requests.isEmpty }
        task.cancel()
        #expect(await task.value == false)
        #expect(env.fallback.calls.isEmpty)
        #expect(env.cancelled == env.requests.map(\.id))
        try env.deliver(env.requests[0])
        #expect(!env.store.exists(.music, "song.m4a"))
    }

    @Test("files must match the request and current credentials")
    func rejectsUnwantedFiles() async throws {
        let env = Fixture()
        let task = env.fetch()
        try await PlayerStoreTests.waitFor { !env.requests.isEmpty }
        let wanted = env.requests[0]
        try env.deliver(WatchFileTransfer(id: wanted.id, type: .music, filename: "wrong.m4a"))
        #expect(!env.store.exists(.music, "wrong.m4a"))
        env.token = "replacement"
        try env.deliver(wanted)
        #expect(await task.value == false)
        #expect(!env.store.exists(.music, wanted.filename))
        #expect(env.fallback.calls.isEmpty)
    }
}
