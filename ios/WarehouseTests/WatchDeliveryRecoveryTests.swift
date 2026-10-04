import Foundation
import Testing
@testable import Warehouse

@Suite("delivery startup recovery", .serialized)
@MainActor
struct WatchDeliveryRecoveryTests {
    @MainActor
    final class Env {
        let files: WatchContentDeliveryTests.Env
        let metadata: WatchLibraryDeliveryTests.Env
        let settings: WatchSyncSettingsStore
        var readFails = false
        var writeFails = false
        var archiveFails = false
        var descriptorReadFails = false
        var replacementFails = false

        init() throws {
            files = try WatchContentDeliveryTests.Env()
            metadata = try WatchLibraryDeliveryTests.Env()
            let defaults = UserDefaults(suiteName: files.root.lastPathComponent)!
            settings = WatchSyncSettingsStore(defaults: defaults)
            settings.setPlaylistIds(["p1", "p2"])
        }

        var queueDirectory: URL { files.root.appending(path: "queue") }
        var publisherDirectory: URL { metadata.root.appending(path: "publisher") }

        func storage(_ repairs: Bool) -> WatchDeliveryState {
            var state = WatchDeliveryState(repairsDamage: repairs)
            let read = state.read
            let write = state.write
            state.read = { [self] url in
                if readFails || (descriptorReadFails && UUID(uuidString: url.deletingPathExtension().lastPathComponent) != nil) {
                    throw CocoaError(.fileReadNoPermission)
                }
                return try read(url)
            }
            state.write = { [self] data, url in
                if writeFails || (archiveFails && url.deletingLastPathComponent().lastPathComponent == "recovery")
                    || (replacementFails && url.lastPathComponent == "state.json") {
                    throw CocoaError(.fileWriteOutOfSpace)
                }
                try write(data, url)
            }
            return state
        }

        func services() -> PhoneWatchLibraryServices {
            PhoneWatchLibraryServices(settings: settings, makeContent: { [self] repairs in
                try PhoneWatchContentQueue(fileStore: files.files, directory: queueDirectory, transport: .init(
                    available: { self.files.transportAvailable }, outstanding: { self.files.outstanding },
                    enqueue: { file, url in self.files.outstanding.append(file); self.files.queued.append((file, url)) },
                    cancel: { id in self.files.outstanding.removeAll { $0.id == id } },
                    query: { self.files.queries.append($0) }),
                    now: { self.files.now }, schedulesRetries: false, state: storage(repairs))
            }, makePublisher: { [self] repairs in
                try PhoneWatchLibraryPublisher(database: metadata.phone, directory: publisherDirectory, transport: .init(
                    context: { self.metadata.heads.append($0) }, outstanding: { self.metadata.outstanding },
                    enqueue: { url, key in self.metadata.deliveries.append((url, key)); self.metadata.outstanding.insert(key) }),
                    state: storage(repairs))
            })
        }

        func prepare() async throws -> PhoneWatchLibraryServices {
            try await metadata.phone.replaceLibrary(with: WatchLibraryDeliveryTests.library(count: 4), sourceIdentity: "account")
            let snapshot = try files.snapshot(count: 4)
            try files.cache(snapshot)
            let services = services()
            services.publish(identity: "account")
            await services.waitForPublication()
            await services.content?.waitForWork()
            #expect(services.publisher?.errorMessage == nil)
            return services
        }

        func corrupt(_ directory: URL) throws {
            try Data("broken".utf8).write(to: directory.appending(path: "state.json"))
        }

        func archives(_ directory: URL) throws -> [URL] {
            try FileManager.default.contentsOfDirectory(at: directory.appending(path: "recovery"), includingPropertiesForKeys: nil)
        }

        func cleanUp() {
            UserDefaults(suiteName: files.root.lastPathComponent)?.removePersistentDomain(forName: files.root.lastPathComponent)
            files.cleanUp()
            metadata.cleanUp()
        }
    }

    @Test("transient startup read and write failures recover both services in the same process", arguments: [false, true])
    func transientPhoneFailure(write: Bool) async throws {
        let env = try Env()
        defer { env.cleanUp() }
        let original = try await env.prepare()
        let head = try #require(original.publisher?.head)
        let files = env.files.outstanding
        let queueBytes = try Data(contentsOf: env.queueDirectory.appending(path: "state.json"))
        let publisherBytes = try Data(contentsOf: env.publisherDirectory.appending(path: "state.json"))
        env.readFails = !write
        env.writeFails = write
        let services = env.services()
        services.publish(identity: "account")
        #expect(services.content == nil && services.publisher == nil)
        #expect(env.settings.progress().state == .deliveryUnavailable)
        #expect(env.settings.playlistIds == ["p1", "p2"])
        #expect(try Data(contentsOf: env.queueDirectory.appending(path: "state.json")) == queueBytes)
        #expect(try Data(contentsOf: env.publisherDirectory.appending(path: "state.json")) == publisherBytes)
        env.settings.onRetryDelivery()
        #expect(env.settings.deliveryStartupError != nil)
        // restoration plus an ordinary lifecycle publication retries without repairing valid journals.
        env.readFails = false
        env.writeFails = false
        services.publish(identity: "account")
        await services.waitForPublication()
        await services.content?.waitForWork()
        #expect(services.content != nil && services.publisher?.head == head)
        #expect(env.settings.deliveryStartupError == nil && !env.settings.deliveryRecovered)
        #expect(env.files.outstanding == files && env.files.queued.count == files.count)
        #expect(!FileManager.default.fileExists(atPath: env.queueDirectory.appending(path: "recovery").path))
        #expect(!FileManager.default.fileExists(atPath: env.publisherDirectory.appending(path: "recovery").path))
        env.settings.setPlaylistIds([])
        env.readFails = true
        let failed = env.services()
        failed.publish(identity: "account")
        #expect(env.settings.progress().state == .deliveryUnavailable)
    }

    @Test("retry archives damaged phone journals, reuses private sources and fences a replaced publisher")
    func damagedPhoneState() async throws {
        let env = try Env()
        defer { env.cleanUp() }
        let initial = try await env.prepare()
        let oldHead = try #require(initial.publisher?.head)
        let oldFiles = env.files.outstanding
        let metadataReceiver = env.metadata.receiver()
        metadataReceiver.expect(oldHead)
        try env.metadata.stage(0)
        metadataReceiver.received()
        await metadataReceiver.waitForImport()
        #expect(metadataReceiver.snapshot?.head == oldHead)
        for file in oldFiles { try env.files.files.delete(file.type, file.filename) }
        try env.corrupt(env.queueDirectory)
        try env.corrupt(env.publisherDirectory)
        let services = env.services()
        services.publish(identity: "account")
        #expect(env.settings.progress().state == .deliveryUnavailable)
        #expect(services.content == nil && services.publisher == nil)
        env.settings.onRetryDelivery()
        await services.waitForPublication()
        await services.content?.waitForWork()
        let head = try #require(services.publisher?.head)
        let queue = try #require(services.content)
        #expect(head.publisher != oldHead.publisher && head.metadataReady)
        #expect(env.settings.deliveryRecovered && env.settings.deliveryStartupError == nil)
        #expect(env.settings.playlistIds == ["p1", "p2"])
        #expect(queue.progress().music.downloaded == 0 && queue.progress().state == .waiting)
        #expect(env.files.outstanding == oldFiles)
        for file in oldFiles {
            #expect(file.matches(env.queueDirectory.appending(path: file.id.uuidString)))
        }
        #expect(try Data(contentsOf: #require(env.archives(env.queueDirectory).first)) == Data("broken".utf8))
        #expect(try Data(contentsOf: #require(env.archives(env.publisherDirectory).first)) == Data("broken".utf8))
        // outstanding metadata files also stay immutable while the system owns them.
        #expect(FileManager.default.fileExists(atPath: env.metadata.deliveries[0].0.path))
        metadataReceiver.expect(head)
        try env.metadata.stage(1)
        metadataReceiver.received()
        await metadataReceiver.waitForImport()
        metadataReceiver.expect(oldHead)
        await metadataReceiver.waitForImport()
        #expect(metadataReceiver.head == head && metadataReceiver.snapshot?.head == head)
        let snapshot = try #require(metadataReceiver.snapshot)
        let receiver = try env.files.receiver()
        try await receiver.settledReconcile(head: head, snapshot: snapshot)
        let oldFile = try #require(oldFiles.first)
        try env.files.stage(oldFile, url: env.queueDirectory.appending(path: oldFile.id.uuidString))
        await receiver.settledResume()
        #expect(!env.files.watchFiles.exists(oldFile.type, oldFile.filename))
        try await queue.settledReceive(.init(file: oldFile, status: .delivered))
        #expect(queue.progress().music.downloaded == 0)
        env.files.outstanding.removeAll()
        await queue.settledResume()
        var delivered = Set<UUID>()
        while let file = env.files.outstanding.first {
            #expect(file.head == head && !oldFiles.contains(file))
            let url = try #require(env.files.queued.first { $0.0 == file }?.1)
            try env.files.stage(file, url: url)
            await receiver.settledResume()
            env.files.outstanding.removeAll { $0.id == file.id }
            try await queue.settledReceive(try #require(env.files.receipts.last { $0.file == file }))
            delivered.insert(file.id)
        }
        #expect(delivered.count == 5)
        #expect(queue.progress().music.downloaded == 4 && queue.progress().state == .ready)
        #expect(receiver.progress().music.downloaded == 4)
        #expect(env.files.files.entries(.music).isEmpty)
    }

    @Test("rebuilding a queue recovers lost receipts by querying verified watch bytes without fabricating progress")
    func damagedQueueOnly() async throws {
        let env = try Env()
        defer { env.cleanUp() }
        let original = try await env.prepare()
        let head = try #require(original.publisher?.head)
        let snapshot = try JSONDecoder().decode(WatchLibrarySnapshot.self, from: Data(contentsOf: env.metadata.deliveries[0].0))
        let receiver = try env.files.receiver()
        try await receiver.settledReconcile(head: head, snapshot: snapshot)
        let (file, source) = try #require(env.files.queued.first)
        try env.files.stage(file, url: source)
        await receiver.settledResume()
        env.files.outstanding.removeAll { $0.id == file.id }
        try env.files.files.delete(file.type, file.filename)
        let descriptor = env.queueDirectory.appending(path: "\(file.id.uuidString).json")
        try FileManager.default.removeItem(at: descriptor)
        _ = try env.files.queue()
        #expect(FileManager.default.fileExists(atPath: descriptor.path))
        let unidentified = env.queueDirectory.appending(path: UUID().uuidString)
        try Data("unidentified bytes".utf8).write(to: unidentified)
        try env.corrupt(env.queueDirectory)
        let services = env.services()
        services.publish(identity: "account")
        env.settings.onRetryDelivery()
        await services.waitForPublication()
        await services.content?.waitForWork()
        let queue = try #require(services.content)
        #expect(services.publisher?.head == head)
        #expect(queue.progress().music.downloaded == 0)
        #expect(env.files.queries.contains(file))
        try await receiver.settledQuery(file)
        try await queue.settledReceive(try #require(env.files.receipts.last { $0.file == file }))
        #expect(queue.progress().music.downloaded == 1)
        #expect(env.files.queued.filter { $0.0.id == file.id }.count == 1)
        env.settings.setPlaylistIds([])
        services.publish(identity: "account")
        await services.waitForPublication()
        await services.content?.waitForWork()
        #expect(try Data(contentsOf: unidentified) == Data("unidentified bytes".utf8))
        let restored = env.services()
        restored.publish(identity: "account")
        await restored.waitForPublication()
        await restored.content?.waitForWork()
        #expect(try Data(contentsOf: unidentified) == Data("unidentified bytes".utf8))
    }

    @Test("recovered private sources cannot cross account namespaces")
    func recoveryAccountChange() async throws {
        let env = try Env()
        defer { env.cleanUp() }
        _ = try await env.prepare()
        let oldFiles = env.files.outstanding
        for file in oldFiles { try env.files.files.delete(file.type, file.filename) }
        try env.corrupt(env.queueDirectory)
        try await env.metadata.phone.replaceLibrary(with: WatchLibraryDeliveryTests.library(count: 4), sourceIdentity: "new-account")
        let services = env.services()
        services.publish(identity: "new-account")
        env.settings.onRetryDelivery()
        await services.waitForPublication()
        await services.content?.waitForWork()
        let queue = try #require(services.content)
        #expect(services.publisher?.head.libraryID == "new-account")
        #expect(queue.jobs.filter { $0.type == .music }.allSatisfy { $0.file == nil })
        #expect(queue.progress().state == .needsPhoneSync && queue.progress().music.downloaded == 0)
        #expect(env.files.outstanding == oldFiles && env.files.queued.count == 4)
        for file in oldFiles { #expect(file.matches(env.queueDirectory.appending(path: file.id.uuidString))) }
    }

    @Test("temporary descriptor read failure preserves the damaged queue and retries source recovery")
    func interruptedDescriptorRecovery() async throws {
        let env = try Env()
        defer { env.cleanUp() }
        _ = try await env.prepare()
        try env.corrupt(env.queueDirectory)
        let services = env.services()
        services.publish(identity: "account")
        env.descriptorReadFails = true
        env.settings.onRetryDelivery()
        #expect(services.content == nil && env.settings.deliveryStartupError != nil)
        #expect(try Data(contentsOf: env.queueDirectory.appending(path: "state.json")) == Data("broken".utf8))
        env.descriptorReadFails = false
        env.settings.onRetryDelivery()
        await services.waitForPublication()
        await services.content?.waitForWork()
        #expect(services.content != nil && env.settings.deliveryStartupError == nil)
        #expect(env.files.queued.count == 4)
    }

    @Test("failed archive or replacement leaves damaged bytes intact for a later in-app retry", arguments: [false, true])
    func interruptedQuarantine(replacement: Bool) async throws {
        let env = try Env()
        defer { env.cleanUp() }
        _ = try await env.prepare()
        try env.corrupt(env.queueDirectory)
        try env.corrupt(env.publisherDirectory)
        let services = env.services()
        services.publish(identity: "account")
        env.archiveFails = !replacement
        env.replacementFails = replacement
        env.settings.onRetryDelivery()
        #expect(services.content == nil && services.publisher == nil)
        #expect(env.settings.progress().state == .deliveryUnavailable)
        #expect(try Data(contentsOf: env.queueDirectory.appending(path: "state.json")) == Data("broken".utf8))
        #expect(try Data(contentsOf: env.publisherDirectory.appending(path: "state.json")) == Data("broken".utf8))
        env.archiveFails = false
        env.replacementFails = false
        env.settings.onRetryDelivery()
        await services.waitForPublication()
        await services.content?.waitForWork()
        #expect(services.content != nil && services.publisher?.head.metadataReady == true)
        #expect(env.settings.deliveryStartupError == nil)
    }

    @Test("watch recovery preserves staged bytes, repairs verified receipts and retries journal writes", arguments: [false, true])
    func damagedWatchState(replacement: Bool) async throws {
        let env = try WatchContentDeliveryTests.Env()
        defer { env.cleanUp() }
        let metadata = try WatchLibraryDeliveryTests.Env()
        defer { metadata.cleanUp() }
        let snapshot = try env.snapshot(count: 4)
        try env.cache(snapshot)
        let queue = try env.queue()
        try await queue.settledReconcile(head: snapshot.head, snapshot: snapshot)
        let first = env.queued[0]
        let second = env.queued[1]
        try env.watchFiles.write(first.0.type, first.0.filename, data: Data(contentsOf: first.1))
        try env.stage(second.0, url: second.1)
        _ = try await metadata.watch.expectWatchLibrary(snapshot.head)
        _ = try await metadata.watch.importWatchLibrary(snapshot)
        let inbox = env.root.appending(path: "receiver")
        let ledger = inbox.appending(path: "receipts.json")
        try Data("broken".utf8).write(to: ledger)
        var failWrites = true
        var state = WatchDeliveryState()
        let write = state.write
        state.write = { data, url in
            if failWrites && (!replacement || url.lastPathComponent == "receipts.json") { throw CocoaError(.fileWriteOutOfSpace) }
            try write(data, url)
        }
        let defaults = UserDefaults(suiteName: env.root.lastPathComponent)!
        defer { defaults.removePersistentDomain(forName: env.root.lastPathComponent) }
        let services = WatchLibraryServices(database: metadata.watch, fileStore: env.watchFiles, defaults: defaults,
                                           metadataDirectory: metadata.inbox, contentDirectory: inbox,
                                           sendReceipt: { env.receipts.append($0) }, contentState: state)
        services.availableBytes = { env.available }
        await services.launch()
        #expect(services.library.state == .ready && services.content == nil)
        #expect(services.library.progress().state == .deliveryUnavailable)
        #expect(env.receipts.isEmpty)
        await services.refresh()
        #expect(services.content == nil && services.library.deliveryStartupError != nil)
        #expect(try Data(contentsOf: ledger) == Data("broken".utf8))
        #expect(second.0.matches(inbox.appending(path: second.0.id.uuidString).appending(path: "bytes")))
        #expect(first.0.matches(env.watchFiles.fileURL(first.0.type, first.0.filename)))
        failWrites = false
        await services.refresh()
        let content = try #require(services.content)
        await content.waitForWork()
        #expect(services.library.deliveryStartupError == nil && services.library.deliveryRecovered)
        #expect(services.library.state == .ready)
        #expect(services.library.progress().music.downloaded == 2)
        #expect(env.receipts == [.init(file: second.0, status: .delivered)])
        #expect(first.0.matches(env.watchFiles.fileURL(first.0.type, first.0.filename)))
        #expect(second.0.matches(env.watchFiles.fileURL(second.0.type, second.0.filename)))
        // presence can support local playback, but an acknowledgment still requires a matching query and verified bytes.
        try await content.settledQuery(first.0)
        #expect(env.receipts.last == .init(file: first.0, status: .delivered))
        try await queue.settledReceive(try #require(env.receipts.last))
        #expect(queue.progress().music.downloaded == 1)
        let restored = WatchLibraryServices(database: metadata.watch, fileStore: env.watchFiles, defaults: defaults,
                                            metadataDirectory: metadata.inbox, contentDirectory: inbox)
        await restored.launch()
        await restored.content?.waitForWork()
        #expect(restored.library.deliveryStartupError == nil && restored.content?.receipts.count == 2)
        #expect(restored.library.progress().music.downloaded == 2)
    }

    @Test("watch startup retries temporary read failures without rebuilding valid receipts")
    func transientWatchRead() async throws {
        let env = try WatchLibraryStoreTests.Env()
        defer { env.cleanUp() }
        try await env.save()
        let inbox = env.root.appending(path: "content")
        try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        let ledger = inbox.appending(path: "receipts.json")
        try Data("[]".utf8).write(to: ledger)
        var failReads = true
        var state = WatchDeliveryState()
        let read = state.read
        state.read = { url in
            if failReads { throw CocoaError(.fileReadNoPermission) }
            return try read(url)
        }
        let services = WatchLibraryServices(database: env.database, fileStore: env.files, defaults: env.defaults,
                                           metadataDirectory: env.root.appending(path: "metadata"), contentDirectory: inbox,
                                           contentState: state)
        await services.launch()
        #expect(services.library.state == .ready && services.content == nil)
        await services.refresh()
        #expect(services.library.progress().state == .deliveryUnavailable)
        #expect(try Data(contentsOf: ledger) == Data("[]".utf8))
        failReads = false
        await services.launch()
        #expect(services.content != nil && services.library.deliveryStartupError == nil)
        #expect(!services.library.deliveryRecovered)
        #expect(services.library.state == .ready && env.files.exists(.music, "local.wav"))
        #expect(!FileManager.default.fileExists(atPath: inbox.appending(path: "recovery").path))
    }
}
