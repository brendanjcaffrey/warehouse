import Foundation
import Testing
@testable import Warehouse

@Suite("watch selection persistence recovery", .serialized)
@MainActor
struct WatchSelectionRecoveryTests {
    @Test("failed selection persistence answers queries without committing and resumes after retry",
          arguments: [CocoaError.Code.fileWriteOutOfSpace, .fileWriteUnknown])
    func failedSelectionSave(code: CocoaError.Code) async throws {
        let env = try WatchContentDeliveryTests.Env()
        defer { env.cleanUp() }
        let snapshot = try env.snapshot(count: 2)
        try env.cache(snapshot)
        let queue = try env.queue()
        try await queue.settledReconcile(head: snapshot.head, snapshot: snapshot)
        let (file, source) = try #require(env.queued.first)
        try env.stage(file, url: source)
        var fails = true
        let cache = FileCache(fileStore: env.watchFiles, beforeWatchSelectionSave: {
            if fails { throw CocoaError(code) }
        })
        let disk = WatchDeliveryState()
        var state = disk
        state.write = { data, url in
            if fails { throw CocoaError(code) }
            try disk.write(data, url)
        }
        let receiver = try WatchContentReceiver(fileCache: cache, directory: env.root.appending(path: "receiver"),
                                                send: { env.receipts.append($0) }, state: state)
        receiver.pause()
        #expect(throws: CocoaError.self) { try receiver.reconcile(head: snapshot.head, snapshot: snapshot) }
        #expect(receiver.errorMessage != nil)
        try await receiver.settledQuery(file)
        let expected: WatchContentStatus = code == .fileWriteOutOfSpace ? .storageFull : .retrying
        #expect(env.receipts.last?.status == expected)
        #expect(!env.watchFiles.exists(file.type, file.filename))
        #expect(!cache.hasDurableWatchSelection)
        #expect(receiver.progress().music.downloaded == 0)
        env.receipts.removeAll()
        await receiver.settledStaged(file)
        #expect(env.receipts.last?.status == expected)
        env.receipts.removeAll()
        await receiver.settledStagingFailed(file, error: CocoaError(code))
        #expect(env.receipts.last?.status == expected)
        #expect(receiver.receipts.isEmpty)
        env.receipts.removeAll()
        receiver.pause()
        try await receiver.settledQuery(file)
        await receiver.settledResume()
        #expect(env.receipts.isEmpty)
        #expect(throws: CocoaError.self) { try receiver.reconcile(head: snapshot.head, snapshot: snapshot) }
        await receiver.settledResume()
        #expect(!env.watchFiles.exists(file.type, file.filename))
        fails = false
        await receiver.settledResume()
        #expect(receiver.errorMessage == nil)
        #expect(cache.hasDurableWatchSelection)
        #expect(file.matches(env.watchFiles.fileURL(file.type, file.filename)))
        #expect(env.receipts.last?.status == .delivered)
    }

    @Test("failed replacement retains old progress and rejects unrelated queries",
          arguments: ["publisher", "account", "future", "filename", "type", "invalid"])
    func failedReplacement(change: String) async throws {
        let env = try WatchContentDeliveryTests.Env()
        defer { env.cleanUp() }
        var fails = false
        let cache = FileCache(fileStore: env.watchFiles, beforeWatchSelectionSave: {
            if fails { throw CocoaError(.fileWriteOutOfSpace) }
        })
        let receiver = try WatchContentReceiver(fileCache: cache, directory: env.root.appending(path: "receiver"),
                                                send: { env.receipts.append($0) })
        let original = try env.snapshot(count: 2)
        try env.watchFiles.write(.music, "m0.mp3", data: Data("retained".utf8))
        try await receiver.settledReconcile(head: original.head, snapshot: original)
        let progress = receiver.progress()
        let next = try env.snapshot(count: 3, revision: 2)
        try env.cache(next)
        let queue = try env.queue()
        try await queue.settledReconcile(head: next.head, snapshot: next)
        let (file, source) = try #require(env.queued.first { $0.0.filename == "m2.mp3" })
        try env.stage(file, url: source)
        fails = true
        receiver.pause()
        #expect(throws: CocoaError.self) { try receiver.reconcile(head: next.head, snapshot: next) }
        #expect(receiver.progress().music == progress.music)
        let head = WatchLibraryHead(publisher: change == "publisher" ? UUID() : next.head.publisher,
                                    revision: next.head.revision + (change == "future" ? 1 : 0),
                                    libraryID: change == "account" ? "other" : next.head.libraryID,
                                    playlistIDs: next.head.playlistIDs, metadataReady: true)
        let unrelated = WatchContentFile(head: head, type: change == "type" ? .artwork : file.type,
                                         filename: change == "filename" ? "unselected.mp3" : file.filename,
                                         bytes: file.bytes, digest: change == "invalid" ? "invalid" : file.digest)
        try await receiver.settledQuery(unrelated)
        #expect(env.receipts.isEmpty)
        try await receiver.settledQuery(file)
        #expect(env.receipts.last?.status == .storageFull)
        #expect(!env.watchFiles.exists(file.type, file.filename))
        let restored = FileCache(fileStore: env.watchFiles)
        #expect(restored.hasDurableWatchSelection)
        restored.evict()
        #expect(env.watchFiles.exists(.music, "m0.mp3"))
        fails = false
        await receiver.settledResume()
        #expect(file.matches(env.watchFiles.fileURL(file.type, file.filename)))
        #expect(receiver.progress().music.downloaded == 2)
    }

    @Test("invalid metadata surfaces its error without authorizing failure replies or commits")
    func invalidSnapshot() async throws {
        let env = try WatchContentDeliveryTests.Env()
        defer { env.cleanUp() }
        let snapshot = try env.snapshot(count: 2)
        try env.cache(snapshot)
        let queue = try env.queue()
        try await queue.settledReconcile(head: snapshot.head, snapshot: snapshot)
        let (file, source) = try #require(env.queued.first)
        try env.stage(file, url: source)
        let receiver = try env.receiver()
        let invalid = WatchLibrarySnapshot(head: snapshot.head, libraryData: Data("invalid".utf8))
        receiver.pause()
        #expect(throws: (any Error).self) { try receiver.reconcile(head: snapshot.head, snapshot: invalid) }
        #expect(receiver.errorMessage != nil)
        try await receiver.settledQuery(file)
        await receiver.settledResume()
        #expect(env.receipts.isEmpty)
        #expect(!env.watchFiles.exists(file.type, file.filename))
        try await receiver.settledReconcile(head: snapshot.head, snapshot: snapshot)
        #expect(receiver.errorMessage == nil)
        #expect(file.matches(env.watchFiles.fileURL(file.type, file.filename)))
    }

    @Test("production metadata callbacks surface selection-save errors and recover on refresh")
    func productionFailure() async throws {
        let env = try await WatchLibraryServicesTests.StatusEnv()
        defer { env.cleanUp() }
        let services = env.services
        let selection = services.fileCache.fileStore.rootURL.appending(path: "watch-selection.json")
        try FileManager.default.createDirectory(at: selection, withIntermediateDirectories: true)
        await services.launch()
        let content = try #require(services.content)
        #expect(content.errorMessage != nil)
        let head = try #require(services.receiver.head)
        env.session.applyContext(try head.encode())
        await services.receiver.waitForImport()
        #expect(content.errorMessage != nil)
        #expect(!services.fileCache.hasDurableWatchSelection)
        #expect(services.library.state == .ready)
        #expect(services.fileCache.fileStore.exists(.music, "m0.mp3"))
        try FileManager.default.removeItem(at: selection)
        await services.refresh()
        await content.waitForWork()
        #expect(content.errorMessage == nil)
        #expect(services.fileCache.hasDurableWatchSelection)
        #expect(services.library.progress().music.downloaded == 1)
    }
}
