import Foundation
import Observation
import Testing
import UIKit
@testable import Warehouse

@Suite("watch thumbnail requests", .serialized)
@MainActor
struct WatchArtworkThumbnailTests {
    static func bytes(_ color: UIColor = .red) -> Data {
        UIGraphicsImageRenderer(size: CGSize(width: 16, height: 16)).pngData { context in
            color.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 16, height: 16))
        }
    }

    @Test("unrelated artwork and music deliveries do not invalidate a settled thumbnail")
    func unrelatedDelivery() async throws {
        let files = FileCacheTests.makeStore()
        defer { try? FileManager.default.removeItem(at: files.rootURL) }
        try files.write(.artwork, "cover.png", data: Self.bytes())
        let cache = FileCache(fileStore: files)
        let fetcher = WatchArtworkFetcher(fileCache: cache)
        let request = fetcher.request("cover.png")
        let thumbnail = WatchArtworkThumbnailState()
        await thumbnail.load(request)
        let image = try #require(thumbnail.image)
        let changes = WatchProgressCacheTests.Probes()
        withObservationTracking {
            _ = fetcher.request("cover.png")
        } onChange: { changes.record() }
        for index in 0..<100 {
            let name = "other\(index).png"
            try files.write(.artwork, name, data: Self.bytes(.blue))
            cache.noteFileStored(.artwork, name)
            cache.noteMusicStored()
            #expect(fetcher.request("cover.png") == request)
            #expect(thumbnail.image === image)
        }
        // a duplicate receipt for unchanged bytes does not restart the task either.
        cache.noteFileStored(.artwork, "cover.png")
        let invalidations = changes.count
        #expect(invalidations == 0)
        #expect(fetcher.request("cover.png") == request)
    }

    @Test("production delivery changes only the requested placeholder even if its receipt cannot save")
    func requestedDelivery() async throws {
        let env = try WatchContentDeliveryTests.Env()
        defer { env.cleanUp() }
        let snapshot = try env.snapshot(count: 2)
        let cache = FileCache(fileStore: env.watchFiles, freeSpaceReserve: 0)
        let fetcher = WatchArtworkFetcher(fileCache: cache)
        let receiver = try WatchContentReceiver(fileCache: cache, directory: env.root.appending(path: "receiver"),
                                               send: { _ in }, beforeReceipt: { throw CocoaError(.fileWriteUnknown) })
        try await receiver.settledReconcile(head: snapshot.head, snapshot: snapshot)
        let filename = "a1.jpg"
        let placeholder = fetcher.request(filename)
        #expect(placeholder.url == nil)
        let thumbnail = WatchArtworkThumbnailState()
        await thumbnail.load(placeholder)
        #expect(thumbnail.image == nil)
        let changes = WatchProgressCacheTests.Probes()
        withObservationTracking {
            _ = fetcher.request(filename)
        } onChange: { changes.record() }
        let source = env.root.appending(path: "source")
        try Self.bytes().write(to: source)
        let fingerprint = try WatchContentFile.fingerprint(source)
        let file = WatchContentFile(head: snapshot.head, type: .artwork, filename: filename,
                                   bytes: fingerprint.bytes, digest: fingerprint.digest)
        try env.stage(file, url: source)
        await receiver.settledStaged(file)
        #expect(receiver.errorMessage != nil)
        #expect(changes.count == 1)
        let delivered = fetcher.request(filename)
        #expect(delivered != placeholder && delivered.url != nil)
        await thumbnail.load(delivered)
        #expect(thumbnail.image != nil)
    }

    @Test("filename and size changes, replacement, removal and redelivery have distinct identities")
    func identityChanges() async throws {
        let files = FileCacheTests.makeStore()
        defer { try? FileManager.default.removeItem(at: files.rootURL) }
        try files.write(.artwork, "cover.png", data: Self.bytes())
        let cache = FileCache(fileStore: files)
        let fetcher = WatchArtworkFetcher(fileCache: cache)
        let first = fetcher.request("cover.png")
        #expect(fetcher.request("cover.png", maxPixelSize: 132) != first)
        #expect(fetcher.request("missing.png") != fetcher.request("other-missing.png"))
        #expect(fetcher.request(nil) != fetcher.request(nil, maxPixelSize: 132))
        #expect(fetcher.request("../cover.png").url == nil)
        let changes = WatchProgressCacheTests.Probes()
        withObservationTracking {
            _ = fetcher.request("cover.png")
        } onChange: { changes.record() }
        try files.write(.artwork, "cover.png", data: Self.bytes(.blue))
        cache.noteFileStored(.artwork, "cover.png")
        let replacement = fetcher.request("cover.png")
        #expect(changes.count == 1 && replacement != first)
        let thumbnail = WatchArtworkThumbnailState()
        await thumbnail.load(replacement)
        #expect(thumbnail.image != nil)
        try cache.adoptWatchSelection(music: [], artwork: [])
        let removed = fetcher.request("cover.png")
        #expect(removed.url == nil && removed != replacement)
        await thumbnail.load(removed)
        #expect(thumbnail.image == nil)
        try files.write(.artwork, "cover.png", data: Self.bytes(.blue))
        cache.noteFileStored(.artwork, "cover.png")
        #expect(fetcher.request("cover.png") != replacement)
    }

    @Test("cache eviction and storage admission invalidate just the removed artwork")
    func evictedArtwork() throws {
        let files = FileCacheTests.makeStore()
        defer { try? FileManager.default.removeItem(at: files.rootURL) }
        let cache = FileCache(fileStore: files, budget: { _ in .init(music: 1000, artwork: 0) }, freeSpaceReserve: 0)
        let fetcher = WatchArtworkFetcher(fileCache: cache)
        try files.write(.artwork, "old.png", data: Self.bytes())
        try files.write(.artwork, "new.png", data: Self.bytes())
        cache.recordUse(.artwork, "new.png")
        #expect(fetcher.request("old.png").url != nil)
        let newest = fetcher.request("new.png")
        #expect(cache.evict().contains(.init(type: .artwork, filename: "old.png")))
        #expect(fetcher.request("old.png").url == nil)
        #expect(fetcher.request("new.png") == newest)
        // a music admission can reclaim artwork when actual free space is exhausted.
        #expect(cache.reserve(.music, "song.mp3", bytes: 1, availableBytes: 0))
        #expect(fetcher.request("new.png").url == nil)
    }

    @Test("a reused row and a cancelled task reject stale decode results")
    func staleResults() async throws {
        var pending: [String: CheckedContinuation<UIImage?, Never>] = [:]
        let thumbnail = WatchArtworkThumbnailState { request in
            await withCheckedContinuation { pending[request.filename!] = $0 }
        }
        let first = WatchArtworkRequest(filename: "first", maxPixelSize: 56, url: URL(filePath: "/first"))
        let second = WatchArtworkRequest(filename: "second", maxPixelSize: 132, url: URL(filePath: "/second"))
        let oldTask = Task { await thumbnail.load(first) }
        try await PlayerStoreTests.waitFor { pending["first"] != nil }
        let newTask = Task { await thumbnail.load(second) }
        try await PlayerStoreTests.waitFor { pending["second"] != nil }
        let current = UIImage()
        pending.removeValue(forKey: "second")?.resume(returning: current)
        await newTask.value
        pending.removeValue(forKey: "first")?.resume(returning: UIImage())
        await oldTask.value
        #expect(thumbnail.image === current)
        let cancelledBeforeStart = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            await thumbnail.load(first)
        }
        await cancelledBeforeStart.value
        #expect(thumbnail.image === current)
        let cancelled = Task { await thumbnail.load(first) }
        try await PlayerStoreTests.waitFor { pending["first"] != nil }
        cancelled.cancel()
        pending.removeValue(forKey: "first")?.resume(returning: UIImage())
        await cancelled.value
        #expect(thumbnail.image == nil)
        let retry = Task { await thumbnail.load(first) }
        try await PlayerStoreTests.waitFor { pending["first"] != nil }
        pending.removeValue(forKey: "first")?.resume(returning: current)
        await retry.value
        #expect(thumbnail.image === current)
        await thumbnail.load(WatchArtworkRequest(filename: nil, maxPixelSize: 56))
        #expect(thumbnail.image == nil)
    }
}
