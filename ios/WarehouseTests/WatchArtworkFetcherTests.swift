import Foundation
import Testing
@testable import Warehouse

@Suite("WatchArtworkFetcher")
@MainActor
struct WatchArtworkFetcherTests {
    /// stepped by hand so the retry cooldown is exact instead of depending on
    /// how long the test takes
    final class Clock: @unchecked Sendable {
        var date = Date(timeIntervalSince1970: 1_000_000)

        func advance(_ seconds: TimeInterval) {
            date += seconds
        }
    }

    /// a downloader the test finishes by hand. every fetch parks until the
    /// test says that file may land, so slot handoff is observed rather than
    /// raced against whatever the mock url protocol gets around to serving
    final class GatedDownloader: SingleFileDownloading, @unchecked Sendable {
        private let lock = NSLock()
        private var parked: [String: CheckedContinuation<Bool, Never>] = [:]
        private var allowed: Set<String> = []
        private var allowsEverything = false
        private var asked: [String] = []

        /// the files a download has been started for, in the order they started
        var started: [String] {
            lock.lock()
            defer { lock.unlock() }
            return asked
        }

        /// lets one file land, whether or not its download has started yet
        func finish(_ filename: String) {
            lock.lock()
            allowed.insert(filename)
            let continuation = parked.removeValue(forKey: filename)
            lock.unlock()
            continuation?.resume(returning: true)
        }

        /// lets everything land, for draining what's left at the end of a test
        func finishEverything() {
            lock.lock()
            allowsEverything = true
            let continuations = parked.values
            parked = [:]
            lock.unlock()
            for continuation in continuations {
                continuation.resume(returning: true)
            }
        }

        func download(_ type: LibraryFileType, filename: String, token: String, baseURL: URL) async -> Bool {
            await withCheckedContinuation { continuation in
                lock.lock()
                asked.append(filename)
                guard !allowsEverything, !allowed.contains(filename) else {
                    lock.unlock()
                    continuation.resume(returning: true)
                    return
                }
                parked[filename] = continuation
                lock.unlock()
            }
        }
    }

    static func makeStore() -> FileStore {
        FileStore(rootURL: FileManager.default.temporaryDirectory
            .appending(path: "artwork-fetcher-tests-\(UUID().uuidString)"))
    }

    /// budgets default to more than any test writes, so only the tests about
    /// eviction ever see a file removed. the `onEvict` hook rides the budget
    /// closure because `FileCache` asks for one exactly once per pass
    static func makeCache(
        _ store: FileStore,
        artwork: Int64 = .max,
        onEvict: @escaping @MainActor () -> Void = {}
    ) -> FileCache {
        FileCache(
            fileStore: store,
            budget: { _ in
                onEvict()
                return FileCacheBudget(music: .max, artwork: artwork)
            })
    }

    static func makeFetcher(
        host: String,
        store: FileStore,
        cache: FileCache? = nil,
        clock: Clock = Clock(),
        handler: @escaping @Sendable (URLRequest) throws -> (HTTPURLResponse, Data)
    ) -> WatchArtworkFetcher {
        let baseURL = URL(string: "https://\(host)")!
        MockURLProtocol.setHandler(forHost: host, handler)
        var client = LibraryClient()
        client.session = MockURLProtocol.makeSession()
        return WatchArtworkFetcher(
            fileCache: cache ?? Self.makeCache(store),
            client: client,
            credentials: { (token: "tok", baseURL: baseURL) },
            now: { clock.date })
    }

    /// for the tests about queueing, which need every download to sit still
    /// until they say otherwise rather than to reach a url session at all
    static func makeGatedFetcher(_ downloader: GatedDownloader) -> WatchArtworkFetcher {
        WatchArtworkFetcher(
            fileCache: Self.makeCache(Self.makeStore()),
            downloader: downloader,
            credentials: { (token: "tok", baseURL: URL(string: "https://artwork.example.com")!) })
    }

    nonisolated static func okResponse(_ url: URL) -> HTTPURLResponse {
        HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
    }

    /// spins until the condition holds, so tests wait on requests actually
    /// starting rather than on a fixed sleep. fails loudly instead of carrying
    /// on to assert against a state that never arrived
    static func waitFor(_ description: String, _ condition: () -> Bool) async throws {
        for _ in 0..<200 where !condition() {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        try #require(condition(), "timed out waiting for \(description)")
    }

    static func names(_ host: String) -> [String] {
        MockURLProtocol.requests(forHost: host).compactMap { $0.url?.lastPathComponent }
    }

    @Test("artwork already on disk is returned without a request")
    func onDiskNeedsNoFetch() async throws {
        let host = "artwork-\(UUID().uuidString).example.com"
        let store = Self.makeStore()
        let fetcher = Self.makeFetcher(host: host, store: store) { request in
            (Self.okResponse(request.url!), Data("artwork-bytes".utf8))
        }
        try store.write(.artwork, "cover.jpg", data: Data("already-here".utf8))

        let url = await fetcher.artworkURL("cover.jpg")

        #expect(url == store.fileURL(.artwork, "cover.jpg"))
        #expect(Self.names(host).isEmpty)
    }

    @Test("a missing file is fetched & its url handed back")
    func fetchesAMissingFile() async throws {
        let host = "artwork-\(UUID().uuidString).example.com"
        let store = Self.makeStore()
        let fetcher = Self.makeFetcher(host: host, store: store) { request in
            (Self.okResponse(request.url!), Data("artwork-bytes".utf8))
        }

        let url = await fetcher.artworkURL("cover.jpg")

        #expect(url == store.fileURL(.artwork, "cover.jpg"))
        #expect(store.exists(.artwork, "cover.jpg"))
        let requests = MockURLProtocol.requests(forHost: host)
        #expect(requests.count == 1)
        #expect(requests.first?.url?.path == "/artwork/cover.jpg")
        #expect(requests.first?.value(forHTTPHeaderField: "Authorization") == "Bearer tok")
    }

    @Test("concurrent requests for the same file share one fetch")
    func dedupesConcurrentFetches() async throws {
        let host = "artwork-\(UUID().uuidString).example.com"
        let store = Self.makeStore()
        let fetcher = Self.makeFetcher(host: host, store: store) { request in
            (Self.okResponse(request.url!), Data("artwork-bytes".utf8))
        }

        async let first = fetcher.artworkURL("cover.jpg")
        async let second = fetcher.artworkURL("cover.jpg")
        async let third = fetcher.artworkURL("cover.jpg", priority: .nowPlaying)

        let urls = await [first, second, third]
        #expect(urls.allSatisfy { $0 == store.fileURL(.artwork, "cover.jpg") })
        #expect(Self.names(host) == ["cover.jpg"])
    }

    @Test("a failed fetch falls back to no url & isn't retried in a tight loop")
    func failureCoolsDownBeforeRetrying() async throws {
        let host = "artwork-\(UUID().uuidString).example.com"
        let store = Self.makeStore()
        let clock = Clock()
        let fetcher = Self.makeFetcher(host: host, store: store, clock: clock) { _ in
            throw URLError(.notConnectedToInternet)
        }

        #expect(await fetcher.artworkURL("cover.jpg") == nil)
        // a row scrolling back into view asks again & is answered from the
        // cooldown rather than the server
        #expect(await fetcher.artworkURL("cover.jpg") == nil)
        #expect(await fetcher.artworkURL("cover.jpg") == nil)
        #expect(Self.names(host).count == 1)

        clock.advance(WatchArtworkFetcher.retryInterval)
        #expect(await fetcher.artworkURL("cover.jpg") == nil)
        #expect(Self.names(host).count == 2)
    }

    @Test("no more than the concurrency cap fetches at once, the rest queue")
    func capsConcurrentFetches() async throws {
        let downloader = GatedDownloader()
        let fetcher = Self.makeGatedFetcher(downloader)

        let fetches = (1...6).map { index in
            Task { @MainActor in await fetcher.fetch("cover\(index).jpg") }
        }
        try await Self.waitFor("four fetches queued") { fetcher.queued == 4 }
        #expect(fetcher.running == WatchArtworkFetcher.concurrentFetches)
        // the queued ones ask for nothing until a slot frees
        try await Self.waitFor("two downloads started") {
            downloader.started.count == WatchArtworkFetcher.concurrentFetches
        }

        downloader.finishEverything()
        for fetch in fetches {
            _ = await fetch.value
        }
        #expect(fetcher.running == 0)
        #expect(fetcher.queued == 0)
        #expect(downloader.started.count == 6)
    }

    @Test("now playing artwork jumps the queue ahead of list rows")
    func nowPlayingGoesFirst() async throws {
        let downloader = GatedDownloader()
        let fetcher = Self.makeGatedFetcher(downloader)

        // two fetches take both slots & hold them until the test lets them go
        var fetches = (1...2).map { index in
            Task { @MainActor in await fetcher.fetch("holding\(index).jpg") }
        }
        try await Self.waitFor("both slots taken & downloading") {
            fetcher.running == WatchArtworkFetcher.concurrentFetches
                && downloader.started.count == WatchArtworkFetcher.concurrentFetches
        }

        // queue two rows ahead of the now playing file, so taking the queue in
        // order would answer a row first. they go on one at a time since the
        // assertion is about the order they lined up in
        for (index, name) in ["row1.jpg", "row2.jpg", "playing.jpg"].enumerated() {
            let priority: WatchArtworkFetcher.Priority = name == "playing.jpg" ? .nowPlaying : .list
            fetches.append(Task { @MainActor in await fetcher.fetch(name, priority: priority) })
            try await Self.waitFor("\(name) queued") { fetcher.queued == index + 1 }
        }

        // the first slot to free goes to the now playing file, not to the row
        // that has been waiting longest
        downloader.finish("holding1.jpg")
        try await Self.waitFor("a third download to start") { downloader.started.count > 2 }
        #expect(downloader.started[2] == "playing.jpg")
        #expect(fetcher.queued == 2)

        downloader.finishEverything()
        for fetch in fetches {
            _ = await fetch.value
        }
        #expect(fetcher.queued == 0)
    }

    @Test("a batch of fetches runs one eviction pass & the ones before it none")
    func evictsEveryNthFetch() async throws {
        let host = "artwork-\(UUID().uuidString).example.com"
        let store = Self.makeStore()
        var evictions = 0
        let cache = Self.makeCache(store) { evictions += 1 }
        let fetcher = Self.makeFetcher(host: host, store: store, cache: cache) { request in
            (Self.okResponse(request.url!), Data("artwork-bytes".utf8))
        }

        for index in 1..<WatchArtworkFetcher.fetchesPerEviction {
            await fetcher.fetch("cover\(index).jpg")
        }
        #expect(evictions == 0)

        await fetcher.fetch("cover\(WatchArtworkFetcher.fetchesPerEviction).jpg")
        #expect(evictions == 1)

        // the count starts over, so scrolling on doesn't walk the directories
        // once per row from here
        await fetcher.fetch("extra.jpg")
        #expect(evictions == 1)
    }

    @Test("failures don't count toward the eviction pass")
    func failedFetchesDontCount() async throws {
        let host = "artwork-\(UUID().uuidString).example.com"
        let store = Self.makeStore()
        var evictions = 0
        let cache = Self.makeCache(store) { evictions += 1 }
        let fetcher = Self.makeFetcher(host: host, store: store, cache: cache) { _ in
            throw URLError(.notConnectedToInternet)
        }

        // distinct names so each one gets past the cooldown & really asks
        for index in 1...WatchArtworkFetcher.fetchesPerEviction {
            await fetcher.fetch("cover\(index).jpg")
        }

        #expect(evictions == 0)
    }

    @Test("artwork over budget is trimmed through the fetcher, with no track played")
    func trimsArtworkOverBudget() async throws {
        let host = "artwork-\(UUID().uuidString).example.com"
        let store = Self.makeStore()
        // eight files' worth of budget against twenty files of browsing
        let cache = Self.makeCache(store, artwork: 800)
        let fetcher = Self.makeFetcher(host: host, store: store, cache: cache) { request in
            (Self.okResponse(request.url!), Data(count: 100))
        }

        for index in 1...WatchArtworkFetcher.fetchesPerEviction {
            await fetcher.fetch("cover\(index).jpg")
        }

        // the pass at the end of the batch takes it back under the budget,
        // which nothing but a music fetch used to be able to do
        #expect(store.totalSize(.artwork) <= 800)
        #expect(store.list(.artwork).count == 8)
        #expect(store.list(.music).isEmpty)
    }

    @Test("a nil filename is nothing to show & nothing to fetch")
    func nilFilenameDoesNothing() async throws {
        let host = "artwork-\(UUID().uuidString).example.com"
        let store = Self.makeStore()
        let fetcher = Self.makeFetcher(host: host, store: store) { request in
            (Self.okResponse(request.url!), Data("artwork-bytes".utf8))
        }

        #expect(await fetcher.artworkURL(nil) == nil)
        #expect(Self.names(host).isEmpty)
    }
}
