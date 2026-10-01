import Foundation
import Testing
@testable import Warehouse

@Suite("phone-backed watch downloads")
@MainActor
struct WatchFileDownloaderTests {
    @MainActor
    final class Fallback {
        var calls = [String]()
        var succeeds = true
        var suspended = false
        var released: Set<Int>?
        var failedCalls: Set<Int> = []
        var error: Error?
        var completed = 0
        let store: FileStore

        init(store: FileStore) { self.store = store }

        func fetch(_ type: LibraryFileType, filename: String, token: String, baseURL: URL) async throws -> URL {
            let index = calls.count
            calls.append(filename)
            while suspended || released.map({ !$0.contains(index) }) == true { await Task.yield() }
            defer { completed += 1 }
            if let error { throw error }
            guard succeeds, !failedCalls.contains(index) else { throw URLError(.networkConnectionLost) }
            let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
            try Data("server".utf8).write(to: url)
            return url
        }
    }

    @MainActor
    final class Fixture {
        let store = FileStore(rootURL: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString))
        var requests = [WatchFileTransfer]()
        var cancelled = [UUID]()
        var replies = [UUID: @MainActor (PhoneFileReply) -> Void]()
        let timeout: Duration
        init(timeout: Duration = .seconds(5)) { self.timeout = timeout }
        var reachable = true
        var token: String? = "token"
        var generation = UUID()
        var manualClock = false
        var advanced = false
        var waits: [Duration] = []
        lazy var fallback = Fallback(store: store)
        lazy var downloader = makeDownloader()

        func makeDownloader(fileCache: FileCache? = nil, availableBytes: Int64? = nil,
                            size: Int64 = 6, phoneSize: Int64? = nil, moveError: Error? = nil) -> WatchFileDownloader {
            WatchFileDownloader(
                fileStore: store, timeout: timeout,
                transport: .init(
                    isReachable: { [unowned self] in self.reachable }, currentToken: { [unowned self] in self.token },
                    currentGeneration: { [unowned self] in self.generation },
                    request: { [unowned self] transfer, _, reply in
                        self.requests.append(transfer)
                        self.replies[transfer.id] = reply
                    }, cancel: { [unowned self] in self.cancelled.append($0) },
                    fileSize: { _, _, _ in phoneSize }),
                wait: { [unowned self] duration in
                    self.waits.append(duration)
                    if self.manualClock {
                        while !self.advanced { try Task.checkCancellation(); await Task.yield() }
                    } else {
                        try await Task.sleep(for: duration)
                    }
                },
                fetch: { [unowned self] in try await self.fallback.fetch($0, filename: $1, token: $2, baseURL: $3) },
                fileCache: fileCache, availableBytes: { availableBytes }, size: { _, _, _, _ in size },
                moveIn: { [unowned self] type, filename, url in
                    if let moveError { throw moveError }
                    try self.store.moveIn(type, filename, from: url)
                })
        }

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

    @Test("storage admission stops phone and http before a request")
    func admissionStopsTransport() async {
        let env = Fixture()
        let cache = FileCache(fileStore: env.store, budget: { _ in FileCacheBudget(music: 100, artwork: 100) },
                              freeSpaceReserve: 10)
        let downloader = env.makeDownloader(fileCache: cache, availableBytes: 15, size: 10)
        let result = await downloader.downloadResult(.music, filename: "song.m4a", token: "token",
                                                     baseURL: URL(string: "https://example.com")!, onPhase: { _ in })
        #expect(result == .outOfSpace)
        #expect(env.requests.isEmpty)
        #expect(env.fallback.calls.isEmpty)
    }

    @Test("phone file length admits a transfer without a server size probe")
    func phoneSizeAdmits() async throws {
        let env = Fixture()
        let cache = FileCache(fileStore: env.store, budget: { _ in FileCacheBudget(music: 100, artwork: 100) },
                              freeSpaceReserve: 10)
        let downloader = env.makeDownloader(fileCache: cache, availableBytes: 100, size: 1_000,
                                            phoneSize: 6)
        let task = Task {
            await downloader.downloadResult(.music, filename: "song.m4a", token: "token",
                                            baseURL: URL(string: "https://example.com")!, onPhase: { _ in })
        }
        try await PlayerStoreTests.waitFor { !env.requests.isEmpty }
        let temporary = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try Data("phone!".utf8).write(to: temporary)
        downloader.receive(try #require(env.requests.first), from: temporary)
        #expect(await task.value == .downloaded)
        #expect(env.fallback.calls.isEmpty)
    }

    @Test("disk full during commit is distinct and releases its claim")
    func commitStorageFailure() async throws {
        let env = Fixture()
        let cache = FileCache(fileStore: env.store, budget: { _ in FileCacheBudget(music: 100, artwork: 100) },
                              freeSpaceReserve: 10)
        let downloader = env.makeDownloader(fileCache: cache, availableBytes: 100, size: 6,
                                            moveError: POSIXError(.ENOSPC))
        let task = Task {
            await downloader.downloadResult(.music, filename: "song.m4a", token: "token",
                                            baseURL: URL(string: "https://example.com")!, onPhase: { _ in })
        }
        try await PlayerStoreTests.waitFor { !env.requests.isEmpty }
        let transfer = try #require(env.requests.first)
        let temporary = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try Data("server".utf8).write(to: temporary)
        downloader.receive(transfer, from: temporary)
        #expect(await task.value == .outOfSpace)
        #expect(cache.reserve(.music, "next.m4a", bytes: 95, availableBytes: 110))
    }

    @Test("disk full during http fallback is returned distinctly")
    func fallbackDiskFull() async throws {
        let env = Fixture()
        let cache = FileCache(fileStore: env.store, budget: { _ in FileCacheBudget(music: 100, artwork: 100) },
                              freeSpaceReserve: 10)
        env.fallback.error = POSIXError(.ENOSPC)
        let downloader = env.makeDownloader(fileCache: cache, availableBytes: 100, size: 6)
        let task = Task {
            await downloader.downloadResult(.music, filename: "song.m4a", token: "token",
                                            baseURL: URL(string: "https://example.com")!, onPhase: { _ in })
        }
        try await PlayerStoreTests.waitFor { !env.requests.isEmpty }
        env.replies[try #require(env.requests.first).id]?(.cacheMiss)
        #expect(await task.value == .outOfSpace)
        #expect(env.fallback.calls == ["song.m4a"])
    }

    @Test("staging disk full reaches the caller without starting http")
    func stagingDiskFull() async throws {
        let env = Fixture()
        let task = Task {
            await env.downloader.downloadResult(.music, filename: "song.m4a", token: "token",
                                                baseURL: URL(string: "https://example.com")!, onPhase: { _ in })
        }
        try await PlayerStoreTests.waitFor { !env.requests.isEmpty }
        env.downloader.stagingFailed(try #require(env.requests.first), outOfSpace: true)
        #expect(await task.value == .outOfSpace)
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
        env.replies[request.id]?(.cacheMiss)
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
        env.replies[transfer.id]?(.accepted)
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
        env.replies[env.requests[0].id]?(.cacheMiss)
        #expect(await task.value)
        #expect(env.fallback.calls == ["song.m4a"])
    }

    @Test("a failed file transfer falls back without waiting for the deadline")
    func transferFailure() async throws {
        let env = Fixture()
        let task = env.fetch()
        try await PlayerStoreTests.waitFor { !env.requests.isEmpty }
        env.replies[env.requests[0].id]?(.accepted)
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

    @Test("a still-desired phone file can arrive after the foreground deadline and http failure")
    func latePreparation() async throws {
        let env = Fixture(timeout: .milliseconds(20))
        env.fallback.succeeds = false
        env.downloader.setDesiredMusic(["song.m4a"])
        #expect(await env.fetch().value == false)
        let transfer = try #require(env.requests.first)
        try env.deliver(transfer)
        #expect(env.store.exists(.music, transfer.filename))
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
        try env.deliver(WatchFileTransfer(id: wanted.id, generation: wanted.generation, type: .music, filename: "wrong.m4a"))
        #expect(!env.store.exists(.music, "wrong.m4a"))
        env.token = "replacement"
        env.generation = UUID()
        try env.deliver(wanted)
        #expect(await task.value == false)
        #expect(!env.store.exists(.music, wanted.filename))
        #expect(env.fallback.calls.isEmpty)
    }

    @Test("a phone delivery beyond thirty seconds survives a failed foreground fallback")
    func pastThirtySeconds() async throws {
        let env = Fixture(timeout: .seconds(30))
        env.manualClock = true
        env.fallback.succeeds = false
        env.downloader.setDesiredMusic(["song.m4a"])
        let task = env.fetch()
        try await PlayerStoreTests.waitFor { env.waits == [.seconds(30)] }
        let transfer = try #require(env.requests.first)
        env.replies[transfer.id]?(.accepted)
        env.advanced = true
        #expect(await task.value == false)
        #expect(env.cancelled.isEmpty)
        #expect(env.downloader.jobs[transfer.id]?.state == .accepted)
        try env.deliver(transfer)
        #expect(env.store.exists(.music, transfer.filename))
        #expect(env.downloader.jobs.isEmpty)
    }

    @Test("background cancellation and downloader recreation preserve selected transfers")
    func relaunch() async throws {
        let env = Fixture()
        env.downloader.setDesiredMusic(["song.m4a"])
        let task = env.fetch()
        try await PlayerStoreTests.waitFor { !env.requests.isEmpty }
        let transfer = try #require(env.requests.first)
        env.replies[transfer.id]?(.accepted)
        task.cancel()
        #expect(await task.value == false)
        #expect(env.cancelled.isEmpty)
        let journal = try String(contentsOf: env.store.rootURL.appending(path: "phone-transfers.json"), encoding: .utf8)
        #expect(!journal.contains("token"))
        env.downloader = env.makeDownloader()
        env.downloader.reconcile([PhoneFileProgress(transfer: transfer, fraction: 0.5)])
        #expect(env.downloader.jobs[transfer.id]?.state == .transferring)
        #expect(env.downloader.jobs[transfer.id]?.fraction == 0.5)
        try env.deliver(transfer)
        #expect(env.store.exists(.music, transfer.filename))
    }

    @Test("lost cancellation messages and delayed acceptance cannot resurrect cancelled intent")
    func lostCancellation() async throws {
        let env = Fixture()
        env.downloader.setDesiredMusic(["song.m4a"])
        let task = env.fetch()
        try await PlayerStoreTests.waitFor { !env.requests.isEmpty }
        let transfer = try #require(env.requests.first)
        env.reachable = false
        env.downloader.setDesiredMusic([])
        #expect(await task.value == false)
        env.replies[transfer.id]?(.accepted)
        env.downloader = env.makeDownloader()
        try env.deliver(transfer)
        #expect(!env.store.exists(.music, transfer.filename))
        #expect(env.downloader.jobs.isEmpty)
        env.downloader.reconcile([PhoneFileProgress(transfer: transfer)])
        #expect(env.cancelled.last == transfer.id)
    }

    @Test("late acceptance remains useful after http fails")
    func delayedAcceptance() async throws {
        let env = Fixture(timeout: .milliseconds(20))
        env.fallback.succeeds = false
        env.downloader.setDesiredMusic(["song.m4a"])
        #expect(await env.fetch().value == false)
        let transfer = try #require(env.requests.first)
        env.replies[transfer.id]?(.accepted)
        #expect(env.downloader.jobs[transfer.id]?.state == .accepted)
        try env.deliver(transfer)
        #expect(env.store.exists(.music, transfer.filename))
    }

    @Test("duplicate callers share phone and http work, and one cancelled caller cannot cancel the other")
    func duplicateCallers() async throws {
        let env = Fixture()
        let first = env.fetch()
        try await PlayerStoreTests.waitFor { env.requests.count == 1 }
        var joined = false
        let second = Task {
            await env.downloader.downloadResult(.music, filename: "song.m4a", token: "token",
                                                baseURL: URL(string: "https://example.com")!) { _ in joined = true }
        }
        try await PlayerStoreTests.waitFor { joined }
        first.cancel()
        #expect(await first.value == false)
        #expect(env.cancelled.isEmpty)
        env.replies[env.requests[0].id]?(.cacheMiss)
        #expect(await second.value == .downloaded)
        #expect(env.requests.count == 1)
        #expect(env.fallback.calls == ["song.m4a"])
    }

    @Test("the first committed source wins when phone and http overlap", arguments: [true, false])
    func overlappingDeliveries(phoneFirst: Bool) async throws {
        let env = Fixture(timeout: .milliseconds(20))
        env.downloader.setDesiredMusic(["song.m4a"])
        env.fallback.suspended = true
        let task = env.fetch()
        try await PlayerStoreTests.waitFor { !env.fallback.calls.isEmpty }
        let transfer = try #require(env.requests.first)
        var stores = 0
        env.downloader.onStored = { _ in stores += 1 }
        if phoneFirst { try env.deliver(transfer) }
        env.fallback.suspended = false
        #expect(await task.value)
        try await PlayerStoreTests.waitFor { env.fallback.completed == 1 }
        if !phoneFirst { try env.deliver(transfer) }
        // a fresh fetch after the original completion must remain a cache hit.
        #expect(await env.fetch().value)
        #expect(stores == 1)
        #expect(try Data(contentsOf: env.store.fileURL(.music, transfer.filename)) == Data((phoneFirst ? "phone" : "server").utf8))
    }

    @Test("cancelled http results cannot recreate files after explicit removal")
    func cancelledHTTP() async throws {
        let env = Fixture(timeout: .milliseconds(20))
        env.downloader.setDesiredMusic(["song.m4a"])
        env.fallback.suspended = true
        let task = env.fetch()
        try await PlayerStoreTests.waitFor { !env.fallback.calls.isEmpty }
        env.downloader.setDesiredMusic([])
        #expect(await task.value == false)
        env.fallback.suspended = false
        try await PlayerStoreTests.waitFor { env.fallback.completed == 1 }
        #expect(!env.store.exists(.music, "song.m4a"))
    }

    @Test("persisted intent cannot authorize the wrong generation, filename, type or unsolicited id")
    func invalidDelivery() async throws {
        let env = Fixture()
        env.downloader.setDesiredMusic(["song.m4a"])
        let task = env.fetch()
        try await PlayerStoreTests.waitFor { !env.requests.isEmpty }
        let transfer = try #require(env.requests.first)
        task.cancel()
        #expect(await task.value == false)
        env.downloader = env.makeDownloader()
        for invalid in [
            WatchFileTransfer(id: transfer.id, generation: UUID(), type: .music, filename: transfer.filename),
            WatchFileTransfer(id: transfer.id, generation: transfer.generation, type: .music, filename: "wrong.m4a"),
            WatchFileTransfer(id: transfer.id, generation: transfer.generation, type: .artwork, filename: transfer.filename),
            WatchFileTransfer(generation: transfer.generation, type: .music, filename: transfer.filename)
        ] { try env.deliver(invalid) }
        #expect(env.store.list(.music).isEmpty)
        #expect(env.store.list(.artwork).isEmpty)
        env.generation = UUID()
        env.downloader = env.makeDownloader()
        try env.deliver(transfer)
        #expect(!env.store.exists(.music, transfer.filename))
    }

    @Test("logout invalidates pending phone and http work")
    func logout() async throws {
        let env = Fixture()
        env.downloader.setDesiredMusic(["song.m4a"])
        let task = env.fetch()
        try await PlayerStoreTests.waitFor { !env.requests.isEmpty }
        env.token = nil
        env.downloader.configurationChanged()
        #expect(await task.value == false)
        env.downloader = env.makeDownloader()
        try env.deliver(env.requests[0])
        #expect(env.store.list(.music).isEmpty)
    }

    @Test("offline preparation survives backgrounding and late delivery updates readiness")
    func offlinePreparation() async throws {
        let env = Fixture()
        let cache = FileCache(fileStore: env.store, budget: { _ in FileCacheBudget(music: 1000, artwork: 1000) })
        let offline = OfflineLibrary(
            fileCache: cache, downloader: env.downloader, availableBytes: { 1_000_000_000 },
            prepareMusic: { env.downloader.setDesiredMusic($0) })
        env.downloader.onStored = { _ in offline.refreshFiles() }
        offline.setCredentials(token: "token", baseURL: URL(string: "https://example.com")!)
        offline.setForeground(true)
        offline.prepare(OfflineLibraryTests.playlist(["1"]), songs: PlayerStoreTests.songs(1))
        try await PlayerStoreTests.waitFor { !env.requests.isEmpty }
        offline.setForeground(false)
        try env.deliver(env.requests[0])
        #expect(offline.progress("p").state == .ready)
        #expect(env.fallback.calls.isEmpty)
        offline.remove("p")
        try env.deliver(env.requests[0])
        #expect(!env.store.exists(.music, "1.wav"))
    }

    @Test("an old http failure cannot finish a resumed foreground wait for the same durable job")
    func cancelledAttemptFailure() async throws {
        let env = Fixture(timeout: .milliseconds(20))
        env.downloader.setDesiredMusic(["song.m4a"])
        env.fallback.released = []
        env.fallback.failedCalls = [0]
        let first = env.fetch()
        try await PlayerStoreTests.waitFor { env.fallback.calls.count == 1 }
        let transfer = try #require(env.requests.first)
        first.cancel()
        #expect(await first.value == false)
        let second = env.fetch()
        try await PlayerStoreTests.waitFor { env.fallback.calls.count == 2 }
        #expect(env.requests.map(\.id) == [transfer.id, transfer.id])
        env.fallback.released = [0]
        try await PlayerStoreTests.waitFor { env.fallback.completed == 1 }
        try env.deliver(transfer)
        #expect(await second.value)
        env.fallback.released = [0, 1]
        try await PlayerStoreTests.waitFor { env.fallback.completed == 2 }
        #expect(try Data(contentsOf: env.store.fileURL(.music, transfer.filename)) == Data("phone".utf8))
    }

    @Test("journal write failure fails closed without leaving a foreground caller waiting")
    func journalFailure() async throws {
        let env = Fixture()
        env.downloader.setDesiredMusic(["song.m4a"])
        let task = env.fetch()
        try await PlayerStoreTests.waitFor { !env.requests.isEmpty }
        let journal = env.store.rootURL.appending(path: "phone-transfers.json")
        try FileManager.default.removeItem(at: journal)
        try FileManager.default.createDirectory(at: journal, withIntermediateDirectories: true)
        let transfer = try #require(env.requests.first)
        env.replies[transfer.id]?(.accepted)
        try env.deliver(transfer)
        #expect(await task.value == false)
        #expect(!env.store.exists(.music, transfer.filename))
    }

    @Test("reconciliation uses current intent when a system snapshot arrives after new requests")
    func delayedSnapshot() async throws {
        let env = Fixture()
        let first = env.fetch("first.m4a")
        try await PlayerStoreTests.waitFor { env.requests.count == 1 }
        let snapshot = [PhoneFileProgress(transfer: env.requests[0], fraction: 0.25)]
        let second = env.fetch("second.m4a")
        try await PlayerStoreTests.waitFor { env.requests.count == 2 }
        env.downloader.reconcile(snapshot)
        #expect(env.cancelled.isEmpty)
        #expect(env.downloader.jobs.count == 2)
        try env.deliver(env.requests[0])
        try env.deliver(env.requests[1])
        #expect(await first.value)
        #expect(await second.value)
    }
}
