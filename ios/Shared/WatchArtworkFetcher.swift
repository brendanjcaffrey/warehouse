import Foundation

/// fetches artwork on demand for the watch, which keeps a bounded cache
/// rather than a mirror of the library, so most artwork is not on disk when a
/// row asks for it. the phone mirrors everything and reads straight off disk,
/// so nothing over there goes through here.
///
/// browsing is the only thing that grows the artwork half of the cache, and a
/// library whose tracks are all cached never fetches music at all, so eviction
/// cannot stay piggybacked on `PlayerStore`: this runs a pass of its own every
/// `fetchesPerEviction` files. artwork files are content addressed, so a
/// refetch after an eviction lands back at the same path and the decoded
/// `ArtworkLoader` cache never goes stale.
@MainActor
final class WatchArtworkFetcher {
    /// the now playing artwork is the one the user is actually looking at, so
    /// it goes ahead of whatever list rows are queued behind it
    enum Priority {
        case list
        case nowPlaying
    }

    /// how many artwork fetches may be in flight at once. the funnel is derp
    /// relayed & shared with the track the user is waiting on, so a screen
    /// full of rows must not open a request each
    static let concurrentFetches = 2
    /// how long a filename that failed is left alone before another row may
    /// try it again, so scrolling past an unreachable server doesn't turn into
    /// a request per row per appearance
    static let retryInterval: TimeInterval = 60
    /// how many artwork files may land between eviction passes. `evict()`
    /// walks both type directories & stats every file in them, which is far
    /// too much work to repeat per row of a scrolling list; artwork files are
    /// small enough that a batch of this many can't overrun the budget by
    /// anything that matters
    static let fetchesPerEviction = 20

    private let fileCache: FileCache
    private let fileStore: FileStore
    private let downloader: SingleFileDownloading
    private let credentials: @Sendable () -> (token: String, baseURL: URL)?
    private let now: @Sendable () -> Date

    /// one task per filename, so rows that want the same artwork at the same
    /// moment share a single request instead of racing
    private var inFlight: [String: Task<Bool, Never>] = [:]
    /// filename -> when it last failed, for the retry cooldown
    private var failures: [String: Date] = [:]
    /// how many fetches hold a slot right now
    private(set) var running = 0
    private var waiting: [(priority: Priority, continuation: CheckedContinuation<Void, Never>)] = []
    /// counts up to `fetchesPerEviction`; only files that actually landed
    /// count, since a failure grew nothing
    private var fetchesSinceEviction = 0

    /// how many fetches are waiting for a slot behind the running ones
    var queued: Int { waiting.count }

    /// takes the cache rather than a bare store so the pass it runs sees the
    /// same in-use set & recency index the player writes: a second `FileCache`
    /// over the same directory would happily evict the cover on screen. the
    /// downloader parameter is here for tests
    init(
        fileCache: FileCache,
        client: LibraryClient = LibraryClient(),
        downloader: SingleFileDownloading? = nil,
        credentials: @escaping @Sendable () -> (token: String, baseURL: URL)?,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.fileCache = fileCache
        self.fileStore = fileCache.fileStore
        self.downloader = downloader ?? FileDownloader(client: client, fileStore: fileCache.fileStore)
        self.credentials = credentials
        self.now = now
    }

    /// the local url for an artwork file, fetching it first when it isn't on
    /// disk. nil means there is nothing to show and the caller keeps its
    /// placeholder — a track with no artwork and one we couldn't fetch look
    /// the same on purpose
    func artworkURL(_ filename: String?, priority: Priority = .list) async -> URL? {
        guard let filename else { return nil }
        if fileStore.exists(.artwork, filename) {
            return fileStore.fileURL(.artwork, filename)
        }
        guard await fetch(filename, priority: priority) else { return nil }
        return fileStore.fileURL(.artwork, filename)
    }

    /// fetches one artwork file, joining the fetch already running for it
    /// rather than starting a second. returns whether it is on disk afterwards
    @discardableResult
    func fetch(_ filename: String, priority: Priority = .list) async -> Bool {
        if let existing = inFlight[filename] {
            return await existing.value
        }
        guard !isCoolingDown(filename), let credentials = credentials() else { return false }

        await acquireSlot(priority)
        // a row that scrolled away while it waited has been cancelled: hand
        // the slot on rather than spending it on something offscreen
        guard !Task.isCancelled else {
            releaseSlot()
            return false
        }
        // someone else may have started this very file while we waited
        if let existing = inFlight[filename] {
            releaseSlot()
            return await existing.value
        }

        let downloader = downloader
        let task = Task { @MainActor in
            await downloader.download(
                .artwork, filename: filename,
                token: credentials.token, baseURL: credentials.baseURL)
        }
        inFlight[filename] = task
        let downloaded = await task.value
        inFlight[filename] = nil
        failures[filename] = downloaded ? nil : now()
        releaseSlot()
        if downloaded {
            evictIfDue()
        }
        return downloaded
    }

    /// keeps the browse path inside the budget without a timer: a pass runs
    /// once a batch of files has landed, which is the only moment this side
    /// can have grown the cache
    private func evictIfDue() {
        fetchesSinceEviction += 1
        guard fetchesSinceEviction >= Self.fetchesPerEviction else { return }
        fetchesSinceEviction = 0
        fileCache.evict()
    }

    /// whether a filename failed recently enough that it isn't worth asking
    /// the server again yet
    private func isCoolingDown(_ filename: String) -> Bool {
        guard let failedAt = failures[filename] else { return false }
        guard now().timeIntervalSince(failedAt) < Self.retryInterval else {
            failures[filename] = nil
            return false
        }
        return true
    }

    private func acquireSlot(_ priority: Priority) async {
        if running < Self.concurrentFetches {
            running += 1
            return
        }
        // resumed holding the slot the releasing fetch handed over, so the
        // running count doesn't move
        await withCheckedContinuation { continuation in
            waiting.append((priority, continuation))
        }
    }

    private func releaseSlot() {
        guard !waiting.isEmpty else {
            running -= 1
            return
        }
        let index = waiting.firstIndex { $0.priority == .nowPlaying } ?? waiting.startIndex
        waiting.remove(at: index).continuation.resume()
    }
}
