import CoreData
import Foundation
import SwiftProtobuf
import Testing
@testable import Warehouse

@Suite("WatchLibraryDelivery", .serialized)
@MainActor
struct WatchLibraryDeliveryTests {
    @Test("completed unchanged snapshots are not transferred again on repeated phone pushes")
    func completedSnapshot() async throws {
        let env = try Env()
        defer { env.cleanUp() }
        try await env.phone.replaceLibrary(with: Self.library(count: 4), sourceIdentity: "account")
        let publisher = try env.publisher()
        let session = PhoneWatchSession(onPlay: { _ in }, diagnostics: env.phoneDiagnostics)
        session.publishLibrary = { publisher.publish(identity: "account", playlistIDs: ["p2"]) }
        session.onMetadataFinished = { try? publisher.finished(key: $0, error: $1) }
        session.push()
        await publisher.waitForPublication()
        let key = try #require(env.deliveries.first?.1)
        env.outstanding.remove(key)
        #expect(session.receiveFileCompletion(metadata: ["kind": "watchLibrarySnapshot", "watchLibraryKey": key], error: nil))
        try await PlayerStoreTests.waitFor { env.phoneDiagnostics.events.contains { $0.kind == .metadataCompleted } }
        session.push()
        await publisher.waitForPublication()
        #expect(env.deliveries.count == 1)
    }

    @Test("completion survives restart, while an older or missing accepted head requests the current snapshot")
    func snapshotRequests() async throws {
        let env = try Env()
        defer { env.cleanUp() }
        try await env.phone.replaceLibrary(with: Self.library(count: 4), sourceIdentity: "account")
        var publisher = try env.publisher()
        publisher.publish(identity: "account", playlistIDs: ["p2"])
        await publisher.waitForPublication()
        let accepted = publisher.head
        let key = PhoneWatchLibraryPublisher.key(accepted)
        env.outstanding.remove(key)
        try publisher.finished(key: key, error: nil)
        publisher = try env.publisher()
        // a failing full-read boundary proves foreground publication uses the saved metadata revision.
        env.phone.beforeWatchLibraryRead = { throw CocoaError(.fileReadUnknown) }
        publisher.publish(identity: "account", playlistIDs: ["p2"])
        await publisher.waitForPublication()
        #expect(publisher.errorMessage == nil && env.deliveries.count == 1)
        let session = PhoneWatchSession(onPlay: { _ in })
        var requests = 0
        session.onLibraryRequest = {
            requests += 1
            publisher.publish(identity: "account", playlistIDs: ["p2"], libraryRequest: $0)
        }
        session.receive(userInfo: try WatchLibraryRequest(acceptedHead: accepted).encode())
        try await PlayerStoreTests.waitFor { requests == 1 }
        await publisher.waitForPublication()
        #expect(env.deliveries.count == 1)
        let older = WatchLibraryHead(publisher: accepted.publisher, revision: accepted.revision - 1,
                                     libraryID: accepted.libraryID, playlistIDs: accepted.playlistIDs, metadataReady: true)
        session.receive(userInfo: try WatchLibraryRequest(acceptedHead: older).encode())
        try await PlayerStoreTests.waitFor { env.deliveries.count == 2 }
        await publisher.waitForPublication()
        #expect(publisher.head == accepted && publisher.errorMessage == nil)
        env.outstanding.remove(key)
        try publisher.finished(key: key, error: nil)
        session.receive(userInfo: ["kind": "watchLibraryRequest"])
        try await PlayerStoreTests.waitFor { env.deliveries.count == 3 }
        await publisher.waitForPublication()
        #expect(env.deliveries.last?.1 == key)
    }

    @Test("failed metadata transfers retry and obsolete completions cannot suppress a newer revision")
    func snapshotFailures() async throws {
        let env = try Env()
        defer { env.cleanUp() }
        try await env.phone.replaceLibrary(with: Self.library(count: 4), sourceIdentity: "account")
        let publisher = try env.publisher()
        publisher.publish(identity: "account", playlistIDs: ["p2"])
        await publisher.waitForPublication()
        let oldKey = PhoneWatchLibraryPublisher.key(publisher.head)
        env.outstanding.remove(oldKey)
        try publisher.finished(key: oldKey, error: CocoaError(.fileReadUnknown))
        publisher.publish(identity: "account", playlistIDs: ["p2"])
        await publisher.waitForPublication()
        #expect(env.deliveries.count == 2)
        try await env.phone.updateTrack(LibraryDatabaseTests.editedSong(id: "t0", artworkFilename: "updated.jpg"))
        publisher.publish(identity: "account", playlistIDs: ["p2"])
        await publisher.waitForPublication()
        let newKey = PhoneWatchLibraryPublisher.key(publisher.head)
        #expect(newKey != oldKey && env.deliveries.count == 3)
        env.outstanding.removeAll()
        try publisher.finished(key: oldKey, error: nil)
        publisher.publish(identity: "account", playlistIDs: ["p2"])
        await publisher.waitForPublication()
        #expect(env.deliveries.count == 4 && env.deliveries.last?.1 == newKey)
    }

    @Test("failed phone metadata transactions preserve the snapshot revision and cached publication")
    func failedSourceRevision() async throws {
        let env = try Env()
        defer { env.cleanUp() }
        try await env.phone.replaceLibrary(with: Self.library(count: 4), sourceIdentity: "account")
        let revision = try await env.phone.phoneLibraryRevision(identity: "account")
        let publisher = try env.publisher()
        publisher.publish(identity: "account", playlistIDs: ["p2"])
        await publisher.waitForPublication()
        env.phone.beforeLibrarySave = { throw CocoaError(.fileWriteOutOfSpace) }
        await #expect(throws: CocoaError.self) {
            try await env.phone.replaceLibrary(with: Library(), sourceIdentity: "other")
        }
        #expect(try await env.phone.phoneLibraryRevision(identity: "account") == revision)
        env.phone.beforeWatchLibraryRead = { throw CocoaError(.fileReadUnknown) }
        publisher.publish(identity: "account", playlistIDs: ["p2"])
        await publisher.waitForPublication()
        #expect(publisher.errorMessage == nil && env.deliveries.count == 1)
    }

    @Test("failed completion persistence leaves the snapshot eligible for another transfer")
    func completionPersistenceFailure() async throws {
        let env = try Env()
        defer { env.cleanUp() }
        try await env.phone.replaceLibrary(with: Self.library(count: 4), sourceIdentity: "account")
        var fails = false
        let state = WatchDeliveryState(write: { data, url in
            if fails { throw CocoaError(.fileWriteOutOfSpace) }
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        })
        let publisher = try PhoneWatchLibraryPublisher(database: env.phone, directory: env.root.appending(path: "publisher"), transport: .init(
            context: { env.heads.append($0) }, outstanding: { env.outstanding },
            enqueue: { env.deliveries.append(($0, $1)); env.outstanding.insert($1) }), state: state)
        publisher.publish(identity: "account", playlistIDs: ["p2"])
        await publisher.waitForPublication()
        let key = PhoneWatchLibraryPublisher.key(publisher.head)
        env.outstanding.remove(key)
        fails = true
        #expect(throws: CocoaError.self) { try publisher.finished(key: key, error: nil) }
        fails = false
        publisher.publish(identity: "account", playlistIDs: ["p2"])
        await publisher.waitForPublication()
        #expect(env.deliveries.count == 2)
    }

    @Test("unselected track additions and removals leave published snapshot bytes and revision unchanged")
    func unselectedTracks() async throws {
        let env = try Env()
        defer { env.cleanUp() }
        var library = Self.library(count: 4)
        try await env.phone.replaceLibrary(with: library, sourceIdentity: "account")
        let publisher = try env.publisher()
        publisher.publish(identity: "account", playlistIDs: ["p2"])
        await publisher.waitForPublication()
        let original = publisher.head
        var options = BinaryEncodingOptions()
        options.useDeterministicOrdering = true
        let bytes = try await env.phone.selectedWatchLibrary(ids: ["p2"], identity: "account").library.serializedData(options: options)
        var unselected = library.tracks[0]
        unselected.id = "a-unselected"
        unselected.playlistIds = []
        library.tracks.append(unselected)
        try await env.phone.replaceLibrary(with: library, sourceIdentity: "account")
        publisher.publish(identity: "account", playlistIDs: ["p2"])
        await publisher.waitForPublication()
        #expect(publisher.head == original)
        #expect(try await env.phone.selectedWatchLibrary(ids: ["p2"], identity: "account").library.serializedData(options: options) == bytes)
        library.tracks.removeAll { $0.id == unselected.id }
        try await env.phone.replaceLibrary(with: library, sourceIdentity: "account")
        publisher.publish(identity: "account", playlistIDs: ["p2"])
        await publisher.waitForPublication()
        #expect(publisher.head == original)
    }

    @Test("a failed replacement preserves the last committed library")
    func failedReplacement() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let database = LibraryDatabase(storeURL: root.appending(path: "library.sqlite"))
        try await database.replaceLibrary(with: LibraryDatabaseTests.makeLibrary())
        var fail = true
        database.beforeLibrarySave = { if fail { throw CocoaError(.fileWriteOutOfSpace) } }
        await #expect(throws: CocoaError.self) { try await database.replaceLibrary(with: Library()) }
        fail = false
        #expect(try await database.trackCount() == 2)
        #expect(try await database.allPlaylists().count == 4)
    }

    @MainActor
    final class Env {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let phone: LibraryDatabase
        let watch: LibraryDatabase
        var heads = [WatchLibraryHead]()
        var deliveries = [(URL, String)]()
        var outstanding = Set<String>()
        var unavailable = false
        let phoneDiagnostics = WatchDiagnostics(logEvents: false)
        let watchDiagnostics = WatchDiagnostics(logEvents: false)

        init() throws {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            phone = LibraryDatabase(storeURL: root.appending(path: "phone.sqlite"))
            watch = LibraryDatabase(storeURL: root.appending(path: "watch.sqlite"))
        }

        var inbox: URL { root.appending(path: "inbox") }
        func publisher() throws -> PhoneWatchLibraryPublisher {
            try PhoneWatchLibraryPublisher(database: phone, directory: root.appending(path: "publisher"), transport: .init(
                context: { [self] head in
                    if unavailable { throw WatchLibraryError.notLoaded }
                    heads.append(try #require(WatchLibraryHead(context: head.encode())))
                }, outstanding: { [self] in outstanding }, enqueue: { [self] url, key in
                    deliveries.append((url, key)); outstanding.insert(key)
                }), diagnostics: phoneDiagnostics)
        }

        func receiver() -> WatchLibraryReceiver { WatchLibraryReceiver(database: watch, directory: inbox, diagnostics: watchDiagnostics) }
        func stage(_ index: Int) throws {
            _ = try WatchLibraryReceiver.stage(deliveries[index].0, directory: inbox)
        }

        func cleanUp() {
            WatchLibraryStoreTests.Env.close(phone)
            WatchLibraryStoreTests.Env.close(watch)
            try? FileManager.default.removeItem(at: root)
        }
    }

    static func library(count: Int = 500) -> Library {
        var library = LibraryDatabaseTests.makeLibrary()
        let template = library.tracks[0]
        library.tracks = (0..<count).map { index in
            var track = template
            track.id = "t\(index)"
            track.musicFilename = "m\(index).mp3"
            track.playlistIds = ["p1", "p2"]
            return track
        }
        library.playlists = [
            Playlist.with { $0.id = "folder"; $0.name = "Folder" },
            Playlist.with {
                $0.id = "p1"; $0.name = "First"; $0.parentID = "folder"
                $0.trackIds = library.tracks.map(\.id).reversed()
            },
            Playlist.with { $0.id = "p2"; $0.name = "Second"; $0.trackIds = ["t0", "t1"] }
        ]
        return library
    }

    @Test("hundreds of selected tracks traverse production serialization, adapter and database without credentials")
    func roundTrip() async throws {
        let env = try Env()
        defer { env.cleanUp() }
        try await env.phone.replaceLibrary(with: Self.library(), sourceIdentity: "account")
        let publisher = try env.publisher()
        publisher.publish(identity: "account", playlistIDs: ["p1", "p2"])
        await publisher.waitForPublication()
        #expect(publisher.errorMessage == nil)
        #expect(env.deliveries.count == 1)
        let receiver = env.receiver()
        // file arrives before the context, and the delegate-owned source disappears.
        try env.stage(0)
        receiver.received()
        await receiver.waitForImport()
        #expect(try await env.watch.trackCount() == 0)
        receiver.expect(try #require(env.heads.last))
        await receiver.waitForImport()
        #expect(receiver.errorMessage == nil)
        #expect(try await env.watch.trackCount() == 500)
        #expect(env.phoneDiagnostics.events.contains { $0.kind == .metadataPublished && $0.identity == WatchDiagnosticIdentity(publisher.head) })
        #expect(env.watchDiagnostics.events.contains { $0.kind == .metadataAccepted && $0.identity == WatchDiagnosticIdentity(publisher.head) })
        let phone = env.phoneDiagnostics.report(deviceModel: "", systemVersion: "")
        let watch = env.watchDiagnostics.report(deviceModel: "", systemVersion: "")
        #expect(phone.totals?["metadataPublished:metadata"]?.bytes == watch.totals?["metadataAccepted:metadata"]?.bytes)
        let published = try #require(phone.totals?["metadataPublished:metadata"])
        #expect(published.bytes > 0)
        let songs = try await env.watch.allSongs()
        let song = try #require(songs.first { $0.id == "t0" })
        #expect(song.artistName == "The Beatles" && song.albumName == "Abbey Road")
        #expect(song.addedDate == Date(timeIntervalSince1970: 1_600_000_000))
        #expect(song.start == 0 && song.rating == 100 && song.playCount == 5)
        let playlists = try await env.watch.allPlaylists()
        #expect(playlists.count == 3)
        #expect(playlists.first { $0.id == "folder" }?.isFolder == true)
        #expect(playlists.first { $0.id == "p1" }?.parentId == "folder")
        #expect(playlists.first { $0.id == "p1" }?.trackIds.first == "t499")
        #expect(playlists.first { $0.id == "p2" }?.trackIds == ["t0", "t1"])
        let sections = PlaylistListBuilder.watchSections(in: playlists)
        #expect(sections.map(\.title) == ["", "Folder"])
        #expect(sections.flatMap(\.playlists).map(\.id) == ["p2", "p1"])
        let saved = try #require(try await env.watch.watchSnapshot())
        #expect(try saved.music.count == 500)
        #expect(try saved.artwork == ["a1.jpg"])
        #expect(saved.head == publisher.head)
        #expect(!receiver.allowsLegacySync)
        try await env.watch.replaceLibrary(with: Library())
        #expect(try await env.watch.trackCount() == 500)
        let localFiles = FileStore(rootURL: env.root.appending(path: "artwork-policy"))
        let fetcher = WatchArtworkFetcher(fileStore: localFiles)
        #expect(fetcher.artworkURL("a1.jpg") == nil)
        let data = try Data(contentsOf: env.deliveries[0].0)
        #expect(String(data: data, encoding: .utf8)?.contains("token") == false)
        let defaults = UserDefaults(suiteName: env.root.lastPathComponent)!
        defer { defaults.removePersistentDomain(forName: env.root.lastPathComponent) }
        let files = FileStore(rootURL: env.root.appending(path: "files"))
        let local = WatchLibraryStore(songs: SongsStore(database: env.watch, fileStore: files),
                                     playlists: PlaylistsStore(database: env.watch), defaults: defaults, receiver: receiver)
        await local.load()
        #expect(local.presentation(isConfigured: false) == .ready)
    }

    @Test("empty selection is saved but failed or wrong-account phone loads cannot publish an empty library")
    func emptyAndFailedLoads() async throws {
        let env = try Env()
        defer { env.cleanUp() }
        let publisher = try env.publisher()
        publisher.publish(identity: "account", playlistIDs: [])
        await publisher.waitForPublication()
        #expect(env.deliveries.isEmpty && publisher.errorMessage != nil && publisher.head.failed == true)
        try await env.phone.replaceLibrary(with: Self.library(), sourceIdentity: "account")
        publisher.publish(identity: "account", playlistIDs: [])
        await publisher.waitForPublication()
        let receiver = env.receiver()
        receiver.expect(publisher.head)
        try env.stage(0)
        receiver.received()
        await receiver.waitForImport()
        #expect(receiver.snapshot != nil)
        #expect(try await env.watch.trackCount() == 0)
        let defaults = UserDefaults(suiteName: env.root.lastPathComponent)!
        defer { defaults.removePersistentDomain(forName: env.root.lastPathComponent) }
        let files = FileStore(rootURL: env.root.appending(path: "files"))
        let local = WatchLibraryStore(songs: SongsStore(database: env.watch, fileStore: files),
                                     playlists: PlaylistsStore(database: env.watch), defaults: defaults, receiver: receiver)
        await local.load()
        #expect(local.presentation(isConfigured: false) == .empty)
        publisher.publish(identity: "another-account", playlistIDs: ["p1"])
        await publisher.waitForPublication()
        #expect(env.deliveries.count == 1 && !publisher.head.metadataReady)
        #expect(publisher.errorMessage != nil)
    }

    @Test("relaunch, duplicate and stale revisions retain the latest library and file inventory")
    func revisionsAndRelaunch() async throws {
        let env = try Env()
        defer { env.cleanUp() }
        try await env.phone.replaceLibrary(with: Self.library(), sourceIdentity: "account")
        var publisher = try env.publisher()
        publisher.publish(identity: "account", playlistIDs: ["p1"])
        await publisher.waitForPublication()
        let old = publisher.head
        let originalBytes = try Data(contentsOf: env.deliveries[0].0)
        publisher.publish(identity: "account", playlistIDs: ["p2"])
        await publisher.waitForPublication()
        let current = publisher.head
        #expect(current.revision > old.revision)
        // the system may still be reading the previous transfer file.
        #expect(try Data(contentsOf: env.deliveries[0].0) == originalBytes)
        let receiver = env.receiver()
        receiver.expect(current)
        try env.stage(1)
        receiver.received()
        await receiver.waitForImport()
        receiver.expect(old)
        try env.stage(0)
        receiver.received()
        await receiver.waitForImport()
        #expect(receiver.head == current)
        #expect(try await env.watch.trackCount() == 2)
        try env.stage(1)
        receiver.received()
        await receiver.waitForImport()
        #expect(receiver.snapshot?.head == current)
        publisher = try env.publisher()
        publisher.publish(identity: "account", playlistIDs: ["p2"])
        await publisher.waitForPublication()
        #expect(publisher.head == current && env.deliveries.count == 2)
        WatchLibraryStoreTests.Env.close(env.watch)
        let reopened = LibraryDatabase(storeURL: env.root.appending(path: "watch.sqlite"))
        defer { WatchLibraryStoreTests.Env.close(reopened) }
        let restored = WatchLibraryReceiver(database: reopened, directory: env.inbox)
        await restored.waitForImport()
        #expect(restored.snapshot?.head == current)
        #expect(try restored.snapshot?.music == ["m0.mp3", "m1.mp3"])
        #expect(try await reopened.trackCount() == 2)
    }

    @Test("corrupt data and interrupted save preserve the accepted revision and retry staged receipt after launch")
    func corruptAndInterrupted() async throws {
        let env = try Env()
        defer { env.cleanUp() }
        try await env.phone.replaceLibrary(with: Self.library(), sourceIdentity: "account")
        let publisher = try env.publisher()
        publisher.publish(identity: "account", playlistIDs: ["p2"])
        await publisher.waitForPublication()
        var receiver = env.receiver()
        receiver.expect(publisher.head)
        try env.stage(0)
        receiver.received()
        await receiver.waitForImport()
        let accepted = receiver.snapshot
        publisher.publish(identity: "account", playlistIDs: ["p1"])
        await publisher.waitForPublication()
        receiver.expect(publisher.head)
        await receiver.waitForImport()
        try Data("corrupt".utf8).write(to: env.inbox.appending(path: "bad.json"))
        receiver.received()
        await receiver.waitForImport()
        #expect(receiver.snapshot == accepted && receiver.errorMessage != nil)
        env.watch.beforeLibrarySave = { throw CocoaError(.fileWriteOutOfSpace) }
        try env.stage(1)
        receiver.received()
        await receiver.waitForImport()
        #expect(receiver.snapshot == accepted && receiver.errorMessage != nil)
        #expect(try await env.watch.trackCount() == 2)
        #expect(try await env.watch.watchSnapshot() == accepted)
        env.watch.beforeLibrarySave = {}
        // no scene or phone reachability is required to recover the inbox.
        receiver = env.receiver()
        await receiver.waitForImport()
        #expect(receiver.snapshot?.head == publisher.head)
        #expect(try await env.watch.trackCount() == 500)
    }

    @Test("identity changes and sign-out reject old account data; refreshed token keeps the namespace")
    func accountChanges() async throws {
        let env = try Env()
        defer { env.cleanUp() }
        func token(_ signature: String, username: String = "user") -> String {
            let claims = Data("{\"username\":\"\(username)\"}".utf8).base64EncodedString()
            return "header.\(claims).\(signature)"
        }
        let origin = URL(string: "https://library.test")!
        let identity = try #require(LibraryIdentity.make(token: token("one"), baseURL: origin))
        #expect(LibraryIdentity.make(token: token("two"), baseURL: origin) == identity)
        #expect(LibraryIdentity.make(token: token("two", username: "other"), baseURL: origin) != identity)
        #expect(LibraryIdentity.make(token: token("two"), baseURL: URL(string: "https://other.test")) != identity)
        try await env.phone.replaceLibrary(with: Self.library(), sourceIdentity: identity)
        let publisher = try env.publisher()
        publisher.publish(identity: identity, playlistIDs: ["p2"])
        await publisher.waitForPublication()
        let old = publisher.head
        let receiver = env.receiver()
        receiver.expect(old)
        try env.stage(0)
        receiver.received()
        await receiver.waitForImport()
        publisher.publish(identity: nil, playlistIDs: ["p2"])
        await publisher.waitForPublication()
        receiver.expect(publisher.head)
        try env.stage(0)
        receiver.received()
        await receiver.waitForImport()
        #expect(receiver.head?.libraryID == nil)
        #expect(receiver.snapshot?.head == old)
        #expect(try await env.watch.trackCount() == 2)
        try await env.phone.replaceLibrary(with: Self.library(count: 4), sourceIdentity: "new-account")
        publisher.publish(identity: "new-account", playlistIDs: ["p1"])
        await publisher.waitForPublication()
        receiver.expect(publisher.head)
        try env.stage(1)
        receiver.received()
        receiver.expect(old)
        await receiver.waitForImport()
        #expect(receiver.snapshot?.head.libraryID == "new-account")
        #expect(try await env.watch.trackCount() == 4)
        var unsupported = WatchLibraryHead(publisher: old.publisher, revision: publisher.head.revision + 1,
                                           libraryID: "new-account", playlistIDs: ["p1"])
        unsupported.version = 99
        receiver.expect(unsupported)
        await receiver.waitForImport()
        #expect(receiver.head?.version == 99 && receiver.errorMessage != nil)
        let incompatible = WatchLibrarySnapshot(head: .init(publisher: unsupported.publisher, revision: unsupported.revision,
                                                           libraryID: "new-account", playlistIDs: ["p1"], metadataReady: true),
                                               libraryData: try WatchLibrarySnapshot.selected(Self.library(count: 4), ids: ["p1"]).serializedData())
        #expect(try await !env.watch.importWatchLibrary(incompatible))
        #expect(try await env.watch.trackCount() == 4)
    }

    @Test("metadata is queued before selected music and artwork can occupy delivery")
    func metadataBeforeContent() async throws {
        let env = try Env()
        defer { env.cleanUp() }
        try await env.phone.replaceLibrary(with: Self.library(count: 4), sourceIdentity: "account")
        let publisher = try env.publisher()
        var contentStartedBeforeMetadata = false
        var publishedSnapshots = 0
        publisher.onSnapshot = { head, snapshot in
            guard snapshot != nil else { return }
            publishedSnapshots += 1
            if !env.outstanding.contains(PhoneWatchLibraryPublisher.key(head)) {
                contentStartedBeforeMetadata = true
            }
        }
        publisher.publish(identity: "account", playlistIDs: ["p1"])
        await publisher.waitForPublication()
        #expect(!contentStartedBeforeMetadata)
        #expect(env.deliveries.count == 1)
        #expect(publishedSnapshots == 1)
        publisher.publish(identity: "account", playlistIDs: [])
        await publisher.waitForPublication()
        publisher.publish(identity: "account", playlistIDs: ["p2"])
        await publisher.waitForPublication()
        #expect(!contentStartedBeforeMetadata)
        #expect(env.deliveries.count == 3)
        #expect(publishedSnapshots == 3)
    }

    @Test("durable publication retries without a live round trip and background lifetime waits for import")
    func backgroundDelivery() async throws {
        let env = try Env()
        defer { env.cleanUp() }
        try await env.phone.replaceLibrary(with: Self.library(count: 4), sourceIdentity: "account")
        env.unavailable = true
        var publisher = try env.publisher()
        var contentStarted = false
        publisher.onSnapshot = { _, snapshot in
            if snapshot != nil { contentStarted = true }
        }
        publisher.publish(identity: "account", playlistIDs: ["p1"])
        await publisher.waitForPublication()
        let head = publisher.head
        #expect(head.metadataReady && env.deliveries.isEmpty)
        #expect(!contentStarted)
        env.unavailable = false
        publisher = try env.publisher()
        publisher.publish(identity: "account", playlistIDs: ["p1"])
        await publisher.waitForPublication()
        #expect(publisher.head == head && env.deliveries.count == 1)
        let lifetime = WatchLibraryBackgroundLifetime()
        var completed = 0
        lifetime.hold { completed += 1 }
        lifetime.update(activated: true, contentPending: false, importsPending: 1)
        #expect(completed == 0)
        lifetime.update(activated: true, contentPending: false, importsPending: 0)
        #expect(completed == 1)
        lifetime.finishIfIdle()
        #expect(completed == 1)
    }

    @Test("malformed graph, missing tracks and unsafe filenames cannot replace saved content")
    func invalidSnapshots() async throws {
        let env = try Env()
        defer { env.cleanUp() }
        let head = WatchLibraryHead(publisher: UUID(), revision: 1, libraryID: "account", playlistIDs: ["p1"], metadataReady: true)
        _ = try await env.watch.expectWatchLibrary(head)
        var bad = Self.library(count: 4)
        bad.playlists[0].parentID = "p1"
        let cyclic = WatchLibrarySnapshot(head: head, libraryData: try bad.serializedData())
        await #expect(throws: WatchLibraryError.self) { _ = try await env.watch.importWatchLibrary(cyclic) }
        bad = Self.library(count: 4)
        bad.playlists[1].trackIds = ["missing"]
        let missing = WatchLibrarySnapshot(head: head, libraryData: try bad.serializedData())
        await #expect(throws: WatchLibraryError.self) { _ = try await env.watch.importWatchLibrary(missing) }
        bad = Self.library(count: 4)
        bad.tracks[0].musicFilename = "../outside.mp3"
        let traversal = WatchLibrarySnapshot(head: head, libraryData: try bad.serializedData())
        await #expect(throws: FileStore.FilenameError.self) { _ = try await env.watch.importWatchLibrary(traversal) }
        #expect(try await env.watch.trackCount() == 0)
    }
    @Test("selection changes and local metadata edits publish new snapshots while invalid selections fail safely")
    func updatedContent() async throws {
        let env = try Env()
        defer { env.cleanUp() }
        try await env.phone.replaceLibrary(with: Self.library(count: 4), sourceIdentity: "account")
        let publisher = try env.publisher()
        publisher.publish(identity: "account", playlistIDs: ["p2"])
        await publisher.waitForPublication()
        let original = publisher.head
        let edited = LibraryDatabaseTests.editedSong(id: "t0", artworkFilename: "updated.jpg")
        try await env.phone.updateTrack(edited)
        publisher.publish(identity: "account", playlistIDs: ["p2"])
        await publisher.waitForPublication()
        #expect(publisher.head.revision > original.revision)
        let receiver = env.receiver()
        receiver.expect(publisher.head)
        try env.stage(1)
        receiver.received()
        await receiver.waitForImport()
        let song = try #require(try await env.watch.allSongs().first { $0.id == "t0" })
        #expect(song.name == "Something" && song.artistName == "George Harrison" && song.rating == 80)
        #expect(try receiver.snapshot?.artwork == ["a1.jpg", "updated.jpg"])
        let accepted = receiver.snapshot
        publisher.publish(identity: "account", playlistIDs: ["folder"])
        await publisher.waitForPublication()
        #expect(publisher.head.failed == true && env.deliveries.count == 2)
        receiver.expect(publisher.head)
        await receiver.waitForImport()
        #expect(receiver.refreshFailed && receiver.snapshot == accepted)
        publisher.publish(identity: "account", playlistIDs: [])
        await publisher.waitForPublication()
        receiver.expect(publisher.head)
        try env.stage(2)
        receiver.received()
        await receiver.waitForImport()
        #expect(try await env.watch.allSongs().isEmpty)
        #expect(receiver.snapshot != nil && !receiver.refreshFailed)
    }

    @Test("a replacement phone publisher retires the old namespace permanently")
    func retiredPublisher() async throws {
        let env = try Env()
        defer { env.cleanUp() }
        let first = WatchLibraryHead(publisher: UUID(), revision: 1, libraryID: "first", playlistIDs: [], metadataReady: true)
        let replacement = WatchLibraryHead(publisher: UUID(), revision: 1, libraryID: "second", playlistIDs: [], metadataReady: true)
        #expect(try await env.watch.expectWatchLibrary(first))
        #expect(try await env.watch.importWatchLibrary(WatchLibrarySnapshot(head: first, libraryData: Library().serializedData())))
        let receiver = env.receiver()
        receiver.expect(replacement)
        await receiver.waitForImport()
        #expect(receiver.waitingForUpdate && receiver.snapshot?.head == first)
        let late = WatchLibraryHead(publisher: first.publisher, revision: 99, libraryID: "first", playlistIDs: [], metadataReady: true)
        #expect(try await !env.watch.expectWatchLibrary(late))
        #expect(try await env.watch.watchHead() == replacement)
    }

    @Test("older saved stores migrate without losing tracks before the first phone snapshot")
    func oldStoreMigration() async throws {
        let env = try Env()
        defer { env.cleanUp() }
        let model = try #require(env.phone.container.managedObjectModel.copy() as? NSManagedObjectModel)
        model.entities = model.entities.filter { $0.name != "LibraryDocument" }
        let url = env.root.appending(path: "legacy.sqlite")
        let legacy = NSPersistentContainer(name: "Library", managedObjectModel: model)
        legacy.persistentStoreDescriptions.first?.url = url
        var failure: Error?
        legacy.loadPersistentStores { _, error in failure = error }
        #expect(failure == nil)
        let description = try #require(NSEntityDescription.entity(forEntityName: "TrackEntity", in: legacy.viewContext))
        let track = TrackEntity(entity: description, insertInto: legacy.viewContext)
        track.id = "old"
        track.name = "Saved before migration"
        track.musicFilename = "old.mp3"
        try legacy.viewContext.save()
        for store in legacy.persistentStoreCoordinator.persistentStores { try legacy.persistentStoreCoordinator.remove(store) }
        let migrated = LibraryDatabase(storeURL: url)
        defer { WatchLibraryStoreTests.Env.close(migrated) }
        #expect(try await migrated.allSongs().first?.id == "old")
        let head = WatchLibraryHead(publisher: UUID(), revision: 1, libraryID: "account", playlistIDs: [], metadataReady: true)
        #expect(try await migrated.expectWatchLibrary(head))
        #expect(try await migrated.importWatchLibrary(WatchLibrarySnapshot(head: head, libraryData: Library().serializedData())))
        #expect(try await migrated.watchSnapshot()?.head == head)
    }

    @Test("a phone store without ownership requests a full refresh before publishing its saved library")
    func sourceOwnershipRefresh() async throws {
        let host = "watch-source-ownership.test"
        let env = SyncStoreTests.makeEnv(host: host, transfersFiles: false)
        defer { try? FileManager.default.removeItem(at: env.fileStore.rootURL) }
        let library = SyncStoreTests.makeLibrary()
        try await env.database.replaceLibrary(with: library)
        env.metadata.update(from: library)
        let claims = Data("{\"username\":\"user\"}".utf8).base64EncodedString()
        let token = "header.\(claims).signature"
        try SyncStoreTests.installHandler(host: host)
        await env.store.checkForUpdates(token: token, baseURL: env.baseURL)
        #expect(env.store.state == .updateAvailable(newLibraryData: true, missingFiles: 0))
        var published = 0
        env.store.onLibrarySaved = { published += 1 }
        await env.store.sync(token: token, baseURL: env.baseURL)
        #expect(env.store.state == .upToDate(failedDownloads: 0) && published == 1)
        let identity = try #require(LibraryIdentity.make(token: token, baseURL: env.baseURL))
        #expect(try await env.database.hasPhoneLibrary(identity: identity))
        #expect(SyncStoreTests.requestPaths(host: host).contains("/api/library"))
    }

    @Test("incomplete phone membership never becomes a successful empty snapshot")
    func incompletePhoneLibrary() async throws {
        let env = try Env()
        defer { env.cleanUp() }
        var incomplete = Self.library(count: 4)
        incomplete.playlists[1].trackIds = ["missing"]
        try await env.phone.replaceLibrary(with: incomplete, sourceIdentity: "account")
        let publisher = try env.publisher()
        publisher.publish(identity: "account", playlistIDs: ["p1"])
        await publisher.waitForPublication()
        #expect(publisher.head.failed == true && publisher.errorMessage != nil)
        #expect(env.deliveries.isEmpty)
    }

    @Test("unreadable new protocol control persists the migration guard without an HTTP fallback")
    func unreadableControl() async throws {
        let env = try Env()
        defer { env.cleanUp() }
        try await env.watch.replaceLibrary(with: Self.library(count: 4))
        let receiver = env.receiver()
        await receiver.waitForImport()
        #expect(receiver.allowsLegacySync)
        #expect(WatchLibraryHead(context: ["watchLibraryHead": Data("future-format".utf8)]) == nil)
        receiver.rejectContext()
        #expect(!receiver.allowsLegacySync)
        await receiver.waitForImport()
        #expect(receiver.refreshFailed)
        try await env.watch.replaceLibrary(with: Library())
        #expect(try await env.watch.trackCount() == 4)
        let restored = env.receiver()
        await restored.waitForImport()
        #expect(restored.protocolSelected && restored.refreshFailed && !restored.allowsLegacySync)
        #expect(try await env.watch.trackCount() == 4)
    }

}
