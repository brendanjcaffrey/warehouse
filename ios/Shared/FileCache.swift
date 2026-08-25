import Foundation

/// how much disk each file type may hold before eviction starts
struct FileCacheBudget: Equatable, Sendable {
    var music: Int64
    var artwork: Int64

    subscript(type: LibraryFileType) -> Int64 {
        switch type {
        case .music: music
        case .artwork: artwork
        }
    }

    /// sized against the space the cache could occupy — what's free right now
    /// plus what it already holds, since evicting hands that back. sizing it
    /// against free space alone would pull the ceiling down every time the
    /// cache grew, and the cache would chase it the whole way to nothing.
    static func forDevice(heldBytes: Int64) -> FileCacheBudget {
        forSpace((FileStore.deviceStorage()?.availableBytes ?? 0) + heldBytes)
    }

    /// half the space for music, floored so a nearly full disk still caches a
    /// few tracks & capped so a roomy one isn't handed over whole. artwork is
    /// small and hot, so it gets its own slice rather than competing with
    /// tracks hundreds of times its size
    static func forSpace(_ bytes: Int64) -> FileCacheBudget {
        FileCacheBudget(
            music: clamp(bytes / 2, low: 256_000_000, high: 16_000_000_000),
            artwork: clamp(bytes / 20, low: 16_000_000, high: 1_000_000_000))
    }

    private static func clamp(_ value: Int64, low: Int64, high: Int64) -> Int64 {
        Swift.min(Swift.max(value, low), high)
    }
}

/// bounds the files the watch pulls on demand to a disk budget, evicting the
/// least recently used first. the phone mirrors the whole library and has no
/// cache: on that side `FileStore.deleteFiles(_:keeping:)` still decides what
/// stays. recency is kept in a sidecar index rather than read from the
/// filesystem's access dates, so a use is recorded at the moment a track
/// actually starts instead of whenever avfoundation happens to touch the bytes
@MainActor
final class FileCache {
    let fileStore: FileStore

    /// called whenever the music files held change — one lands or eviction
    /// takes one — so the watch's rows can refresh which tracks are cached.
    /// the phone mirrors the library & has no cache to leave a listener on
    var onMusicChanged: (@MainActor () -> Void)?

    private let budget: @MainActor (Int64) -> FileCacheBudget
    private let now: @Sendable () -> Date
    /// type directory -> filename -> seconds since the epoch
    private var recency: [String: [String: Double]]
    /// files that must survive eviction: the track playing & anything
    /// prefetched behind it, keyed the same way
    private var inUse: [String: Set<String>] = [:]

    init(
        fileStore: FileStore,
        budget: @escaping @MainActor (Int64) -> FileCacheBudget = FileCacheBudget.forDevice,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.fileStore = fileStore
        self.budget = budget
        self.now = now
        self.recency = Self.load(from: Self.indexURL(fileStore))
    }

    /// marks a file as just used, so eviction sees it as the newest
    func recordUse(_ type: LibraryFileType, _ filename: String) {
        recency[type.directory, default: [:]][filename] = now().timeIntervalSince1970
        save()
    }

    /// notes a music file landing on disk, so anything showing what the cache
    /// holds picks it up. the recency index is deliberately left alone: a
    /// prefetched track hasn't been played, & the player records the tracks it
    /// actually starts itself
    func noteMusicStored() {
        onMusicChanged?()
    }

    /// replaces the set of files of one type that eviction may not touch,
    /// so starting a track both protects the new file & releases the old one
    func setInUse(_ type: LibraryFileType, _ filenames: Set<String>) {
        inUse[type.directory] = filenames
    }

    /// how much more music the cache could take before what it already holds
    /// fills the music budget. this is the question a fill that runs deep into
    /// a queue has to ask: the files it pulls are evictable as soon as the
    /// protection window slides past them, so measuring against the in-use set
    /// instead would say there was room right up until the disk was full, and
    /// every track pulled after that would evict one pulled a minute earlier.
    /// goes negative once the music on disk is over budget, which the fetch of
    /// a track about to play is allowed to do — that one ignores the answer
    /// and eviction makes the room back
    func musicRoom() -> Int64 {
        var held: Int64 = 0
        var musicBytes: Int64 = 0
        for type in LibraryFileType.allCases {
            let bytes = fileStore.entries(type).reduce(0) { $0 + $1.sizeBytes }
            if type == .music {
                musicBytes = bytes
            }
            held += bytes
        }
        return budget(held).music - musicBytes
    }

    /// drops least recently used files until each type is back under budget,
    /// returning what it removed. runs after a fetch, never on a timer
    @discardableResult
    func evict() -> [FileToDownload] {
        var entries: [LibraryFileType: [FileEntry]] = [:]
        var held: Int64 = 0
        for type in LibraryFileType.allCases {
            let typeEntries = fileStore.entries(type)
            entries[type] = typeEntries
            held += typeEntries.reduce(0) { $0 + $1.sizeBytes }
        }

        let budget = self.budget(held)
        var removed: [FileToDownload] = []
        for type in LibraryFileType.allCases {
            removed += evict(type, entries: entries[type] ?? [], budget: budget[type])
        }
        save()
        if removed.contains(where: { $0.type == .music }) {
            onMusicChanged?()
        }
        return removed
    }

    private func evict(_ type: LibraryFileType, entries: [FileEntry], budget: Int64) -> [FileToDownload] {
        prune(type, entries: entries)
        var total = entries.reduce(0) { $0 + $1.sizeBytes }
        guard total > budget else { return [] }

        let protected = inUse[type.directory] ?? []
        let ordered = entries.sorted { lastUsed($0, type) < lastUsed($1, type) }
        // the newest file is never a candidate: it is the one just fetched far
        // more often than not, and skipping it also makes a store holding a
        // single file bigger than the whole budget a no-op instead of a
        // delete followed by an immediate refetch of the same track
        let candidates = ordered.dropLast().filter { !protected.contains($0.filename) }

        var removed: [FileToDownload] = []
        for entry in candidates {
            guard total > budget else { break }
            guard (try? fileStore.delete(type, entry.filename)) != nil else { continue }
            total -= entry.sizeBytes
            recency[type.directory]?[entry.filename] = nil
            removed.append(FileToDownload(type: type, filename: entry.filename))
        }
        return removed
    }

    /// when the index has nothing for a file — anything the old mirror sync
    /// left behind — its creation date stands in, which puts leftovers ahead
    /// of anything actually played
    private func lastUsed(_ entry: FileEntry, _ type: LibraryFileType) -> Date {
        guard let seconds = recency[type.directory]?[entry.filename] else { return entry.createdAt }
        return Date(timeIntervalSince1970: seconds)
    }

    /// forgets index entries whose files are gone, so a store that filled and
    /// emptied a few times doesn't carry the names forever
    private func prune(_ type: LibraryFileType, entries: [FileEntry]) {
        guard var kept = recency[type.directory] else { return }
        let onDisk = Set(entries.map(\.filename))
        kept = kept.filter { onDisk.contains($0.key) }
        recency[type.directory] = kept.isEmpty ? nil : kept
    }

    private static func indexURL(_ fileStore: FileStore) -> URL {
        fileStore.rootURL.appending(path: "recency.json")
    }

    private static func load(from url: URL) -> [String: [String: Double]] {
        guard let data = try? Data(contentsOf: url),
              let index = try? JSONDecoder().decode([String: [String: Double]].self, from: data)
        else { return [:] }
        return index
    }

    private func save() {
        let url = Self.indexURL(fileStore)
        guard let data = try? JSONEncoder().encode(recency) else { return }
        try? FileManager.default.createDirectory(
            at: fileStore.rootURL, withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}
